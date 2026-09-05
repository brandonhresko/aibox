#!/usr/bin/env bash
# Real-Docker smoke coverage for the Milestone 2 and 3 sandbox core.

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
AIBOX_BIN="${AIBOX_BIN:-${ROOT_DIR}/bin/aibox}"
REAL_DOCKER="${AIBOX_SMOKE_REAL_DOCKER:-$(command -v docker 2>/dev/null || true)}"
TMP_BASE="${TMPDIR:-/tmp}"
HARNESS_DIR=""
PROJECT_LIST=""
FOREIGN_LIST=""
IMAGE_LIST=""
HOST_PID_LIST=""
DANGLING_IMAGE_LIST=""
STUB_DIR=""
SMOKE_CONFIG=""
SMOKE_VERSION="smoke"
SMOKE_IMAGE=""
SMOKE_ID=""
M3_VALID_IMAGE=""
M3_BAD_USER_IMAGE=""
M3_BAD_ENTRY_IMAGE=""
M3_ROLLBACK_IMAGE=""
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

record_image() {
  printf '%s\n' "$1" >> "$IMAGE_LIST"
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
  local project foreign_id foreign_name actual_name image_tag host_pid image_id repo_tags
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

  if [[ -n "$IMAGE_LIST" && -f "$IMAGE_LIST" ]] && docker_ready; then
    while IFS= read -r image_tag; do
      case "$image_tag" in
        aibox-smoke-*:*) "$REAL_DOCKER" image rm "$image_tag" >/dev/null 2>&1 || true ;;
      esac
    done < "$IMAGE_LIST"
  fi

  if [[ -n "$DANGLING_IMAGE_LIST" && -f "$DANGLING_IMAGE_LIST" ]] && docker_ready; then
    while IFS= read -r image_id; do
      [[ -n "$image_id" ]] || continue
      repo_tags="$("$REAL_DOCKER" image inspect --format '{{json .RepoTags}}' "$image_id" 2>/dev/null || true)"
      if [[ "$repo_tags" == "[]" || "$repo_tags" == "null" ]]; then
        "$REAL_DOCKER" image rm "$image_id" >/dev/null 2>&1 || true
      fi
    done < "$DANGLING_IMAGE_LIST"
  fi

  if [[ -n "$HOST_PID_LIST" && -f "$HOST_PID_LIST" ]]; then
    while IFS= read -r host_pid; do
      [[ "$host_pid" =~ ^[0-9]+$ ]] && kill "$host_pid" >/dev/null 2>&1 || true
    done < "$HOST_PID_LIST"
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
  IMAGE_LIST="${HARNESS_DIR}/images.list"
  HOST_PID_LIST="${HARNESS_DIR}/host-pids.list"
  DANGLING_IMAGE_LIST="${HARNESS_DIR}/dangling-images.list"
  STUB_DIR="${HARNESS_DIR}/stub-bin"
  SMOKE_CONFIG="${HARNESS_DIR}/config"
  SMOKE_ID="$(printf '%s' "${HARNESS_DIR##*.}" | tr '[:upper:]' '[:lower:]')"
  SMOKE_VERSION="smoke-${SMOKE_ID}"
  SMOKE_IMAGE="aibox:${SMOKE_VERSION}-node24"
  : > "$PROJECT_LIST"
  : > "$FOREIGN_LIST"
  : > "$IMAGE_LIST"
  : > "$HOST_PID_LIST"
  : > "$DANGLING_IMAGE_LIST"
  mkdir -p "$STUB_DIR" "$SMOKE_CONFIG"
  ln -s "${ROOT_DIR}/scripts/docker-stub.sh" "${STUB_DIR}/docker"
}

require_docker() {
  if ! docker_ready; then
    printf 'FAIL Docker CLI and a reachable local daemon are required\n' >&2
    exit 1
  fi
}

