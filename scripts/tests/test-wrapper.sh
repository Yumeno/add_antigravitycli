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
        [[ "$(cat "$ROOT/stdin")" == "$payload" ]] && ! grep -qF '日本語' "$ROOT/argv"
}
t_args() {
    export FAKE_AGY_OUTPUT=ok
    PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt hi --model gemini/test --sandbox --timeout 9 >/dev/null 2>/dev/null &&
        grep -qx -- '--print' "$ROOT/argv" && grep -qx -- '--print-timeout' "$ROOT/argv" &&
        grep -qx -- '9s' "$ROOT/argv" && grep -qx -- 'gemini/test' "$ROOT/argv" &&
        grep -qx -- '--sandbox' "$ROOT/argv" && grep -qx -- '--new-project' "$ROOT/argv" &&
        grep -qx -- '--add-dir' "$ROOT/argv"
}
t_media() {
    export FAKE_AGY_OUTPUT=ok
    png="$ROOT/first image.png"; wav="$ROOT/second-audio.wav"
    printf '\211PNG\r\n\032\n\000\000\000\rIHDR' >"$png"
    printf 'RIFF\044\000\000\000WAVEfmt ' >"$wav"
    PATH="$ROOT/bin:$PATH" bash "$WRAPPER" --prompt inspect --workdir "$ROOT/work" \
        --attachment "$png" --attachment "$wav" >/dev/null 2>/dev/null &&
        grep -Fq 'original=first\ image.png, mime=image/png' "$ROOT/stdin" &&
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
check stdin_is_not_argv t_stdin
check expected_cli_arguments t_args
check ordered_mixed_media_staging t_media
check exit_code_and_sentinel t_exit
check empty_output_sentinel t_empty
check dangerous_requires_double_opt_in t_danger
check invalid_media_cleanup t_invalid_media_cleanup
check model_resolution t_model
check parent_timeout t_timeout
printf 'Passed: %d / %d\n' "$passed" "$total"
[[ "$passed" -eq "$total" ]]
