#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WRAPPER="$HERE/../antigravity-wrapper.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agy_wrapper_test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir "$ROOT/bin" "$ROOT/work"
cp "$HERE/fake-agy.sh" "$ROOT/bin/agy"; chmod +x "$ROOT/bin/agy"
export FAKE_AGY_ARGV="$ROOT/argv" FAKE_AGY_STDIN="$ROOT/stdin"
export ANTIGRAVITY_WRAPPER_CONFIG="$ROOT/config"
passed=0; total=0
check() {
    local name="$1"; shift
    total=$((total+1))
    if "$@"; then printf 'PASS: %s\n' "$name"; passed=$((passed+1)); else printf 'FAIL: %s\n' "$name"; fi
}

t_stdin() {
    export FAKE_AGY_OUTPUT=ok
    payload=$'日本語 "quote"\nsecond line'
    PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt "$payload" --workdir "$ROOT/work" >/dev/null 2>/dev/null &&
        [[ "$(cat "$ROOT/stdin")" == $'## Request\n\n'"$payload" ]] && ! grep -qF '日本語' "$ROOT/argv"
}
t_args() {
    export FAKE_AGY_OUTPUT=ok
    PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi --model gemini/test --sandbox --timeout 9 >/dev/null 2>/dev/null &&
        ! grep -qx -- '--print' "$ROOT/argv" && grep -qx -- '--print-timeout' "$ROOT/argv" &&
        grep -qx -- '9s' "$ROOT/argv" && grep -qx -- 'gemini/test' "$ROOT/argv" &&
        grep -qx -- '--sandbox' "$ROOT/argv" && grep -qx -- '--disable-slash-commands' "$ROOT/argv" && grep -qx -- '--new-project' "$ROOT/argv" &&
        grep -qx -- '--add-dir' "$ROOT/argv" &&
        grep -qx -- '--output-format' "$ROOT/argv" &&
        { grep -qx -- 'stream-json' "$ROOT/argv" || grep -qx -- 'json' "$ROOT/argv"; }
}
t_media() {
    export FAKE_AGY_OUTPUT=ok
    png="$ROOT/first image.png"; wav="$ROOT/second-audio.wav"
    printf '\211PNG\r\n\032\n\000\000\000\rIHDR' >"$png"
    printf 'RIFF\044\000\000\000WAVEfmt ' >"$wav"
    PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt inspect --workdir "$ROOT/work" \
        --attachment "$png" --attachment "$wav" >/dev/null 2>/dev/null &&
        grep -Fq 'original=first image.png, mime=image/png' "$ROOT/stdin" &&
        grep -Eq '2\..*original=second-audio\.wav.*mime=audio/(x-)?wav.*support=probe-verified' "$ROOT/stdin" &&
        [[ "$(grep -c -x -- '--add-dir' "$ROOT/argv")" -eq 2 ]]
}
t_exit() {
    export FAKE_AGY_OUTPUT=partial FAKE_AGY_EXIT=42
    set +e; out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_EXIT
    [[ $code -eq 42 && "$out" == *'[ANTIGRAVITY_WRAPPER_ERROR]'* ]]
}
t_empty() {
    unset FAKE_AGY_OUTPUT
    set +e; out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    [[ $code -eq 1 && "$out" == *'[ANTIGRAVITY_WRAPPER_ERROR]'* ]]
}
t_danger() {
    export FAKE_AGY_OUTPUT=ok
    set +e; out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi --dangerously-skip-permissions 2>/dev/null)"; code=$?; set -e
    [[ $code -eq 1 && "$out" == *'ANTIGRAVITY_ALLOW_DANGEROUS=1'* ]]
}
t_invalid_media_cleanup() {
    mkdir -p "$ROOT/media-tmp"
    printf 'not media' >"$ROOT/not-media.bin"
    set +e
    out="$(TMPDIR="$ROOT/media-tmp" PATH="$ROOT/bin:$PATH" bash "$WRAPPER" \
        --prompt hi --attachment "$ROOT/not-media.bin" 2>/dev/null)"
    code=$?
    set -e
    [[ $code -eq 1 && "$out" == *'Unsupported or unrecognized media format'* ]] &&
        [[ -z "$(find "$ROOT/media-tmp" -mindepth 1 -print -quit)" ]]
}
t_model() {
    PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --set-model config/model >/dev/null &&
    out="$(PATH="$ROOT/bin:$PATH" ANTIGRAVITY_WRAPPER_MODEL=env/model bash "$WRAPPER" --show-model)" &&
    [[ "$out" == *'env/model (source: env)'* ]] &&
    out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --show-model)" &&
    [[ "$out" == *'config/model (source: config)'* ]]
}
t_timeout() {
    command -v timeout >/dev/null 2>&1 || return 0
    export FAKE_AGY_OUTPUT=late FAKE_AGY_SLEEP=3
    set +e; out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi --timeout 1 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_SLEEP
    [[ $code -eq 2 && "$out" == *'timed out'* ]]
}
t_denied_empty_response() {
    export FAKE_AGY_OUTPUT='' FAKE_AGY_DENIED='escalate_admin:Bash'
    set +e; out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_DENIED
    [[ $code -eq 1 && "$out" == *'permissions were denied'* && "$out" == *'[ANTIGRAVITY_DENIED_ACTIONS] escalate_admin (Bash)'* ]]
}
t_denied_with_response() {
    export FAKE_AGY_OUTPUT='fake response' FAKE_AGY_DENIED='command:Bash'
    set +e; out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_DENIED
    [[ $code -eq 0 ]] || return 1
    response_pos="${out%%fake response*}"; [[ "$response_pos" != "$out" ]] || return 1
    denied_pos="${out%%\[ANTIGRAVITY_DENIED_ACTIONS\] command \(Bash\)*}"; [[ "$denied_pos" != "$out" ]] || return 1
    [[ "${#response_pos}" -lt "${#denied_pos}" ]]
}
t_non_success_status() {
    export FAKE_AGY_OUTPUT='fake response' FAKE_AGY_STATUS='ERROR'
    set +e; out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_STATUS
    [[ $code -eq 1 && "$out" == *'status ERROR'* ]]
}
t_unparseable_output() {
    export FAKE_AGY_RAW='not json at all'
    set +e; out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_RAW
    [[ $code -eq 1 && "$out" == *'unparseable'* && "$out" == *'not json at all'* ]]
}
t_raw_empty() {
    export FAKE_AGY_RAW_EMPTY=1
    set +e; out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_RAW_EMPTY
    [[ $code -eq 1 && "$out" == *'empty output'* ]]
}
t_no_parser_fallback() {
    export FAKE_AGY_OUTPUT=ok ANTIGRAVITY_WRAPPER_JSON_TOOL=none FAKE_AGY_DENIED=escalate_admin:Bash
    set +e
    out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi 2>"$ROOT/no_parser_err")"
    code=$?
    set -e
    unset ANTIGRAVITY_WRAPPER_JSON_TOOL FAKE_AGY_DENIED
    [[ $code -eq 0 && "$out" == *'ok'* ]] || return 1
    ! grep -qx -- '--output-format' "$ROOT/argv" || return 1
    grep -qF 'denied-action detection disabled' "$ROOT/no_parser_err" || return 1
    [[ "$out" != *'[ANTIGRAVITY_DENIED_ACTIONS]'* ]]
}
t_denied_single_object() {
    export FAKE_AGY_OUTPUT='' FAKE_AGY_DENIED='escalate_admin:Bash' FAKE_AGY_DENIED_SHAPE=object
    set +e; out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_DENIED FAKE_AGY_DENIED_SHAPE
    [[ $code -eq 1 && "$out" == *'[ANTIGRAVITY_DENIED_ACTIONS] escalate_admin (Bash)'* ]]
}
t_denied_bad_type() {
    export FAKE_AGY_OUTPUT='fake response' FAKE_AGY_DENIED='escalate_admin:Bash' FAKE_AGY_DENIED_SHAPE=number
    set +e; out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_DENIED FAKE_AGY_DENIED_SHAPE
    [[ $code -eq 1 && "$out" == *'unexpected denied_actions type'* ]]
}
t_denied_dedupe() {
    export FAKE_AGY_OUTPUT='fake response' FAKE_AGY_DENIED='command:Bash,command:Bash,escalate_admin:Bash'
    set +e; out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_DENIED
    [[ $code -eq 0 && "$out" == *'[ANTIGRAVITY_DENIED_ACTIONS] command (Bash), escalate_admin (Bash)'* ]]
}
t_conversation_id_on_stderr() {
    export FAKE_AGY_OUTPUT='fake response'
    set +e; out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi 2>"$ROOT/convid_err")"; code=$?; set -e
    [[ $code -eq 0 ]] || return 1
    grep -qF 'ANTIGRAVITY: conversation_id=fake' "$ROOT/convid_err" || return 1
    [[ "$out" != *'conversation_id'* ]]
}
t_status_timeout() {
    export FAKE_AGY_OUTPUT='fake response' FAKE_AGY_STATUS=TIMEOUT
    set +e; out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_STATUS
    [[ $code -eq 2 && "$out" == *'status TIMEOUT'* ]]
}
t_stderr_tail_on_empty() {
    export FAKE_AGY_RAW_EMPTY=1 FAKE_AGY_STDERR='hint line'
    set +e; out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_RAW_EMPTY FAKE_AGY_STDERR
    [[ $code -eq 1 && "$out" == *'agy stderr (tail):'* && "$out" == *'hint line'* ]]
}
t_large_response() {
    large_file="$ROOT/large_response.txt"
    { printf '%s' "$(head -c 3000000 </dev/zero | tr '\0' 'x')"; printf '\n日本語の行\n'; } >"$large_file"
    export FAKE_AGY_RESPONSE_FILE="$large_file"
    set +e; out="$(PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_RESPONSE_FILE
    [[ $code -eq 0 ]] || return 1
    [[ "${#out}" -ge 3000000 ]] || return 1
    [[ "$out" == *'日本語の行'* ]]
}
t_crlf_and_trailing_newlines() {
    crlf_file="$ROOT/crlf_response.txt"
    printf 'line1\r\nline2\n\n\n' >"$crlf_file"
    export FAKE_AGY_RESPONSE_FILE="$crlf_file"
    set +e
    PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi >"$ROOT/crlf_out" 2>/dev/null
    code=$?
    set -e
    unset FAKE_AGY_RESPONSE_FILE
    [[ $code -eq 0 ]] || return 1
    cmp -s "$crlf_file" "$ROOT/crlf_out"
}
tool_is_usable() {
    # Some Windows setups have a PATH entry for python3/python that is a broken App
    # Execution Alias stub; command -v alone is not enough to know it actually runs.
    case "$1" in
        jq) command -v jq >/dev/null 2>&1 ;;
        python3|python) command -v "$1" >/dev/null 2>&1 && "$1" -c 'import json' >/dev/null 2>&1 ;;
        node) command -v node >/dev/null 2>&1 && node -e '1' >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}
