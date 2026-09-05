#!/usr/bin/env bash
# Real-Docker smoke coverage for the Milestone 2 sandbox core.

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
AIBOX_BIN="${AIBOX_BIN:-${ROOT_DIR}/bin/aibox}"
REAL_DOCKER="${AIBOX_SMOKE_REAL_DOCKER:-$(command -v docker 2>/dev/null || true)}"
TMP_BASE="${TMPDIR:-/tmp}"
HARNESS_DIR=""
PROJECT_LIST=""
FOREIGN_LIST=""
STUB_DIR=""
SMOKE_CONFIG=""
SMOKE_VERSION="smoke"
SMOKE_IMAGE=""
CHECKS=0
FAILURES=0

pass() {
  CHECKS=$((CHECKS + 1))
  printf 'PASS %s\n' "$1"
}

fail() {
  CHECKS=$((CHECKS + 1))
  FAILURES=$((FAILURES + 1))
  printf 'FAIL %s\n' "$1" >&2
}

check_equal() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name (expected: ${expected}; actual: ${actual})"
  fi
}

check_contains() {
  local name="$1" needle="$2" file="$3"
  if grep -Fq "$needle" "$file"; then
    pass "$name"
  else
    fail "$name (missing: ${needle})"
  fi
}

record_project() {
  printf '%s\n' "$1" >> "$PROJECT_LIST"
}

new_project() {
  local project
  project="$(mktemp -d "${HARNESS_DIR}/smk-project.XXXXXX")" || return 1
  project="$(cd "$project" && pwd -P)"
  record_project "$project"
  printf '%s\n' "$project"
}

project_name() {
  local project="$1" canonical slug hash
  canonical="$(cd "$project" && pwd -P)"
  slug="$(basename "$canonical" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/_/-/g; s/^-*//; s/-*$//')"
  [[ -n "$slug" ]] || slug="project"
  slug="${slug:0:48}"
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$canonical" | sha256sum | cut -d' ' -f1 | cut -c1-6)"
  else
    hash="$(printf '%s' "$canonical" | shasum -a 256 | cut -d' ' -f1 | cut -c1-6)"
  fi
  printf 'aibox-%s-%s\n' "$slug" "$hash"
}

run_aibox() {
  AIBOX_CONFIG_DIR="$SMOKE_CONFIG" \
    AIBOX_CLI_VERSION="$SMOKE_VERSION" \
    "$AIBOX_BIN" "$@"
}

docker_ready() {
  [[ -n "$REAL_DOCKER" ]] && "$REAL_DOCKER" info >/dev/null 2>&1
}

remove_ids() {
  local object="$1" ids="$2" id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    case "$object" in
      container) "$REAL_DOCKER" rm --force "$id" >/dev/null 2>&1 || true ;;
      network) "$REAL_DOCKER" network rm "$id" >/dev/null 2>&1 || true ;;
      volume) "$REAL_DOCKER" volume rm --force "$id" >/dev/null 2>&1 || true ;;
    esac
  done <<EOF
$ids
EOF
}

cleanup_project_resources() {
  local project="$1" ids
  ids="$("$REAL_DOCKER" ps --all --quiet \
    --filter 'label=aibox.schema=3' \
    --filter "label=aibox.path=${project}" 2>/dev/null || true)"
  remove_ids container "$ids"

  ids="$("$REAL_DOCKER" network ls --quiet \
    --filter 'label=aibox.schema=3' \
    --filter "label=aibox.path=${project}" 2>/dev/null || true)"
  remove_ids network "$ids"

  ids="$("$REAL_DOCKER" volume ls --quiet \
    --filter 'label=aibox.schema=3' \
    --filter "label=aibox.path=${project}" 2>/dev/null || true)"
  remove_ids volume "$ids"
}

