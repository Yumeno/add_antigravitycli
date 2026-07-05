#!/usr/bin/env bash
# clean repository だけを対象に agy へ実装を委任し、終了後にGit不変条件を検収する。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WRAPPER="$SCRIPT_DIR/antigravity-wrapper.sh"
VERIFY="$SCRIPT_DIR/antigravity-verify.sh"
ERROR='[ANTIGRAVITY_IMPLEMENT_ERROR]'
die() { printf '%s %s\n' "$ERROR" "$*" >&2; exit 1; }

REPO=''; SPEC_FILE=''; MODEL=''; TIMEOUT=600
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) [[ $# -ge 2 ]] || die '--repo requires a value.'; REPO="$2"; shift 2 ;;
        --spec-file) [[ $# -ge 2 ]] || die '--spec-file requires a value.'; SPEC_FILE="$2"; shift 2 ;;
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
    printf '%s\n' '次の依頼を、このGitリポジトリ内だけで実装してください。'
    printf '%s\n' '対象リポジトリ外のファイルを読取・列挙・検索しないでください。CLI内部の認証・設定処理を除き、他projectやユーザー設定を調査しないでください。'
    printf '%s\n' '禁止: .git、認証情報、.envへの接触、commit/branch/tag/ref/Git設定/hook/submodule操作、依頼範囲外の変更。'
    printf '%s\n\n' '必要なテストを実行し、最後に変更ファイルとテスト結果を報告してください。'
    cat -- "$SPEC_FILE"
} >"$INSTRUCTION"
ARGS=(--prompt-file "$INSTRUCTION" --workdir "$ROOT" --timeout "$TIMEOUT" --sandbox)
[[ -z "$MODEL" ]] || ARGS+=(--model "$MODEL")
run_code=0
"$WRAPPER" "${ARGS[@]}" || run_code=$?
check_code=0
"$VERIFY" check --repo "$ROOT" --snapshot "$SNAP" || check_code=$?
[[ "$check_code" -eq 0 ]] || exit "$check_code"
exit "$run_code"