build_m3_images() {
  local build_dir="${HARNESS_DIR}/images"
  M3_VALID_IMAGE="aibox-smoke-${SMOKE_ID}:valid"
  M3_INDEPENDENT_IMAGE="aibox-smoke-${SMOKE_ID}:independent"
  M3_BAD_USER_IMAGE="aibox-smoke-${SMOKE_ID}:bad-user"
  M3_BAD_ENTRY_IMAGE="aibox-smoke-${SMOKE_ID}:bad-entry"
  M3_ROLLBACK_IMAGE="aibox-smoke-${SMOKE_ID}:rollback"
  mkdir -p "$build_dir"

  cat > "${build_dir}/Dockerfile.valid" <<DOCKERFILE
FROM ${SMOKE_IMAGE}
LABEL aibox.smoke.variant=valid
DOCKERFILE
  cat > "${build_dir}/Dockerfile.independent" <<'DOCKERFILE'
FROM node:24-bookworm
RUN userdel -r node 2>/dev/null || true; useradd -m -u 1000 aibox
ENV HOME=/home/aibox
USER aibox
WORKDIR /home/aibox
ENTRYPOINT ["sh", "-c", "exec \"$@\"", "independent-entry"]
DOCKERFILE
  cat > "${build_dir}/Dockerfile.bad-user" <<DOCKERFILE
FROM ${SMOKE_IMAGE}
USER root
DOCKERFILE
  cat > "${build_dir}/Dockerfile.bad-entry" <<DOCKERFILE
FROM ${SMOKE_IMAGE}
ENTRYPOINT ["sleep", "infinity"]
DOCKERFILE
  cat > "${build_dir}/Dockerfile.rollback" <<DOCKERFILE
FROM ${SMOKE_IMAGE}
ENTRYPOINT ["sh", "-c", "if [ \"\$PWD\" = \"/home/aibox\" ]; then exec \"\$@\"; else exit 42; fi", "aibox-entry"]
DOCKERFILE

  if "$REAL_DOCKER" build -q -f "${build_dir}/Dockerfile.valid" -t "$M3_VALID_IMAGE" "$build_dir" >/dev/null \
    && "$REAL_DOCKER" build -q -f "${build_dir}/Dockerfile.independent" -t "$M3_INDEPENDENT_IMAGE" "$build_dir" >/dev/null \
    && "$REAL_DOCKER" build -q -f "${build_dir}/Dockerfile.bad-user" -t "$M3_BAD_USER_IMAGE" "$build_dir" >/dev/null \
    && "$REAL_DOCKER" build -q -f "${build_dir}/Dockerfile.bad-entry" -t "$M3_BAD_ENTRY_IMAGE" "$build_dir" >/dev/null \
    && "$REAL_DOCKER" build -q -f "${build_dir}/Dockerfile.rollback" -t "$M3_ROLLBACK_IMAGE" "$build_dir" >/dev/null; then
    record_image "$M3_VALID_IMAGE"
    record_image "$M3_INDEPENDENT_IMAGE"
    record_image "$M3_BAD_USER_IMAGE"
    record_image "$M3_BAD_ENTRY_IMAGE"
    record_image "$M3_ROLLBACK_IMAGE"
    pass "Milestone 3 image fixtures build"
  else
    fail "Milestone 3 image fixtures build"
    return 1
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

test_limits_and_active_refusal() {
  local project="$1" name="$2" out err code before after nano memory swap pids cpu_max memory_max pids_max
  out="${HARNESS_DIR}/limits.out"
  err="${HARNESS_DIR}/limits.err"
  if ! run_aibox --dir "$project" up >"$out" 2>"$err"; then
    fail "create resource-limit sandbox"
    return
  fi
  before="$("$REAL_DOCKER" container inspect --format '{{.Id}}' "$name")"
  if run_aibox --dir "$project" up --cpus 1.5 --memory 256m --pids 50 >"$out" 2>"$err"; then
    after="$("$REAL_DOCKER" container inspect --format '{{.Id}}' "$name")"
    check_equal "live limits do not replace the sandbox" "$before" "$after"
  else
    fail "live limits apply"
    return
  fi
  read -r nano memory swap pids <<EOF
$("$REAL_DOCKER" container inspect --format '{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.HostConfig.PidsLimit}}' "$name")
EOF
  if [[ "$nano" == "1500000000" && "$memory" == "268435456" && "$swap" == "268435456" && "$pids" == "50" ]]; then
    pass "Docker records CPU, paired memory/swap, and process limits"
  else
    fail "Docker records CPU, paired memory/swap, and process limits (${nano} ${memory} ${swap} ${pids})"
  fi
  cpu_max="$(run_aibox --dir "$project" run sh -c 'cat /sys/fs/cgroup/cpu.max' 2>"$err")"
  memory_max="$(run_aibox --dir "$project" run sh -c 'cat /sys/fs/cgroup/memory.max' 2>>"$err")"
  pids_max="$(run_aibox --dir "$project" run sh -c 'cat /sys/fs/cgroup/pids.max' 2>>"$err")"
  if [[ "$cpu_max" == "150000 100000" && "$memory_max" == "268435456" && "$pids_max" == "50" ]]; then
    pass "cgroup files expose the requested limits inside the sandbox"
  else
    fail "cgroup files expose requested limits (${cpu_max}; ${memory_max}; ${pids_max})"
  fi

  if run_aibox --dir "$project" up --pids 0 >"$out" 2>"$err"; then
    pids="$("$REAL_DOCKER" container inspect --format '{{.HostConfig.PidsLimit}}' "$name")"
    pids_max="$(run_aibox --dir "$project" run sh -c 'cat /sys/fs/cgroup/pids.max' 2>>"$err")"
    if [[ "$pids" == "0" || "$pids" == "-1" ]] && [[ "$pids_max" == "max" ]]; then
      pass "process limit clears live"
    else
      fail "process limit clears live (inspect=${pids}, cgroup=${pids_max})"
    fi
  else
    fail "process limit clears live"
  fi

  set +e
  AIBOX_SMOKE_REAL_DOCKER="$REAL_DOCKER" \
    AIBOX_SMOKE_FAIL_COMMAND='update' \
    AIBOX_CONFIG_DIR="$SMOKE_CONFIG" \
    AIBOX_CLI_VERSION="$SMOKE_VERSION" \
    PATH="${STUB_DIR}:${PATH}" \
    "$AIBOX_BIN" --dir "$project" up --pids 75 >"$out" 2>"$err"
  code=$?
  set -e
  if [[ "$code" -eq 1 ]] \
    && grep -Fq 'synthetic docker update failure' "$err" \
    && grep -Fq 'Docker rejected the requested live resource update' "$err"; then
    pass "a rejected live update preserves Docker's diagnostic"
  else
    fail "a rejected live update preserves Docker's diagnostic"
  fi

  if run_aibox --dir "$project" up --cpus 2 >"$out" 2>"$err" \
    && run_aibox --dir "$project" up >>"$out" 2>>"$err"; then
    nano="$("$REAL_DOCKER" container inspect --format '{{.HostConfig.NanoCpus}}' "$name")"
    check_equal "omitted up flags preserve the CPU limit" "2000000000" "$nano"
  else
    fail "omitted up flags preserve the CPU limit"
  fi

  "$REAL_DOCKER" exec -d "$name" bash -c 'exec -a m3-active-sleep sleep 30'
  set +e
  run_aibox --dir "$project" up --cpus 0 >"$out" 2>"$err"
  code=$?
  set -e
  after="$("$REAL_DOCKER" container inspect --format '{{.Id}}' "$name")"
  if [[ "$code" -eq 1 && "$after" == "$before" ]] && grep -Fq "run 'aibox stop'" "$err"; then
    pass "replace-class CPU clear is refused while a process is active"
  else
    fail "replace-class CPU clear is refused while active"
  fi
  "$REAL_DOCKER" exec "$name" pkill -f m3-active-sleep >/dev/null 2>&1 || true
  sleep 0.2
  if run_aibox --dir "$project" up --cpus 0 >"$out" 2>"$err"; then
    after="$("$REAL_DOCKER" container inspect --format '{{.Id}}' "$name")"
    nano="$("$REAL_DOCKER" container inspect --format '{{.HostConfig.NanoCpus}}' "$name")"
    if [[ "$after" != "$before" && "$nano" == "0" ]]; then
      pass "CPU limit clear replaces an idle sandbox"
    else
      fail "CPU limit clear replaces an idle sandbox"
    fi
  else
    fail "CPU limit clear replaces an idle sandbox"
  fi

  before="$after"
  if run_aibox --dir "$project" up --memory 0 >"$out" 2>"$err"; then
    after="$("$REAL_DOCKER" container inspect --format '{{.Id}}' "$name")"
    read -r memory swap <<EOF
$("$REAL_DOCKER" container inspect --format '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}}' "$name")
EOF
    if [[ "$after" != "$before" && "$memory" == "0" && "$swap" == "0" ]]; then
      pass "memory limit clear replaces an idle sandbox and clears swap"
    else
      fail "memory limit clear replaces an idle sandbox and clears swap"
    fi
  else
    fail "memory limit clear replaces an idle sandbox and clears swap"
  fi

  if run_aibox --dir "$project" run tmux new-session -d -s m3-guard 'sleep 30' >"$out" 2>"$err"; then
    set +e
    run_aibox --dir "$project" up --image "$M3_VALID_IMAGE" >"$out" 2>"$err"
    code=$?
    set -e
    if [[ "$code" -eq 1 ]] && grep -Fq 'background processes are active' "$err"; then
      pass "tmux server blocks image replacement"
    else
      fail "tmux server blocks image replacement"
    fi
    run_aibox --dir "$project" run tmux kill-server >/dev/null 2>&1 || true
  else
    fail "start tmux activity fixture"
  fi
  sleep 0.2

  set +e
  AIBOX_SMOKE_REAL_DOCKER="$REAL_DOCKER" \
    AIBOX_SMOKE_FAIL_COMMAND='top' \
    AIBOX_CONFIG_DIR="$SMOKE_CONFIG" \
    AIBOX_CLI_VERSION="$SMOKE_VERSION" \
    PATH="${STUB_DIR}:${PATH}" \
    "$AIBOX_BIN" --dir "$project" up --image "$M3_VALID_IMAGE" >"$out" 2>"$err"
  code=$?
  set -e
  if [[ "$code" -eq 1 ]] && grep -Fiq 'cannot establish safety' "$err"; then
    pass "replacement refuses a failed docker top inspection"
  else
    fail "replacement refuses a failed docker top inspection"
  fi
}

test_custom_images_and_rollback() {
  local project="$1" name="$2" out err code before after state source
  out="${HARNESS_DIR}/images.out"
  err="${HARNESS_DIR}/images.err"
  run_aibox --dir "$project" up >"$out" 2>"$err" || { fail "create custom-image sandbox"; return; }
  before="$("$REAL_DOCKER" container inspect --format '{{.Id}}' "$name")"

  set +e
  run_aibox --dir "$project" up --image "$M3_BAD_USER_IMAGE" >"$out" 2>"$err"
  code=$?
  set -e
  after="$("$REAL_DOCKER" container inspect --format '{{.Id}}' "$name")"
  if [[ "$code" -eq 1 && "$after" == "$before" ]] && grep -Fq "configured user must be 'aibox'" "$err"; then
    pass "changed-user image is rejected before touching the sandbox"
  else
    fail "changed-user image is rejected before touching the sandbox"
  fi

  set +e
  run_aibox --dir "$project" up --image "$M3_BAD_ENTRY_IMAGE" >"$out" 2>"$err"
  code=$?
  set -e
  after="$("$REAL_DOCKER" container inspect --format '{{.Id}}' "$name")"
  if [[ "$code" -eq 1 && "$after" == "$before" ]] && grep -Fq 'entrypoint' "$err"; then
    pass "non-passthrough entrypoint is rejected before touching the sandbox"
  else
    fail "non-passthrough entrypoint is rejected before touching the sandbox"
  fi

  set +e
  run_aibox --dir "$project" up --image "$M3_ROLLBACK_IMAGE" >"$out" 2>"$err"
  code=$?
  set -e
  after="$("$REAL_DOCKER" container inspect --format '{{.Id}}' "$name")"
  state="$("$REAL_DOCKER" container inspect --format '{{.State.Status}}' "$name")"
  if [[ "$code" -eq 1 && "$after" == "$before" && "$state" == "running" ]] && grep -Fq 'previous sandbox was restored' "$err"; then
    pass "failed replacement restores a previously running sandbox"
  else
    fail "failed replacement restores a previously running sandbox"
  fi

  run_aibox --dir "$project" stop >/dev/null 2>"$err"
  set +e
  run_aibox --dir "$project" up --image "$M3_ROLLBACK_IMAGE" >"$out" 2>"$err"
  code=$?
  set -e
  after="$("$REAL_DOCKER" container inspect --format '{{.Id}}' "$name")"
  state="$("$REAL_DOCKER" container inspect --format '{{.State.Status}}' "$name")"
  if [[ "$code" -eq 1 && "$after" == "$before" && "$state" == "exited" ]]; then
    pass "failed replacement restores a previously stopped sandbox"
  else
    fail "failed replacement restores a previously stopped sandbox"
  fi

  if run_aibox --dir "$project" up >"$out" 2>"$err" \
    && run_aibox --dir "$project" up --image "$M3_VALID_IMAGE" >>"$out" 2>>"$err"; then
    source="$(_docker_label "$name" 'aibox.image-source')"
    check_equal "valid custom image becomes the recorded sandbox source" "custom" "$source"
  else
    fail "valid custom image replaces the sandbox"
  fi

  if run_aibox --dir "$project" up --image "$M3_INDEPENDENT_IMAGE" >"$out" 2>"$err" \
    && run_aibox --dir "$project" run sh -c 'test -f /tmp/aibox-ready' >>"$out" 2>>"$err"; then
    source="$(_docker_label "$name" 'aibox.image-source')"
    check_equal "independent compatible image reaches the shared readiness protocol" "custom" "$source"
  else
    fail "independent compatible image reaches the shared readiness protocol"
  fi
}

_docker_label() {
  "$REAL_DOCKER" container inspect --format "{{ index .Config.Labels \"$2\" }}" "$1"
}

test_concurrent_run_and_up() {
  local project="$1" name="$2" run_out run_err up_out up_err run_pid up_pid run_code up_code count
  run_out="${HARNESS_DIR}/race-run.out"; run_err="${HARNESS_DIR}/race-run.err"
  up_out="${HARNESS_DIR}/race-up.out"; up_err="${HARNESS_DIR}/race-up.err"
  run_aibox --dir "$project" run sh -c 'sleep 0.5; printf safe' >"$run_out" 2>"$run_err" & run_pid=$!
  run_aibox --dir "$project" up --image "$M3_VALID_IMAGE" >"$up_out" 2>"$up_err" & up_pid=$!
  set +e
  wait "$run_pid"; run_code=$?
  wait "$up_pid"; up_code=$?
  set -e
  count="$("$REAL_DOCKER" ps --all --quiet --filter "name=^/${name}$" | wc -l | tr -d ' ')"
  if [[ "$run_code" -eq 0 && "$(tr -d '\r\n' < "$run_out")" == "safe" && "$count" == "1" ]] \
    && ! grep -Fq 'No such container' "$run_err" \
    && { [[ "$up_code" -eq 0 ]] || grep -Fq 'session(s) are active' "$up_err"; }; then
    pass "concurrent run and image up never lose or kill the command"
  else
    fail "concurrent run and image up stay safe (run=${run_code}, up=${up_code}, count=${count})"
  fi
}

test_fingerprint_rebuild() {
  local project="$1" name="$2" out err before after old_image next
  out="${HARNESS_DIR}/fingerprint.out"; err="${HARNESS_DIR}/fingerprint.err"
  run_aibox --dir "$project" up >"$out" 2>"$err" || { fail "create fingerprint sandbox"; return; }
  run_aibox --dir "$project" run sh -c 'printf retained > "$HOME/.fingerprint-home"' >/dev/null 2>>"$err"
  before="$("$REAL_DOCKER" container inspect --format '{{.Id}}' "$name")"
  old_image="$("$REAL_DOCKER" container inspect --format '{{.Image}}' "$name")"
  printf '%s\n' "$old_image" >> "$DANGLING_IMAGE_LIST"
  printf 'LABEL aibox.smoke.fingerprint=%s\n' "$SMOKE_ID" > "${SMOKE_CONFIG}/Dockerfile.extra"
  if run_aibox --dir "$project" run true >"$out" 2>"$err"; then
    after="$("$REAL_DOCKER" container inspect --format '{{.Id}}' "$name")"
    if [[ "$after" == "$before" ]] && grep -Fq 'uses an older default image' "$err"; then
      pass "run rebuilds the stale tag but does not replace the sandbox"
    else
      fail "run reports a stale image without replacement"
    fi
  else
    fail "run handles a changed Dockerfile.extra"
  fi
  if run_aibox --dir "$project" up >"$out" 2>"$err"; then
    after="$("$REAL_DOCKER" container inspect --format '{{.Id}}' "$name")"
    if [[ "$after" != "$before" ]] \
      && run_aibox --dir "$project" run sh -c 'test "$(cat "$HOME/.fingerprint-home")" = retained' >/dev/null 2>>"$err"; then
      pass "up replaces for a new fingerprint and preserves private home"
    else
      fail "up replaces for a new fingerprint and preserves private home"
    fi
  else
    fail "up replaces for a new fingerprint"
  fi
  next="$after"
  if run_aibox --dir "$project" up --rebuild >"$out" 2>"$err"; then
    after="$("$REAL_DOCKER" container inspect --format '{{.Id}}' "$name")"
    [[ "$after" != "$next" ]] && pass "--rebuild explicitly replaces the idle sandbox" \
      || fail "--rebuild explicitly replaces the idle sandbox"
  else
    fail "--rebuild explicitly replaces the idle sandbox"
  fi
}

start_node_server() {
  local name="$1" project="$2" port="$3" host="$4" pid_file="$5" attempts=0
  "$REAL_DOCKER" exec -d "$name" node -e '
    const fs = require("fs"), http = require("http");
    fs.writeFileSync(process.argv[1], String(process.pid));
    http.createServer((req, res) => res.end("aibox-forward-ok")).listen(Number(process.argv[2]), process.argv[3]);
  ' "$pid_file" "$port" "$host"
  until [[ -s "$pid_file" ]]; do
    attempts=$((attempts + 1))
    (( attempts < 30 )) || return 1
    sleep 0.1
  done
}

stop_node_server() {
  local name="$1" pid_file="$2" pid
  [[ -f "$pid_file" ]] || return 0
  pid="$(tr -d '[:space:]' < "$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]] && "$REAL_DOCKER" exec "$name" kill "$pid" >/dev/null 2>&1 || true
  rm -f -- "$pid_file"
  sleep 0.2
}

