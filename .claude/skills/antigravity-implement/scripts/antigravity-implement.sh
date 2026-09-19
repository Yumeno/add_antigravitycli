#!/usr/bin/env bash
# clean repository だけを対象に agy へ実装を委任し、終了後にGit不変条件を検収する。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WRAPPER="$SCRIPT_DIR/antigravity-wrapper.sh"
VERIFY="$SCRIPT_DIR/antigravity-verify.sh"
ERROR='[ANTIGRAVITY_IMPLEMENT_ERROR]'
die() { printf '%s %s\n' "$ERROR" "$*" >&2; exit 1; }

REPO=''; SPEC_FILE=''; MODEL=''; TIMEOUT=600; ATTACHMENTS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) [[ $# -ge 2 ]] || die '--repo requires a value.'; REPO="$2"; shift 2 ;;
        --spec-file) [[ $# -ge 2 ]] || die '--spec-file requires a value.'; SPEC_FILE="$2"; shift 2 ;;
        --attachment) [[ $# -ge 2 ]] || die '--attachment requires a value.'; ATTACHMENTS+=("$2"); shift 2 ;;
        --model) [[ $# -ge 2 ]] || die '--model requires a value.'; MODEL="$2"; shift 2 ;;
        --timeout) [[ $# -ge 2 ]] || die '--timeout requires a value.'; TIMEOUT="$2"; shift 2 ;;
        *) die "Unknown option: $1" ;;
    esac
done
[[ -n "$REPO" ]] || die '--repo is required.'
[[ -n "$SPEC_FILE" && -f "$SPEC_FILE" ]] || die '--spec-file must name an existing file.'
ROOT="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || die 'Not a Git repository.'
ROOT="$(cd "$ROOT" && pwd -P)"
SNAP="$(mktemp "${TMPDIR:-/tmp}/antigravity_implement_snapshot.XXXXXX")"
rm -f "$SNAP"
INSTRUCTION="$(mktemp "${TMPDIR:-/tmp}/antigravity_implement_prompt.XXXXXX")"
cleanup() { rm -f "$SNAP" "$INSTRUCTION"; }
trap cleanup EXIT HUP INT TERM
"$VERIFY" snapshot --repo "$ROOT" --out "$SNAP" >/dev/null
{
    cat -- "$SCRIPT_DIR/antigravity-implement-safety.txt"
    printf '\n\n---\n\n'
    cat -- "$SPEC_FILE"
} >"$INSTRUCTION"
ARGS=(--prompt-file "$INSTRUCTION" --workdir "$ROOT" --timeout "$TIMEOUT" --sandbox)
[[ -z "$MODEL" ]] || ARGS+=(--model "$MODEL")
for media in "${ATTACHMENTS[@]}"; do ARGS+=(--attachment "$media"); done
run_code=0
"$WRAPPER" "${ARGS[@]}" || run_code=$?
check_code=0
"$VERIFY" check --repo "$ROOT" --snapshot "$SNAP" || check_code=$?
[[ "$check_code" -eq 0 ]] || exit "$check_code"
if [[ "$run_code" -ne 0 ]]; then
    printf '%s Antigravity run failed with exit code %s. See the wrapper output above.
' "$ERROR" "$run_code"
    exit "$run_code"
fi
exit 0
