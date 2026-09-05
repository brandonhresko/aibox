#!/usr/bin/env bash
# Real-Docker smoke harness for the prototype milestones. Milestone 1 defines
# the safe scaffolding only; lifecycle checks are added with their features.

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
AIBOX_BIN="${AIBOX_BIN:-${ROOT_DIR}/bin/aibox}"
REAL_DOCKER="${AIBOX_SMOKE_REAL_DOCKER:-$(command -v docker 2>/dev/null || true)}"
TMP_BASE="${TMPDIR:-/tmp}"
HARNESS_DIR=""
PROJECT_LIST=""
STUB_DIR=""
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

record_project() {
  local project="$1"
  printf '%s\n' "$project" >> "$PROJECT_LIST"
}

new_project() {
  local project
  project="$(mktemp -d "${HARNESS_DIR}/smk-project.XXXXXX")" || return 1
  record_project "$project"
  printf '%s\n' "$project"
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
      network)   "$REAL_DOCKER" network rm "$id" >/dev/null 2>&1 || true ;;
      volume)    "$REAL_DOCKER" volume rm --force "$id" >/dev/null 2>&1 || true ;;
      image)     "$REAL_DOCKER" image rm --force "$id" >/dev/null 2>&1 || true ;;
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
  local project image_ids
  trap - EXIT HUP INT TERM

  if [[ -n "$PROJECT_LIST" && -f "$PROJECT_LIST" ]] && docker_ready; then
    while IFS= read -r project; do
      [[ -n "$project" ]] && cleanup_project_resources "$project"
    done < "$PROJECT_LIST"

    image_ids="$("$REAL_DOCKER" image ls --quiet \
      --filter "label=aibox.smoke-run=${HARNESS_DIR##*/}" 2>/dev/null || true)"
    remove_ids image "$image_ids"
  fi

  case "$HARNESS_DIR" in
    "${TMP_BASE%/}"/smk-aibox.*) rm -rf -- "$HARNESS_DIR" ;;
  esac
}

on_signal() {
  exit 130
}

require_docker() {
  if ! docker_ready; then
    printf 'FAIL Docker CLI and a reachable local daemon are required\n' >&2
    return 1
  fi
}

create_home_fixture() {
  local project="$1" volume="$2"
  require_docker || return 1
  "$REAL_DOCKER" volume create \
    --label 'aibox.schema=3' \
    --label "aibox.path=${project}" \
    --label 'aibox.role=sandbox' \
    "$volume" >/dev/null || return 1
  "$REAL_DOCKER" run --rm \
    --mount "type=volume,src=${volume},dst=/home/aibox" \
    alpine:3.20 sh -c '
      mkdir -p /home/aibox/.config/fake-agent /home/aibox/.local/state/fake-agent
      printf synthetic-login > /home/aibox/.config/fake-agent/auth
      printf synthetic-session > /home/aibox/.local/state/fake-agent/session
      printf synthetic-history > /home/aibox/.shell_history
    '
}

run_with_docker_failure() {
  local command="$1"
  shift
  AIBOX_SMOKE_REAL_DOCKER="$REAL_DOCKER" \
    AIBOX_SMOKE_FAIL_COMMAND="$command" \
    PATH="${STUB_DIR}:${PATH}" \
    "$@"
}

setup() {
  [[ -x "$AIBOX_BIN" ]] || {
    printf 'Smoke harness: CLI is not executable: %s\n' "$AIBOX_BIN" >&2
    exit 1
  }
  HARNESS_DIR="$(mktemp -d "${TMP_BASE%/}/smk-aibox.XXXXXX")" || exit 1
  PROJECT_LIST="${HARNESS_DIR}/projects.list"
  STUB_DIR="${HARNESS_DIR}/stub-bin"
  : > "$PROJECT_LIST"
  mkdir -p "$STUB_DIR"
  ln -s "${ROOT_DIR}/scripts/docker-stub.sh" "${STUB_DIR}/docker"
}

main() {
  setup
  trap cleanup EXIT
  trap on_signal HUP INT TERM

  # Milestone 1 intentionally runs no behavior checks. Later milestones use
  # new_project, create_home_fixture, run_with_docker_failure, and the
  # PASS/FAIL reporters above as each guarantee is implemented.

  printf 'Smoke harness complete: %s checks, %s failures\n' "$CHECKS" "$FAILURES"
  [[ "$FAILURES" -eq 0 ]]
}

main "$@"