wait_for_url() {
  local url="$1" attempts=0
  until curl -fsS --max-time 1 "$url" 2>/dev/null; do
    attempts=$((attempts + 1))
    (( attempts < 30 )) || return 1
    sleep 0.1
  done
}

test_forwarding_and_remove() {
  local project="$1" name="$2" other_project="$3" other_name="$4" out err code
  local forward_id forward_after binding state other_forward pid_file loop_pid_file marker host_pid
  out="${HARNESS_DIR}/forward.out"; err="${HARNESS_DIR}/forward.err"
  pid_file="${project}/server.pid"; loop_pid_file="${project}/loop-server.pid"
  run_aibox --dir "$project" up >"$out" 2>"$err" || { fail "create forwarding sandbox"; return; }
  if start_node_server "$name" "$project" 8080 0.0.0.0 "$pid_file" \
    && run_aibox --dir "$project" port-forward 18080:8080 >"$out" 2>"$err"; then
    forward_id="$("$REAL_DOCKER" ps --all --quiet --filter 'label=aibox.role=forward' --filter "label=aibox.path=${project}" --filter 'label=aibox.forward.host=18080')"
    binding="$("$REAL_DOCKER" port "$forward_id" 8080/tcp 2>/dev/null || true)"
    if [[ "$binding" == "127.0.0.1:18080" ]] && [[ "$(wait_for_url http://127.0.0.1:18080)" == "aibox-forward-ok" ]]; then
      pass "port forward is reachable and bound only to loopback"
    else
      fail "port forward is reachable and bound only to loopback (${binding})"
    fi
  else
    fail "create explicit port forward"
    return
  fi

  stop_node_server "$name" "$pid_file"
  if run_aibox --dir "$project" up --image "$M3_VALID_IMAGE" >"$out" 2>"$err"; then
    forward_after="$("$REAL_DOCKER" ps --all --quiet --filter 'label=aibox.role=forward' --filter "label=aibox.path=${project}" --filter 'label=aibox.forward.host=18080')"
    if start_node_server "$name" "$project" 8080 0.0.0.0 "$pid_file" \
      && [[ "$forward_after" == "$forward_id" ]] \
      && [[ "$(wait_for_url http://127.0.0.1:18080)" == "aibox-forward-ok" ]]; then
      pass "forward survives sandbox replacement without sidecar replacement"
    else
      fail "forward survives sandbox replacement without sidecar replacement"
    fi
  else
    fail "replace sandbox behind a forward"
  fi
  stop_node_server "$name" "$pid_file"

  if start_node_server "$name" "$project" 8081 127.0.0.1 "$loop_pid_file" \
    && run_aibox --dir "$project" port-forward 18081:8081 >"$out" 2>"$err"; then
    set +e
    curl -fsS --max-time 1 http://127.0.0.1:18081 >/dev/null 2>&1
    code=$?
    set -e
    if [[ "$code" -ne 0 ]] && grep -Fq 'listens on 0.0.0.0' "$err"; then
      pass "container-loopback server fails with the documented diagnosis"
    else
      fail "container-loopback server fails with the documented diagnosis"
    fi
  else
    fail "create loopback-only server fixture"
  fi
  stop_node_server "$name" "$loop_pid_file"
  if run_aibox --dir "$project" port-forward --list >"$out" 2>"$err" \
    && grep -Fq '127.0.0.1:18080' "$out" \
    && grep -Fq '127.0.0.1:18081' "$out"; then
    pass "port-forward --list reports project forwards"
  else
    fail "port-forward --list reports project forwards"
  fi
  if run_aibox --dir "$project" port-forward --stop 18081 >"$out" 2>"$err" \
    && [[ -z "$("$REAL_DOCKER" ps --all --quiet --filter 'label=aibox.role=forward' --filter "label=aibox.path=${project}" --filter 'label=aibox.forward.host=18081')" ]]; then
    pass "port-forward --stop removes one host port"
  else
    fail "port-forward --stop removes one host port"
  fi

  if run_aibox --dir "$other_project" port-forward 18082:8082 >"$out" 2>"$err"; then
    other_forward="$("$REAL_DOCKER" ps --all --quiet --filter 'label=aibox.role=forward' --filter "label=aibox.path=${other_project}" --filter 'label=aibox.forward.host=18082')"
  else
    fail "create other-project forward fixture"
    other_forward=""
  fi

  if run_aibox --dir "$project" stop >"$out" 2>"$err"; then
    state="$("$REAL_DOCKER" container inspect --format '{{.State.Status}}' "$forward_id")"
    check_equal "stop stops project forwarders" "exited" "$state"
  else
    fail "stop stops project forwarders"
  fi
  if run_aibox --dir "$project" up >"$out" 2>"$err"; then
    state="$("$REAL_DOCKER" container inspect --format '{{.State.Status}}' "$forward_id")"
    check_equal "up restarts stopped forwarders" "running" "$state"
  else
    fail "up restarts stopped forwarders"
  fi
  if run_aibox --dir "$project" port-forward --stop-all >"$out" 2>"$err"; then
    if [[ -z "$("$REAL_DOCKER" ps --all --quiet --filter 'label=aibox.role=forward' --filter "label=aibox.path=${project}")" ]] \
      && [[ -n "$other_forward" ]] && "$REAL_DOCKER" container inspect "$other_forward" >/dev/null 2>&1; then
      pass "stop-all removes only this project's forwarders"
    else
      fail "stop-all removes only this project's forwarders"
    fi
  else
    fail "port-forward --stop-all"
  fi

  python3 -m http.server 18083 --bind 127.0.0.1 >"${HARNESS_DIR}/host-port.log" 2>&1 &
  host_pid=$!
  printf '%s\n' "$host_pid" >> "$HOST_PID_LIST"
  sleep 0.3
  set +e
  run_aibox --dir "$project" port-forward 18083:8083 >"$out" 2>"$err"
  code=$?
  set -e
  if [[ "$code" -eq 1 ]] && grep -Fq 'host port may already be in use' "$err"; then
    pass "host-port conflict is actionable"
  else
    fail "host-port conflict is actionable"
  fi
  kill "$host_pid" >/dev/null 2>&1 || true

  marker="${project}/remove-home-marker"
  run_aibox --dir "$project" run sh -c 'printf retained > "$HOME/.remove-marker"' >/dev/null 2>"$err"
  run_aibox --dir "$project" port-forward 18080:8080 >"$out" 2>"$err"
  if run_aibox --dir "$project" remove >"$out" 2>"$err"; then
    if ! "$REAL_DOCKER" container inspect "$name" >/dev/null 2>&1 \
      && ! "$REAL_DOCKER" network inspect "$name" >/dev/null 2>&1 \
      && "$REAL_DOCKER" volume inspect "$name" >/dev/null 2>&1 \
      && grep -Fq 'was retained' "$err"; then
      pass "remove deletes runtime resources and reports retained home"
    else
      fail "remove deletes runtime resources and reports retained home"
    fi
  else
    fail "remove retains private home"
  fi
  if run_aibox --dir "$project" up >"$out" 2>"$err" \
    && run_aibox --dir "$project" run sh -c 'test "$(cat "$HOME/.remove-marker")" = retained' >/dev/null 2>>"$err"; then
    pass "retained home returns with a recreated sandbox"
  else
    fail "retained home returns with a recreated sandbox"
  fi
  if run_aibox --dir "$project" remove --purge --yes >"$out" 2>"$err"; then
    if ! "$REAL_DOCKER" container inspect "$name" >/dev/null 2>&1 \
      && ! "$REAL_DOCKER" network inspect "$name" >/dev/null 2>&1 \
      && ! "$REAL_DOCKER" volume inspect "$name" >/dev/null 2>&1; then
      pass "remove --purge --yes deletes the private home"
    else
      fail "remove --purge --yes deletes the private home"
    fi
  else
    fail "remove --purge --yes"
  fi

  [[ -n "$other_name" && -n "$marker" ]]
}

