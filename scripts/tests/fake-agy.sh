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
use_stream=0
prev=""
for arg in "$@"; do
    if [[ "$prev" == "--output-format" && "$arg" == "json" ]]; then use_json=1; fi
    if [[ "$prev" == "--output-format" && "$arg" == "stream-json" ]]; then use_stream=1; fi
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

# write_stream emits the agy 1.2.7 stream-json event sequence for $1 (the response text):
# init, a DONE user_input step, the response split into two agent_response deltas (with an
# optional sleep between them for liveness tests), an optional tool ACTIVE/DONE pair with a
# TOOL_ERROR, then a final result event (unless FAKE_AGY_NO_RESULT/FAKE_NO_RESULT is set).
write_stream() {
    if [[ "${FAKE_AGY_BOM:-}" == "1" ]]; then
        printf '\xEF\xBB\xBF'
    fi
    local response_file
    response_file="$(mktemp "${TMPDIR:-/tmp}/fake_agy_stream_response.XXXXXX")"
    if [[ -n "${FAKE_AGY_RESPONSE_FILE:-}" ]]; then
        cat "$FAKE_AGY_RESPONSE_FILE" >"$response_file"
    else
        printf '%s' "$1" >"$response_file"
    fi
    local encoder; encoder="$(json_encoder || true)"
    local delay="${FAKE_STREAM_DELAY:-${FAKE_AGY_STREAM_DELAY:-}}"
    local tool_event=0
    [[ "${FAKE_TOOL_EVENT:-}" == "1" || "${FAKE_AGY_TOOL_EVENT:-}" == "1" ]] && tool_event=1
    local no_result=0
    [[ "${FAKE_NO_RESULT:-}" == "1" || "${FAKE_AGY_NO_RESULT:-}" == "1" ]] && no_result=1
    case "$encoder" in
        python3|python)
            "$encoder" - "$response_file" "${FAKE_AGY_STATUS:-SUCCESS}" "${FAKE_AGY_DENIED:-}" "${FAKE_AGY_DENIED_SHAPE:-}" "$delay" "$tool_event" "$no_result" <<'PYEOF'
import json, sys, time
try:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", newline="")
except Exception:
    pass

response_file, status, denied_raw, shape, delay, tool_event, no_result = sys.argv[1:8]
with open(response_file, encoding="utf-8", newline="") as f:
    response = f.read()

def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False))
    sys.stdout.write("\n")
    sys.stdout.flush()

emit({"event": "init", "conversation_id": "fake", "init": {}})
emit({"event": "step_update", "step_update": {"conversation_id": "fake", "step_index": 0, "state": "DONE", "step_type": "user_input"}})

if response:
    half = (len(response) + 1) // 2
    first, rest = response[:half], response[half:]
    emit({"event": "step_update", "step_update": {"conversation_id": "fake", "step_index": 1, "state": "ACTIVE", "step_type": "agent_response", "text_delta": first}})
    if delay:
        time.sleep(float(delay))
    emit({"event": "step_update", "step_update": {"conversation_id": "fake", "step_index": 1, "state": "DONE", "step_type": "agent_response", "text_delta": rest}})

if tool_event == "1":
    emit({"event": "step_update", "step_update": {"conversation_id": "fake", "step_index": 2, "state": "ACTIVE", "step_type": "tool", "tool_name": "run_command", "tool_info": {"parameters": {"command": "echo hi"}}}})
    emit({"event": "step_update", "step_update": {"conversation_id": "fake", "step_index": 2, "state": "DONE", "step_type": "tool", "tool_name": "run_command", "tool_info": {"parameters": {"command": "echo hi"}, "error": {"type": "TOOL_ERROR", "message": "context canceled"}}}})

if no_result != "1":
    result = {"conversation_id": "fake", "status": status, "response": response, "duration_seconds": 0, "num_turns": 1, "usage": {}}
    if denied_raw:
        pairs = []
        for entry in denied_raw.split(","):
            action, _, display = entry.partition(":")
            pairs.append({"action": action, "display_name": display})
        if shape == "object":
            result["denied_actions"] = pairs[0]
        elif shape == "number":
            result["denied_actions"] = 42
        else:
            result["denied_actions"] = pairs
    emit({"event": "result", "result": result})
PYEOF
            ;;
        node)
            node -e '
const fs = require("fs");
const response = fs.readFileSync(process.argv[1], "utf-8");
const status = process.argv[2] || "SUCCESS";
const deniedRaw = process.argv[3] || "";
const shape = process.argv[4] || "";
const delay = process.argv[5] || "";
const toolEvent = process.argv[6] === "1";
const noResult = process.argv[7] === "1";

function emit(obj) {
    process.stdout.write(JSON.stringify(obj));
    process.stdout.write("\n");
}

function main() {
    emit({event: "init", conversation_id: "fake", init: {}});
    emit({event: "step_update", step_update: {conversation_id: "fake", step_index: 0, state: "DONE", step_type: "user_input"}});
    finish();
}

function finish() {
    if (response) {
        const half = Math.ceil(response.length / 2);
        const first = response.slice(0, half);
        const rest = response.slice(half);
        emit({event: "step_update", step_update: {conversation_id: "fake", step_index: 1, state: "ACTIVE", step_type: "agent_response", text_delta: first}});
        const after = () => {
            emit({event: "step_update", step_update: {conversation_id: "fake", step_index: 1, state: "DONE", step_type: "agent_response", text_delta: rest}});
            afterDeltas();
        };
        if (delay) { setTimeout(after, parseFloat(delay) * 1000); } else { after(); }
    } else {
        afterDeltas();
    }
}

function afterDeltas() {
    if (toolEvent) {
        emit({event: "step_update", step_update: {conversation_id: "fake", step_index: 2, state: "ACTIVE", step_type: "tool", tool_name: "run_command", tool_info: {parameters: {command: "echo hi"}}}});
        emit({event: "step_update", step_update: {conversation_id: "fake", step_index: 2, state: "DONE", step_type: "tool", tool_name: "run_command", tool_info: {parameters: {command: "echo hi"}, error: {type: "TOOL_ERROR", message: "context canceled"}}}});
    }
    if (!noResult) {
        const result = {conversation_id: "fake", status, response, duration_seconds: 0, num_turns: 1, usage: {}};
        if (deniedRaw) {
            const pairs = deniedRaw.split(",").map(e => {
                const idx = e.indexOf(":");
                return {action: e.slice(0, idx), display_name: e.slice(idx + 1)};
            });
            if (shape === "object") result.denied_actions = pairs[0];
            else if (shape === "number") result.denied_actions = 42;
            else result.denied_actions = pairs;
        }
        emit({event: "result", result});
    }
}

main();
' "$response_file" "${FAKE_AGY_STATUS:-SUCCESS}" "${FAKE_AGY_DENIED:-}" "${FAKE_AGY_DENIED_SHAPE:-}" "$delay" "$tool_event" "$no_result"
            ;;
        *)
            # jq/no-parser: emit a minimal non-streaming fallback so plain-text tests still see output.
            printf '%s' "$response"
            ;;
    esac
    rm -f "$response_file"
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

if [[ "$use_stream" -eq 1 ]]; then
    write_stream "${FAKE_AGY_OUTPUT:-}"
elif [[ "$use_json" -eq 1 ]]; then
    write_envelope "${FAKE_AGY_OUTPUT:-}"
else
    [[ -z "${FAKE_AGY_OUTPUT+x}" ]] || printf '%s\n' "$FAKE_AGY_OUTPUT"
fi
exit "${FAKE_AGY_EXIT:-0}"
