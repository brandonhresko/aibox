#!/usr/bin/env bash
# Test-only Docker wrapper. The smoke harness puts this file first on PATH to
# make one selected Docker subcommand fail, then delegates every other call to
# the real CLI. It never changes Docker behavior unless both variables are set.

set -u

real_docker="${AIBOX_SMOKE_REAL_DOCKER:?AIBOX_SMOKE_REAL_DOCKER is required}"
fail_command="${AIBOX_SMOKE_FAIL_COMMAND:-}"
fail_status="${AIBOX_SMOKE_FAIL_STATUS:-1}"
fake_endpoint="${AIBOX_SMOKE_DOCKER_ENDPOINT:-}"
interrupt_sandbox="${AIBOX_SMOKE_INTERRUPT_SANDBOX:-}"
interrupt_stage="${AIBOX_SMOKE_INTERRUPT_STAGE:-before-create}"
build_barrier="${AIBOX_SMOKE_BUILD_BARRIER:-}"
local_endpoint=""
if [[ "${1:-}" == --host ]]; then
  local_endpoint="$2"
  shift 2
fi

real_call() {
  if [[ -n "$local_endpoint" ]]; then
    "$real_docker" --host "$local_endpoint" "$@"
  else
    "$real_docker" "$@"
  fi
}

if [[ -n "$fake_endpoint" && "${1:-}" == "context" && "${2:-}" == "inspect" ]]; then
  printf '%s\n' "$fake_endpoint"
  exit 0
fi

if [[ -n "$fail_command" && "${1:-}" == "$fail_command" ]]; then
  printf 'synthetic docker %s failure\n' "$fail_command" >&2
  exit "$fail_status"
fi

# Interrupt only the persistent replacement, never a custom-image probe.
if [[ -n "$interrupt_sandbox" ]] \
  && real_call container inspect "${interrupt_sandbox}.prev" >/dev/null 2>&1; then
  if [[ "$interrupt_stage" == before-create && "${1:-}" == create \
    && "${2:-}" == --name && "${3:-}" == "$interrupt_sandbox" ]]; then
    kill -s "${AIBOX_SMOKE_INTERRUPT_SIGNAL:-TERM}" "$PPID"
    exit 130
  elif [[ "$interrupt_stage" == after-start && "${1:-}" == start && "${2:-}" == "$interrupt_sandbox" ]]; then
    real_call "$@" || exit $?
    kill -s "${AIBOX_SMOKE_INTERRUPT_SIGNAL:-TERM}" "$PPID"
    exit 130
  fi
fi

# Hold real builds at a deterministic barrier while another project snapshots
# its inputs. The harness checks both contexts before releasing the builds.
if [[ -n "$build_barrier" && "${1:-}" == build ]]; then
  printf '%s\n' "${!#}" > "${build_barrier}/$$.context"
  attempts=0
  while [[ ! -f "${build_barrier}/release" ]]; do
    attempts=$((attempts + 1))
    (( attempts < 1000 )) || { printf 'Build barrier timed out\n' >&2; exit 1; }
    sleep 0.1
  done
fi

if [[ -n "$local_endpoint" ]]; then
  exec "$real_docker" --host "$local_endpoint" "$@"
fi
exec "$real_docker" "$@"
