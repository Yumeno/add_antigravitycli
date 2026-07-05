#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_AGY_ARGV:?FAKE_AGY_ARGV is required}"
: "${FAKE_AGY_STDIN:?FAKE_AGY_STDIN is required}"
printf '%s\n' "$@" >"$FAKE_AGY_ARGV"
cat >"$FAKE_AGY_STDIN"
if [[ -n "${FAKE_AGY_WRITE_FILE:-}" ]]; then
    printf '%s\n' "${FAKE_AGY_WRITE_CONTENT:-fake change}" >"$FAKE_AGY_WRITE_FILE"
fi
[[ -z "${FAKE_AGY_SLEEP:-}" ]] || sleep "$FAKE_AGY_SLEEP"
[[ -z "${FAKE_AGY_STDERR:-}" ]] || printf '%s\n' "$FAKE_AGY_STDERR" >&2
[[ -z "${FAKE_AGY_OUTPUT+x}" ]] || printf '%s\n' "$FAKE_AGY_OUTPUT"
exit "${FAKE_AGY_EXIT:-0}"