test_address_pool_failure() {
  local project="$1" out="${HARNESS_DIR}/network.out" err="${HARNESS_DIR}/network.err" code
  set +e
  AIBOX_SMOKE_REAL_DOCKER="$REAL_DOCKER" \
    AIBOX_SMOKE_FAIL_COMMAND='network' \
    AIBOX_CONFIG_DIR="$SMOKE_CONFIG" \
    AIBOX_CLI_VERSION="$SMOKE_VERSION" \
    PATH="${STUB_DIR}:${PATH}" \
    "$AIBOX_BIN" --dir "$project" up >"$out" 2>"$err"
  code=$?
  set -e
  if [[ "$code" -eq 1 ]] && grep -Fq 'default-address-pools' "$err"; then
    pass "network creation failure names Docker address pools"
  else
    fail "network creation failure names Docker address pools"
  fi
}

main() {
  local project_one project_two project_foreign name_one name_foreign
  local project_limits project_images project_race project_fingerprint project_forward project_other project_network
  local name_limits name_images name_race name_fingerprint name_forward name_other
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

  build_m3_images || {
    printf 'Smoke harness complete: %s checks, %s failures\n' "$CHECKS" "$FAILURES"
    return 1
  }
  project_limits="$(new_project)"; name_limits="$(project_name "$project_limits")"
  project_images="$(new_project)"; name_images="$(project_name "$project_images")"
  project_race="$(new_project)"; name_race="$(project_name "$project_race")"
  project_fingerprint="$(new_project)"; name_fingerprint="$(project_name "$project_fingerprint")"
  project_forward="$(new_project)"; name_forward="$(project_name "$project_forward")"
  project_other="$(new_project)"; name_other="$(project_name "$project_other")"
  project_network="$(new_project)"

  test_limits_and_active_refusal "$project_limits" "$name_limits"
  test_custom_images_and_rollback "$project_images" "$name_images"
  test_concurrent_run_and_up "$project_race" "$name_race"
  test_forwarding_and_remove "$project_forward" "$name_forward" "$project_other" "$name_other"
  test_address_pool_failure "$project_network"
  test_fingerprint_rebuild "$project_fingerprint" "$name_fingerprint"

  printf 'Smoke harness complete: %s checks, %s failures\n' "$CHECKS" "$FAILURES"
  [[ "$FAILURES" -eq 0 ]]
}

main "$@"
