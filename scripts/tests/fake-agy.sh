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

use_json=0
prev=""
for arg in "$@"; do
    if [[ "$prev" == "--output-format" && "$arg" == "json" ]]; then use_json=1; fi
    prev="$arg"
done

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g' -e 's/\r/\\r/g' -e 's/\t/\\t/g'
}

write_envelope() {
    local response="$1" status="${FAKE_AGY_STATUS:-SUCCESS}"
    local escaped; escaped="$(json_escape "$response")"
    local json="{\"conversation_id\":\"fake\",\"status\":\"$status\",\"response\":\"$escaped\",\"num_turns\":1"
    if [[ -n "${FAKE_AGY_DENIED:-}" ]]; then
        local pairs="" first=1
        IFS=',' read -ra entries <<<"$FAKE_AGY_DENIED"
        for entry in "${entries[@]}"; do
            local action="${entry%%:*}" display="${entry#*:}"
            [[ "$first" -eq 1 ]] || pairs+=","
            pairs+="{\"action\":\"$action\",\"display_name\":\"$display\"}"
            first=0
        done
        json+=",\"denied_actions\":[$pairs]"
    fi
    json+="}"
    printf '%s\n' "$json"
}

if [[ -n "${FAKE_AGY_RAW:-}" ]]; then
    printf '%s\n' "$FAKE_AGY_RAW"
    exit "${FAKE_AGY_EXIT:-0}"
fi

if [[ "${FAKE_AGY_RAW_EMPTY:-}" == "1" ]]; then
    exit "${FAKE_AGY_EXIT:-0}"
fi

if [[ -n "${FAKE_AGY_EXIT:-}" && "${FAKE_AGY_EXIT:-0}" -ne 0 ]]; then
    # Fatal-error mode: agy exits non-zero without emitting JSON, same as today.
    [[ -z "${FAKE_AGY_OUTPUT+x}" ]] || printf '%s\n' "$FAKE_AGY_OUTPUT"
    exit "$FAKE_AGY_EXIT"
fi

if [[ "$use_json" -eq 1 ]]; then
    write_envelope "${FAKE_AGY_OUTPUT:-}"
else
    [[ -z "${FAKE_AGY_OUTPUT+x}" ]] || printf '%s\n' "$FAKE_AGY_OUTPUT"
fi
exit "${FAKE_AGY_EXIT:-0}"
