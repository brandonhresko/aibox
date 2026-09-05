#!/usr/bin/env bash
# Test-only Docker wrapper. The smoke harness puts this file first on PATH to
# make one selected Docker subcommand fail, then delegates every other call to
# the real CLI. It never changes Docker behavior unless both variables are set.

set -u

real_docker="${AIBOX_SMOKE_REAL_DOCKER:?AIBOX_SMOKE_REAL_DOCKER is required}"
fail_command="${AIBOX_SMOKE_FAIL_COMMAND:-}"
fail_status="${AIBOX_SMOKE_FAIL_STATUS:-1}"
fake_endpoint="${AIBOX_SMOKE_DOCKER_ENDPOINT:-}"

if [[ -n "$fake_endpoint" && "${1:-}" == "context" && "${2:-}" == "inspect" ]]; then
  printf '%s\n' "$fake_endpoint"
  exit 0
fi

if [[ -n "$fail_command" && "${1:-}" == "$fail_command" ]]; then
  printf 'synthetic docker %s failure\n' "$fail_command" >&2
  exit "$fail_status"
fi

exec "$real_docker" "$@"