cleanup() {
  local project foreign_id foreign_name actual_name
  trap - EXIT HUP INT TERM

  if [[ -n "$PROJECT_LIST" && -f "$PROJECT_LIST" ]] && docker_ready; then
    while IFS= read -r project; do
      [[ -n "$project" ]] && cleanup_project_resources "$project"
    done < "$PROJECT_LIST"
  fi

  if [[ -n "$FOREIGN_LIST" && -f "$FOREIGN_LIST" ]] && docker_ready; then
    while read -r foreign_id foreign_name; do
      [[ -n "$foreign_id" && -n "$foreign_name" ]] || continue
      actual_name="$("$REAL_DOCKER" container inspect --format '{{.Name}}' "$foreign_id" 2>/dev/null || true)"
      if [[ "$actual_name" == "/${foreign_name}" ]]; then
        "$REAL_DOCKER" rm --force "$foreign_id" >/dev/null 2>&1 || true
      fi
    done < "$FOREIGN_LIST"
  fi

  case "$SMOKE_IMAGE" in
    aibox:smoke-*-node24) "$REAL_DOCKER" image rm --force "$SMOKE_IMAGE" >/dev/null 2>&1 || true ;;
  esac

  case "$HARNESS_DIR" in
    "${TMP_BASE%/}"/smk-aibox.*) rm -rf -- "$HARNESS_DIR" ;;
  esac
}

on_signal() {
  exit 130
}