t_bom_input() {
    export FAKE_AGY_OUTPUT='bom response' FAKE_AGY_BOM=1
    local any_tested=0
    for tool in jq python3 python node; do
        tool_is_usable "$tool" || continue
        any_tested=1
        set +e
        out="$(PATH="$ROOT/bin:$PATH" ANTIGRAVITY_WRAPPER_JSON_TOOL="$tool" bash "$WRAPPER" --prompt hi 2>/dev/null)"
        code=$?
        set -e
        if [[ $code -ne 0 || "$out" != *'bom response'* ]]; then
            unset FAKE_AGY_OUTPUT FAKE_AGY_BOM
            return 1
        fi
    done
    unset FAKE_AGY_OUTPUT FAKE_AGY_BOM
    [[ "$any_tested" -eq 1 ]]
}
pick_stream_tool() {
    for t in python3 python node; do
        tool_is_usable "$t" && { printf '%s' "$t"; return 0; }
    done
    return 1
}

t_liveness_stream_delay() {
    local stream_tool; stream_tool="$(pick_stream_tool)" || return 0
    # ASCII-only response so the first-chunk byte comparison against the fake's first-half split
    # is unambiguous (no multi-byte UTF-8 sequence can straddle the split point).
    local response='fake response ascii only 0123456789'
    export FAKE_AGY_OUTPUT="$response" FAKE_AGY_STREAM_DELAY=3
    local expected_first="${response:0:$(( (${#response} + 1) / 2 ))}"
    local live_out="$ROOT/live_out"
    : >"$live_out"
    local start_seconds=$SECONDS
    PATH="$ROOT/bin:$PATH" ANTIGRAVITY_WRAPPER_JSON_TOOL="$stream_tool" bash "$WRAPPER" --prompt hi >"$live_out" 2>/dev/null &
    local pid=$!
    local first_nonempty_seconds=""
    local first_chunk=""
    while kill -0 "$pid" 2>/dev/null; do
        if [[ -z "$first_nonempty_seconds" && -s "$live_out" ]]; then
            first_nonempty_seconds=$SECONDS
            first_chunk="$(cat "$live_out")"
        fi
        sleep 0.2
    done
    wait "$pid"
    local exit_seconds=$SECONDS
    unset FAKE_AGY_STREAM_DELAY FAKE_AGY_OUTPUT
    [[ -n "$first_nonempty_seconds" ]] || return 1
    [[ "$first_chunk" == "$expected_first" ]] || return 1
    local gap=$((exit_seconds - first_nonempty_seconds))
    [[ "$gap" -ge 2 ]]
}
t_tool_progress_on_stderr() {
    local stream_tool; stream_tool="$(pick_stream_tool)" || return 0
    export FAKE_AGY_OUTPUT='fake response' FAKE_AGY_TOOL_EVENT=1
    set +e; out="$(PATH="$ROOT/bin:$PATH" ANTIGRAVITY_WRAPPER_JSON_TOOL="$stream_tool" bash "$WRAPPER" --prompt hi 2>"$ROOT/tool_err")"; code=$?; set -e
    unset FAKE_AGY_TOOL_EVENT FAKE_AGY_OUTPUT
    [[ $code -eq 0 ]] || return 1
    grep -qF 'ANTIGRAVITY: tool=run_command state=ACTIVE' "$ROOT/tool_err" || return 1
    grep -qF 'ANTIGRAVITY: tool=run_command state=DONE error=TOOL_ERROR: context canceled' "$ROOT/tool_err" || return 1
    [[ "$out" != *'tool='* ]]
}
t_no_result_event() {
    local stream_tool; stream_tool="$(pick_stream_tool)" || return 0
    export FAKE_AGY_OUTPUT='fake response' FAKE_AGY_NO_RESULT=1
    set +e; out="$(PATH="$ROOT/bin:$PATH" ANTIGRAVITY_WRAPPER_JSON_TOOL="$stream_tool" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_NO_RESULT FAKE_AGY_OUTPUT
    [[ $code -eq 1 && "$out" == *'stream ended without a result event'* ]]
}
t_denied_with_response_after_stream() {
    local stream_tool; stream_tool="$(pick_stream_tool)" || return 0
    local no_newline_file="$ROOT/no_newline_response.txt"
    printf 'no trailing newline here' >"$no_newline_file"
    export FAKE_AGY_RESPONSE_FILE="$no_newline_file" FAKE_AGY_DENIED='command:Bash'
    set +e; out="$(PATH="$ROOT/bin:$PATH" ANTIGRAVITY_WRAPPER_JSON_TOOL="$stream_tool" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_RESPONSE_FILE FAKE_AGY_DENIED
    [[ $code -eq 0 ]] || return 1
    [[ "$out" == $'no trailing newline here\n[ANTIGRAVITY_DENIED_ACTIONS] command (Bash)' ]]
}
t_utf8_delta_bytes() {
    local stream_tool; stream_tool="$(pick_stream_tool)" || return 0
    local utf8_file="$ROOT/utf8_response.txt"
    printf '日本語のテキストです。絵文字も入ります: \xF0\x9F\x98\x80 end' >"$utf8_file"
    export FAKE_AGY_RESPONSE_FILE="$utf8_file"
    set +e
    PATH="$ROOT/bin:$PATH" ANTIGRAVITY_WRAPPER_JSON_TOOL="$stream_tool" bash "$WRAPPER" --prompt hi >"$ROOT/utf8_out" 2>/dev/null
    code=$?
    set -e
    unset FAKE_AGY_RESPONSE_FILE
    [[ $code -eq 0 ]] || return 1
    cmp -s "$utf8_file" "$ROOT/utf8_out"
}
t_malformed_mid_stream_warning() {
    local stream_tool; stream_tool="$(pick_stream_tool)" || return 0
    export FAKE_AGY_OUTPUT='fake response' FAKE_AGY_GARBAGE_LINE=1
    set +e; out="$(PATH="$ROOT/bin:$PATH" ANTIGRAVITY_WRAPPER_JSON_TOOL="$stream_tool" bash "$WRAPPER" --prompt hi 2>"$ROOT/malformed_err")"; code=$?; set -e
    unset FAKE_AGY_OUTPUT FAKE_AGY_GARBAGE_LINE
    [[ $code -eq 0 && "$out" == *'fake response'* ]] || return 1
    grep -qF 'non-JSON line(s) ignored' "$ROOT/malformed_err"
}
t_fatal_error_event() {
    local stream_tool; stream_tool="$(pick_stream_tool)" || return 0
    export FAKE_AGY_ERROR_EVENT=1
    set +e; out="$(PATH="$ROOT/bin:$PATH" ANTIGRAVITY_WRAPPER_JSON_TOOL="$stream_tool" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_ERROR_EVENT
    [[ $code -eq 1 && "$out" == *'fatal error'* && "$out" == *'fake fatal error'* ]]
}
t_unknown_step_progress() {
    local stream_tool; stream_tool="$(pick_stream_tool)" || return 0
    export FAKE_AGY_OUTPUT='fake response' FAKE_AGY_THOUGHT_STEP=1
    set +e; out="$(PATH="$ROOT/bin:$PATH" ANTIGRAVITY_WRAPPER_JSON_TOOL="$stream_tool" bash "$WRAPPER" --prompt hi 2>"$ROOT/thought_err")"; code=$?; set -e
    unset FAKE_AGY_OUTPUT FAKE_AGY_THOUGHT_STEP
    [[ $code -eq 0 && "$out" == *'fake response'* ]] || return 1
    grep -qF 'ANTIGRAVITY: step=thought state=ACTIVE' "$ROOT/thought_err" || return 1
    [[ "$out" != *'step=thought'* ]]
}
lock_dir_no_write() {
    # Blocks new writes into a directory. Plain chmod does not stop the owner from writing on this
    # Windows/NTFS setup (verified: chmod 500 alone is a no-op for owner writes here), so on
    # Windows we instead strip the inherited ACEs that carry the owner's write grant via icacls.
    local dir="$1"
    if command -v icacls >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
        icacls "$(cygpath -w "$dir")" /inheritance:r >/dev/null 2>&1
    else
        chmod 500 "$dir" 2>/dev/null
    fi
}
unlock_dir() {
    local dir="$1"
    if command -v icacls >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
        icacls "$(cygpath -w "$dir")" /inheritance:e >/dev/null 2>&1
    else
        chmod 700 "$dir" 2>/dev/null
    fi
    true
}
t_parser_failure_propagated() {
    local stream_tool; stream_tool="$(pick_stream_tool)" || return 0
    if [[ "$(id -u)" == "0" ]]; then return 0; fi
    # RESULT_FILE is created (then immediately deleted) by the wrapper before agy even starts. A
    # generous FAKE_AGY_STREAM_DELAY between the two response halves gives us a wide window to
    # lock the directory well before the parser's open(result_file, "w") for the `result` event,
    # so that write genuinely fails (verified: a lock applied shortly after wrapper start reliably
    # produces a PermissionError in the parser, vs. one applied near/after the write which can
    # race and miss it).
    export FAKE_AGY_OUTPUT='fake response' FAKE_AGY_STREAM_DELAY=8
    local result_dir="$ROOT/parser_fail_result_dir"
    mkdir -p "$result_dir"
    local live_out="$ROOT/parser_fail_out"
    local live_err="$ROOT/parser_fail_err"
    : >"$live_out"; : >"$live_err"
    PATH="$ROOT/bin:$PATH" ANTIGRAVITY_WRAPPER_JSON_TOOL="$stream_tool" ANTIGRAVITY_WRAPPER_RESULT_DIR="$result_dir" \
        bash "$WRAPPER" --prompt hi >"$live_out" 2>"$live_err" &
    local pid=$!
    # The wrapper's own mktemp (+ immediate rm -f) of RESULT_FILE happens before agy even starts;
    # locking the directory before that completes would make mktemp itself fail instead (a
    # different, uninteresting failure mode: "Unable to create temporary result file"). Wait for
    # the conversation_id line on stderr (printed right after agy's init event, well after that
    # mktemp) as a synchronization point, then lock -- agy's 8s delay before the second half of the
    # response leaves ample margin before the parser's later open(result_file, "w") for `result`.
    local synced=0
    local attempt=0
    while [[ "$attempt" -lt 100 ]]; do
        grep -qF 'ANTIGRAVITY: conversation_id=' "$live_err" 2>/dev/null && { synced=1; break; }
        sleep 0.05
        attempt=$((attempt + 1))
    done
    local locked=0
    if [[ "$synced" -eq 1 ]]; then
        lock_dir_no_write "$result_dir" && locked=1
    fi
    wait "$pid"
    local code=$?
    unlock_dir "$result_dir"
    unset FAKE_AGY_OUTPUT FAKE_AGY_STREAM_DELAY
    [[ "$locked" -eq 1 ]] || return 0
    local out; out="$(cat "$live_out")"
    [[ $code -eq 1 && "$out" == *'stream parser failed'* ]]
}
t_error_sentinel_on_new_line() {
    local stream_tool; stream_tool="$(pick_stream_tool)" || return 0
    local no_newline_file="$ROOT/no_newline_error_response.txt"
    printf 'no trailing newline before error' >"$no_newline_file"
    export FAKE_AGY_RESPONSE_FILE="$no_newline_file" FAKE_AGY_NO_RESULT=1
    set +e; out="$(PATH="$ROOT/bin:$PATH" ANTIGRAVITY_WRAPPER_JSON_TOOL="$stream_tool" bash "$WRAPPER" --prompt hi 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_RESPONSE_FILE FAKE_AGY_NO_RESULT
    [[ $code -eq 1 ]] || return 1
    [[ "$out" == $'no trailing newline before error\n'* ]] || return 1
    [[ "$out" == *$'\n[ANTIGRAVITY_WRAPPER_ERROR]'* ]]
}
t_jq_fallback_buffered() {
    tool_is_usable jq || return 0
    export FAKE_AGY_OUTPUT=ok
    set +e
    out="$(PATH="$ROOT/bin:$PATH" ANTIGRAVITY_WRAPPER_JSON_TOOL=jq bash "$WRAPPER" --prompt hi 2>"$ROOT/jq_err")"
    code=$?
    set -e
    unset FAKE_AGY_OUTPUT
    [[ $code -eq 0 && "$out" == *'ok'* ]] || return 1
    grep -qx -- '--output-format' "$ROOT/argv" || return 1
    grep -qx -- 'json' "$ROOT/argv" || return 1
    ! grep -qx -- 'stream-json' "$ROOT/argv" || return 1
    grep -qF 'falling back to buffered output' "$ROOT/jq_err"
}
t_response_file_cleanup() {
    before="$(ls "${TMPDIR:-/tmp}" 2>/dev/null | grep -c '^antigravity_response\.' || true)"
    export FAKE_AGY_OUTPUT='ok'
    PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi >/dev/null 2>/dev/null
    unset FAKE_AGY_OUTPUT
    after="$(ls "${TMPDIR:-/tmp}" 2>/dev/null | grep -c '^antigravity_response\.' || true)"
    [[ "$before" -eq "$after" ]]
}
check stdin_is_not_argv t_stdin
check expected_cli_arguments t_args
check ordered_mixed_media_staging t_media
check exit_code_and_sentinel t_exit
check empty_output_sentinel t_empty
check dangerous_requires_double_opt_in t_danger
check invalid_media_cleanup t_invalid_media_cleanup
check model_resolution t_model
check parent_timeout t_timeout
check denied_empty_response t_denied_empty_response
check denied_with_response t_denied_with_response
check non_success_status t_non_success_status
check unparseable_output t_unparseable_output
check raw_empty t_raw_empty
check no_parser_fallback t_no_parser_fallback
check denied_single_object t_denied_single_object
check denied_bad_type t_denied_bad_type
check denied_dedupe t_denied_dedupe
check conversation_id_on_stderr t_conversation_id_on_stderr
check status_timeout t_status_timeout
check stderr_tail_on_empty t_stderr_tail_on_empty
check large_response t_large_response
check crlf_and_trailing_newlines t_crlf_and_trailing_newlines
check bom_input t_bom_input
check liveness_stream_delay t_liveness_stream_delay
check tool_progress_on_stderr t_tool_progress_on_stderr
check no_result_event t_no_result_event
check denied_with_response_after_stream t_denied_with_response_after_stream
check utf8_delta_bytes t_utf8_delta_bytes
check malformed_mid_stream_warning t_malformed_mid_stream_warning
check fatal_error_event t_fatal_error_event
check unknown_step_progress t_unknown_step_progress
check parser_failure_propagated t_parser_failure_propagated
check error_sentinel_on_new_line t_error_sentinel_on_new_line
check jq_fallback_buffered t_jq_fallback_buffered
check response_file_cleanup t_response_file_cleanup
printf 'Passed: %d / %d\n' "$passed" "$total"
[[ "$passed" -eq "$total" ]]
