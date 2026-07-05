#!/usr/bin/env bash
# Antigravity CLI の非対話呼び出し。prompt/context は argv に含めず stdin で渡す。
set -euo pipefail

ERROR_SENTINEL='[ANTIGRAVITY_WRAPPER_ERROR]'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${ANTIGRAVITY_WRAPPER_CONFIG:-$SCRIPT_DIR/antigravity-wrapper.conf}"
MODEL_RE='^[A-Za-z0-9._:/-]+$'

die() {
    local code="$1"; shift
    printf '%s %s\n' "$ERROR_SENTINEL" "$*"
    printf 'Error: %s\n' "$*" >&2
    exit "$code"
}

need_value() { [[ "$2" -ge 1 ]] || die 1 "$1 requires a value."; }
validate_model() {
    [[ "$1" =~ $MODEL_RE ]] ||
        die 1 "model name from $2 contains unsafe characters."
}
read_config_model() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    awk '/^[[:space:]]*#/ {next}
         /^[[:space:]]*model[[:space:]]*=/ {
           sub(/^[[:space:]]*model[[:space:]]*=[[:space:]]*/, "");
           sub(/[[:space:]]+$/, ""); print; exit
         }' "$CONFIG_FILE"
}

PROMPT=''
PROMPT_FILE=''
CONTEXT_FILE=''
MODEL=''
MODEL_SOURCE=''
WORKDIR=''
TIMEOUT=120
PRINT_TIMEOUT=''
# Safety default: Antigravity's sandbox is a value-less boolean flag.
SANDBOX=1
SET_MODEL=''
SHOW_MODEL=0
DANGEROUS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prompt) need_value "$1" "$(( $# - 1 ))"; PROMPT="$2"; shift 2 ;;
        --prompt-file) need_value "$1" "$(( $# - 1 ))"; PROMPT_FILE="$2"; shift 2 ;;
        --context-file) need_value "$1" "$(( $# - 1 ))"; CONTEXT_FILE="$2"; shift 2 ;;
        --model) need_value "$1" "$(( $# - 1 ))"; MODEL="$2"; MODEL_SOURCE=cli; shift 2 ;;
        --workdir|--cd) need_value "$1" "$(( $# - 1 ))"; WORKDIR="$2"; shift 2 ;;
        --timeout) need_value "$1" "$(( $# - 1 ))"; TIMEOUT="$2"; shift 2 ;;
        --print-timeout) need_value "$1" "$(( $# - 1 ))"; PRINT_TIMEOUT="$2"; shift 2 ;;
        --sandbox) SANDBOX=1; shift ;;
        --dangerously-skip-permissions) DANGEROUS=1; shift ;;
        --set-model) need_value "$1" "$(( $# - 1 ))"; SET_MODEL="$2"; shift 2 ;;
        --show-model) SHOW_MODEL=1; shift ;;
        *) die 1 "Unknown option: $1" ;;
    esac
done

if [[ -n "$SET_MODEL" ]]; then
    validate_model "$SET_MODEL" '--set-model'
    umask 077
    printf '# antigravity-wrapper.conf\nmodel=%s\n' "$SET_MODEL" >"$CONFIG_FILE" ||
        die 1 "Unable to write config: $CONFIG_FILE"
    printf "Saved model='%s' to %s\n" "$SET_MODEL" "$CONFIG_FILE"
    exit 0
fi

if [[ -n "$MODEL" ]]; then
    validate_model "$MODEL" '--model'
elif [[ -n "${ANTIGRAVITY_WRAPPER_MODEL:-}" ]]; then
    MODEL="$ANTIGRAVITY_WRAPPER_MODEL"; MODEL_SOURCE=env
    validate_model "$MODEL" '$ANTIGRAVITY_WRAPPER_MODEL'
else
    MODEL="$(read_config_model)"
    if [[ -n "$MODEL" ]]; then
        MODEL_SOURCE=config
        validate_model "$MODEL" "$CONFIG_FILE"
    fi
fi

if [[ "$SHOW_MODEL" -eq 1 ]]; then
    if [[ -n "$MODEL" ]]; then
        printf 'model=%s (source: %s)\n' "$MODEL" "$MODEL_SOURCE"
    else
        printf 'model=(unset; agy CLI default will be used)\n'
    fi
    printf 'config_file=%s\n' "$CONFIG_FILE"
    exit 0
fi

[[ -z "$PROMPT" || -z "$PROMPT_FILE" ]] ||
    die 1 '--prompt and --prompt-file are mutually exclusive.'
[[ -n "$PROMPT" || -n "$PROMPT_FILE" ]] ||
    die 1 '--prompt or --prompt-file is required.'