setup() {
  [[ -x "$AIBOX_BIN" ]] || {
    printf 'Smoke harness: CLI is not executable: %s\n' "$AIBOX_BIN" >&2
    exit 1
  }
  HARNESS_DIR="$(mktemp -d "${TMP_BASE%/}/smk-aibox.XXXXXX")" || exit 1
  PROJECT_LIST="${HARNESS_DIR}/projects.list"
  FOREIGN_LIST="${HARNESS_DIR}/foreign.list"
  STUB_DIR="${HARNESS_DIR}/stub-bin"
  SMOKE_CONFIG="${HARNESS_DIR}/config"
  SMOKE_VERSION="smoke-$(printf '%s' "${HARNESS_DIR##*.}" | tr '[:upper:]' '[:lower:]')"
  SMOKE_IMAGE="aibox:${SMOKE_VERSION}-node24"
  : > "$PROJECT_LIST"
  : > "$FOREIGN_LIST"
  mkdir -p "$STUB_DIR" "$SMOKE_CONFIG"
  ln -s "${ROOT_DIR}/scripts/docker-stub.sh" "${STUB_DIR}/docker"
}

require_docker() {
  if ! docker_ready; then
    printf 'FAIL Docker CLI and a reachable local daemon are required\n' >&2
    exit 1
  fi
}

test_reuse_mounts_and_persistence() {
  local project="$1" name="$2" out err code count mounts sources unrelated secret status_text marker
  out="${HARNESS_DIR}/reuse.out"
  err="${HARNESS_DIR}/reuse.err"

  if run_aibox --dir "$project" up >"$out" 2>"$err" && run_aibox --dir "$project" up >>"$out" 2>>"$err"; then
    pass "two up calls reuse the sandbox"
  else
    fail "two up calls reuse the sandbox"
    return
  fi

  count="$("$REAL_DOCKER" ps --all --quiet --filter 'label=aibox.schema=3' --filter "label=aibox.path=${project}" --filter 'label=aibox.role=sandbox' | wc -l | tr -d ' ')"
  check_equal "one project container exists" "1" "$count"
  count="$("$REAL_DOCKER" volume ls --quiet --filter 'label=aibox.schema=3' --filter "label=aibox.path=${project}" | wc -l | tr -d ' ')"
  check_equal "one private home volume exists" "1" "$count"
  count="$("$REAL_DOCKER" network ls --quiet --filter 'label=aibox.schema=3' --filter "label=aibox.path=${project}" | wc -l | tr -d ' ')"
  check_equal "one project network exists" "1" "$count"

  mounts="$("$REAL_DOCKER" container inspect --format '{{len .Mounts}}' "$name")"
  check_equal "sandbox has exactly two mounts" "2" "$mounts"
  sources="$("$REAL_DOCKER" container inspect --format '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Destination}}{{println}}{{end}}' "$name")"
  if grep -Fq "bind|${project}|${project}" <<<"$sources" && grep -Fq "volume|" <<<"$sources" && grep -Fq '|/home/aibox' <<<"$sources"; then
    pass "mounts are the same-path project bind and private home"
  else
    fail "mounts are the same-path project bind and private home"
  fi

  unrelated="${HARNESS_DIR}/unrelated"
  mkdir -p "$unrelated"
  printf 'host-only\n' > "${unrelated}/secret"
  if run_aibox --dir "$project" run sh -c 'test ! -e "$1"' sh "${unrelated}/secret" >/dev/null 2>"$err"; then
    pass "unrelated host directory is not visible"
  else
    fail "unrelated host directory is not visible"
  fi

  if run_aibox --dir "$project" run sh -c 'printf persistent > "$HOME/.m2-home"' >/dev/null 2>"$err" \
    && run_aibox --dir "$project" stop >/dev/null 2>>"$err" \
    && run_aibox --dir "$project" run sh -c 'test "$(cat "$HOME/.m2-home")" = persistent' >/dev/null 2>>"$err"; then
    pass "private home file persists across stop and run"
  else
    fail "private home file persists across stop and run"
  fi

  if run_aibox --dir "$project" run sh -c 'sudo apt-get update -qq && sudo apt-get install -y -qq tree' >/dev/null 2>"$err" \
    && run_aibox --dir "$project" stop >/dev/null 2>>"$err" \
    && run_aibox --dir "$project" run sh -c 'dpkg-query -W tree >/dev/null' >/dev/null 2>>"$err"; then
    pass "apt package persists across stop and run"
  else
    fail "apt package persists across stop and run"
  fi

  marker="${project}/unset-env-command-ran"
  unset AIBOX_M2_UNSET_SMOKE || true
  set +e
  run_aibox --dir "$project" run --env AIBOX_M2_UNSET_SMOKE sh -c 'touch "$1"' sh "$marker" >"$out" 2>"$err"
  code=$?
  set -e
  if [[ "$code" -eq 1 && ! -e "$marker" ]]; then
    pass "unset forwarded environment fails before exec"
  else
    fail "unset forwarded environment fails before exec"
  fi

  secret="smk-secret-${RANDOM}-${RANDOM}"
  export AIBOX_M2_SECRET="$secret"
  if run_aibox --dir "$project" run --env AIBOX_M2_SECRET sh -c 'test -n "$AIBOX_M2_SECRET"' >"$out" 2>"$err"; then
    pass "bare-name environment forwarding delivers its value"
  else
    fail "bare-name environment forwarding delivers its value"
  fi
  status_text="$(run_aibox --dir "$project" status 2>>"$err")"
  if ! grep -Fq "$secret" "$err" && ! grep -Fq "$secret" <<<"$status_text"; then
    pass "forwarded environment value stays out of diagnostics"
  else
    fail "forwarded environment value stays out of diagnostics"
  fi
  unset AIBOX_M2_SECRET

  set +e
  run_aibox --dir "$project" run sh -c 'echo out; echo err >&2; exit 7' >"$out" 2>"$err"
  code=$?
  set -e
  check_equal "program exit status passes through" "7" "$code"
  check_equal "program stdout remains clean" "out" "$(tr -d '\r\n' < "$out")"
  check_contains "program stderr passes through" "err" "$err"

  if run_aibox --dir "$project" run sh -c 'test -f /tmp/aibox-ready' >/dev/null 2>"$err"; then
    pass "agent-independent readiness marker exists"
  else
    fail "agent-independent readiness marker exists"
  fi
  if run_aibox --dir "$project" run sh -c '! command -v claude >/dev/null && ! command -v codex >/dev/null' >/dev/null 2>"$err"; then
    pass "default image contains no bundled agent"
  else
    fail "default image contains no bundled agent"
  fi

  if (cd "$HARNESS_DIR" && run_aibox --dir "$project" status) >"$out" 2>"$err" \
    && grep -Fq "Sandbox: ${name}" "$out"; then
    pass "leading --dir resolves the same sandbox from elsewhere"
  else
    fail "leading --dir resolves the same sandbox from elsewhere"
  fi

  if run_aibox --dir "$project" shell printf '%s' shell-ok >"$out" 2>"$err"; then
    check_equal "shell command preserves arguments" "shell-ok" "$(tr -d '\r\n' < "$out")"
  else
    fail "shell command preserves arguments"
  fi

  if grep -Fq 'Processes: idle' <<<"$status_text"; then
    pass "PID-based inspection recognizes the idle sandbox"
  else
    fail "PID-based inspection recognizes the idle sandbox"
  fi

}

test_concurrent_creation() {
  local project="$1" out1 out2 err1 err2 pid1 pid2 code1 code2 count
  out1="${HARNESS_DIR}/concurrent-1.out"
  out2="${HARNESS_DIR}/concurrent-2.out"
  err1="${HARNESS_DIR}/concurrent-1.err"
  err2="${HARNESS_DIR}/concurrent-2.err"

  run_aibox --dir "$project" run sh -c 'sleep 0.2; printf one' >"$out1" 2>"$err1" &
  pid1=$!
  run_aibox --dir "$project" run sh -c 'sleep 0.2; printf two' >"$out2" 2>"$err2" &
  pid2=$!
  set +e
  wait "$pid1"; code1=$?
  wait "$pid2"; code2=$?
  set -e
  if [[ "$code1" -eq 0 && "$code2" -eq 0 ]]; then
    pass "concurrent run calls both succeed"
  else
    fail "concurrent run calls both succeed (statuses: ${code1}, ${code2})"
    sed 's/^/  first: /' "$err1" >&2
    sed 's/^/  second: /' "$err2" >&2
  fi
  count="$("$REAL_DOCKER" ps --all --quiet --filter 'label=aibox.schema=3' --filter "label=aibox.path=${project}" --filter 'label=aibox.role=sandbox' | wc -l | tr -d ' ')"
  check_equal "concurrent creation produces one container" "1" "$count"
  count="$("$REAL_DOCKER" volume ls --quiet --filter 'label=aibox.schema=3' --filter "label=aibox.path=${project}" | wc -l | tr -d ' ')"
  check_equal "concurrent creation produces one volume" "1" "$count"
  count="$("$REAL_DOCKER" network ls --quiet --filter 'label=aibox.schema=3' --filter "label=aibox.path=${project}" | wc -l | tr -d ' ')"
  check_equal "concurrent creation produces one network" "1" "$count"
}

test_refusals_and_fail_closed() {
  local project="$1" name="$2" foreign_project="$3" foreign_name="$4" foreign_id out err code path colon_path
  out="${HARNESS_DIR}/refusal.out"
  err="${HARNESS_DIR}/refusal.err"

  for path in / "$HOME" /Users /home /Volumes /mnt /tmp /var /etc /usr /opt /private; do
    [[ -d "$path" ]] || continue
    set +e
    run_aibox --dir "$path" status >"$out" 2>"$err"
    code=$?
    set -e
    if [[ "$code" -eq 1 ]] && grep -Fq 'Refusing unsafe project path:' "$err"; then
      pass "unsafe path is rejected: ${path}"
    else
      fail "unsafe path is rejected: ${path}"
    fi
  done

  colon_path="${HARNESS_DIR}/smk:colon"
  mkdir -p "$colon_path"
  record_project "$colon_path"
  set +e
  run_aibox --dir "$colon_path" status >"$out" 2>"$err"
  code=$?
  set -e
  if [[ "$code" -eq 1 ]] && grep -Fq 'Refusing unsafe project path:' "$err"; then
    pass "path containing a colon is rejected"
  else
    fail "path containing a colon is rejected"
  fi

  foreign_id="$("$REAL_DOCKER" create --name "$foreign_name" node:24-bookworm sleep infinity)" || {
    fail "create foreign-schema fixture"
    return
  }
  printf '%s %s\n' "$foreign_id" "$foreign_name" >> "$FOREIGN_LIST"
  set +e
  run_aibox --dir "$foreign_project" up >"$out" 2>"$err"
  code=$?
  set -e
  if [[ "$code" -eq 1 ]] && grep -Fq "Refusing foreign container named ${foreign_name}" "$err" \
    && "$REAL_DOCKER" container inspect "$foreign_id" >/dev/null 2>&1; then
    pass "foreign-schema container is refused and untouched"
  else
    fail "foreign-schema container is refused and untouched"
  fi

  set +e
  AIBOX_SMOKE_REAL_DOCKER="$REAL_DOCKER" \
    AIBOX_SMOKE_DOCKER_ENDPOINT='tcp://remote.example:2375' \
    AIBOX_CONFIG_DIR="$SMOKE_CONFIG" \
    AIBOX_CLI_VERSION="$SMOKE_VERSION" \
    PATH="${STUB_DIR}:${PATH}" \
    "$AIBOX_BIN" --dir "$project" status >"$out" 2>"$err"
  code=$?
  set -e
  if [[ "$code" -eq 1 ]] && grep -Fq 'Refusing remote Docker endpoint' "$err"; then
    pass "remote Docker endpoint is refused"
  else
    fail "remote Docker endpoint is refused"
  fi

  set +e
  AIBOX_SMOKE_REAL_DOCKER="$REAL_DOCKER" \
    AIBOX_SMOKE_FAIL_COMMAND='top' \
    AIBOX_CONFIG_DIR="$SMOKE_CONFIG" \
    AIBOX_CLI_VERSION="$SMOKE_VERSION" \
    PATH="${STUB_DIR}:${PATH}" \
    "$AIBOX_BIN" --dir "$project" status >"$out" 2>"$err"
  code=$?
  set -e
  if [[ "$code" -eq 0 ]] && grep -Fiq 'cannot establish safety' "$err" && grep -Fq 'Processes: unknown' "$out"; then
    pass "docker top failure becomes unknown safety state"
  else
    fail "docker top failure becomes unknown safety state"
  fi

  set +e
  run_aibox --dir "$project" run definitely-not-an-aibox-program >"$out" 2>"$err"
  code=$?
  set -e
  if [[ "$code" -eq 1 ]] && grep -Fq 'persistent /home/aibox' "$err" && grep -Fq 'Dockerfile.extra' "$err"; then
    pass "missing program error names both installation paths"
  else
    fail "missing program error names both installation paths"
  fi

  # Silence unused-name false positives while keeping fixture derivation explicit.
  [[ -n "$name" ]]
}

main() {
  local project_one project_two project_foreign name_one name_foreign
  setup
  trap cleanup EXIT
  trap on_signal HUP INT TERM
  require_docker

  project_one="$(new_project)"
  project_two="$(new_project)"
  project_foreign="$(new_project)"
  name_one="$(project_name "$project_one")"
  name_foreign="$(project_name "$project_foreign")"

  test_reuse_mounts_and_persistence "$project_one" "$name_one"
  test_concurrent_creation "$project_two"
  test_refusals_and_fail_closed "$project_one" "$name_one" "$project_foreign" "$name_foreign"

  printf 'Smoke harness complete: %s checks, %s failures\n' "$CHECKS" "$FAILURES"
  [[ "$FAILURES" -eq 0 ]]
}

main "$@"
