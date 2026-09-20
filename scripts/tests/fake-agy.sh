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

json_encoder() {
    # command -v alone is not enough on some Windows setups, where a PATH entry for
    # python3/python is a broken App Execution Alias stub; verify each candidate actually runs.
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then printf 'python3'; return 0; fi
    if command -v python >/dev/null 2>&1 && python -c 'import json' >/dev/null 2>&1; then printf 'python'; return 0; fi
    if command -v jq >/dev/null 2>&1; then printf 'jq'; return 0; fi
    if command -v node >/dev/null 2>&1 && node -e '1' >/dev/null 2>&1; then printf 'node'; return 0; fi
    return 1
}

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g' -e 's/\r/\\r/g' -e 's/\t/\\t/g'
}

write_envelope_manual() {
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
    printf '%s' "$json"
}

write_envelope() {
    # Pass the response body via a temp file, never argv, so large payloads (e.g. multi-MB
    # test fixtures) do not hit the OS argument-list-too-long limit.
    local response_file
    response_file="$(mktemp "${TMPDIR:-/tmp}/fake_agy_response.XXXXXX")"
    if [[ -n "${FAKE_AGY_RESPONSE_FILE:-}" ]]; then
        cat "$FAKE_AGY_RESPONSE_FILE" >"$response_file"
    else
        printf '%s' "$1" >"$response_file"
    fi
    local encoder; encoder="$(json_encoder || true)"
    local out=""
    case "$encoder" in
        python3|python)
            out="$("$encoder" - "$response_file" "${FAKE_AGY_STATUS:-SUCCESS}" "${FAKE_AGY_DENIED:-}" "${FAKE_AGY_DENIED_SHAPE:-}" <<'PYEOF'
import json, sys
try:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", newline="")
except Exception:
    pass
response_file, status, denied_raw, shape = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(response_file, encoding="utf-8", newline="") as f:
    response = f.read()
data = {"conversation_id": "fake", "status": status, "response": response, "num_turns": 1}
if denied_raw:
    pairs = []
    for entry in denied_raw.split(","):
        action, _, display = entry.partition(":")
        pairs.append({"action": action, "display_name": display})
    if shape == "object":
        data["denied_actions"] = pairs[0]
    elif shape == "number":
        data["denied_actions"] = 42
    else:
        data["denied_actions"] = pairs
sys.stdout.write(json.dumps(data, ensure_ascii=False))
PYEOF
)" ;;
        jq)
            local denied_json="[]"
            if [[ -n "${FAKE_AGY_DENIED:-}" ]]; then
                local pairs="" first=1
                IFS=',' read -ra entries <<<"$FAKE_AGY_DENIED"
                for entry in "${entries[@]}"; do
                    local action="${entry%%:*}" display="${entry#*:}"
                    [[ "$first" -eq 1 ]] || pairs+=","
                    pairs+="{\"action\":$(printf '%s' "$action" | jq -Rs .),\"display_name\":$(printf '%s' "$display" | jq -Rs .)}"
                    first=0
                done
                denied_json="[$pairs]"
            fi
            out="$(jq -cn --rawfile response "$response_file" --arg status "${FAKE_AGY_STATUS:-SUCCESS}" --argjson denied "$denied_json" '
                {conversation_id:"fake", status:$status, response:$response, num_turns:1}
                + (if ($denied|length) == 0 then {} else
                    if "'"${FAKE_AGY_DENIED_SHAPE:-}"'" == "object" then {denied_actions:$denied[0]}
                    elif "'"${FAKE_AGY_DENIED_SHAPE:-}"'" == "number" then {denied_actions:42}
                    else {denied_actions:$denied} end
                  end)
            ')" ;;
        node)
            out="$(node -e '
const fs = require("fs");
const response = fs.readFileSync(process.argv[1], "utf-8");
const status = process.argv[2] || "SUCCESS";
const deniedRaw = process.argv[3] || "";
const shape = process.argv[4] || "";
const data = {conversation_id: "fake", status, response, num_turns: 1};
if (deniedRaw) {
    const pairs = deniedRaw.split(",").map(e => {
        const idx = e.indexOf(":");
        return {action: e.slice(0, idx), display_name: e.slice(idx + 1)};
    });
    if (shape === "object") data.denied_actions = pairs[0];
    else if (shape === "number") data.denied_actions = 42;
    else data.denied_actions = pairs;
}
process.stdout.write(JSON.stringify(data));
' "$response_file" "${FAKE_AGY_STATUS:-SUCCESS}" "${FAKE_AGY_DENIED:-}" "${FAKE_AGY_DENIED_SHAPE:-}")" ;;
        *)
            out="$(write_envelope_manual "$(cat "$response_file")")" ;;
    esac
    rm -f "$response_file"
    if [[ "${FAKE_AGY_BOM:-}" == "1" ]]; then
        printf '\xEF\xBB\xBF'
    fi
    printf '%s\n' "$out"
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