[[ -z "$PROMPT_FILE" || -f "$PROMPT_FILE" ]] ||
    die 1 "Prompt file not found: $PROMPT_FILE"
[[ -z "$CONTEXT_FILE" || -f "$CONTEXT_FILE" ]] ||
    die 1 "Context file not found: $CONTEXT_FILE"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] ||
    die 1 "--timeout must be a positive integer (got: '$TIMEOUT')."
if [[ -z "$PRINT_TIMEOUT" ]]; then PRINT_TIMEOUT="$TIMEOUT"; fi
[[ "$PRINT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] ||
    die 1 "--print-timeout must be a positive integer (got: '$PRINT_TIMEOUT')."
[[ "$DANGEROUS" -eq 0 || "${ANTIGRAVITY_ALLOW_DANGEROUS:-}" == 1 ]] ||
    die 1 '--dangerously-skip-permissions requires ANTIGRAVITY_ALLOW_DANGEROUS=1.'
command -v agy >/dev/null 2>&1 || die 127 'agy CLI was not found in PATH.'

OWNED_WORKDIR=''
if [[ -z "$WORKDIR" ]]; then
    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/antigravity_work.XXXXXX")" ||
        die 1 'Unable to create isolated workdir.'
    OWNED_WORKDIR="$WORKDIR"
fi
[[ -d "$WORKDIR" ]] || die 1 "workdir does not exist: $WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd -P)" || die 1 'Unable to resolve workdir.'

INPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/antigravity_input.XXXXXX")" ||
    die 1 'Unable to create temporary input.'
OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/antigravity_out.XXXXXX")" ||
    die 1 'Unable to create temporary output.'
ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/antigravity_err.XXXXXX")" ||
    die 1 'Unable to create temporary error output.'
cleanup() {
    rm -f "$INPUT_FILE" "$OUT_FILE" "$ERR_FILE"
    [[ -z "$OWNED_WORKDIR" ]] || rm -rf -- "$OWNED_WORKDIR"
}
trap cleanup EXIT HUP INT TERM
chmod 600 "$INPUT_FILE" "$OUT_FILE" "$ERR_FILE" 2>/dev/null || true

if [[ -n "$PROMPT_FILE" ]]; then cat -- "$PROMPT_FILE" >"$INPUT_FILE"; else printf '%s' "$PROMPT" >"$INPUT_FILE"; fi
if [[ -n "$CONTEXT_FILE" ]]; then
    printf '\n\n--- Explicit context ---\n' >>"$INPUT_FILE"
    cat -- "$CONTEXT_FILE" >>"$INPUT_FILE"
fi

ARGS=(--print --print-timeout "${PRINT_TIMEOUT}s" --new-project --add-dir "$WORKDIR")
[[ -z "$MODEL" ]] || ARGS+=(--model "$MODEL")
[[ "$SANDBOX" -eq 0 ]] || ARGS+=(--sandbox)
[[ "$DANGEROUS" -eq 0 ]] || ARGS+=(--dangerously-skip-permissions)
[[ -z "$MODEL" ]] || printf 'MODEL: %s\n' "$MODEL" >&2
printf 'ANTIGRAVITY: workdir=%s timeout=%ss sandbox=%s dangerous=%s\n' \
    "$WORKDIR" "$TIMEOUT" "$SANDBOX" "$DANGEROUS" >&2

run_agy() { (cd "$WORKDIR" && "$@" agy "${ARGS[@]}" <"$INPUT_FILE" >"$OUT_FILE" 2>"$ERR_FILE"); }
AGY_EXIT=0
if command -v timeout >/dev/null 2>&1; then
    run_agy timeout "${TIMEOUT}s" || AGY_EXIT=$?
elif command -v gtimeout >/dev/null 2>&1; then
    run_agy gtimeout "${TIMEOUT}s" || AGY_EXIT=$?
else
    printf 'Warning: parent timeout command unavailable; relying on agy --print-timeout.\n' >&2
    run_agy || AGY_EXIT=$?
fi

[[ -s "$ERR_FILE" ]] && cat "$ERR_FILE" >&2
if [[ "$AGY_EXIT" -eq 124 || "$AGY_EXIT" -eq 137 ]]; then
    die 2 "agy CLI timed out after ${TIMEOUT}s."
fi
if [[ "$AGY_EXIT" -ne 0 ]]; then
    [[ ! -s "$OUT_FILE" ]] || cat "$OUT_FILE"
    printf '%s agy CLI exited with non-zero status: %s\n' "$ERROR_SENTINEL" "$AGY_EXIT"
    exit "$AGY_EXIT"
fi
[[ -s "$OUT_FILE" ]] || die 1 'agy CLI returned empty output.'
cat "$OUT_FILE"
