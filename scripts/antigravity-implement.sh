#!/usr/bin/env bash
# clean repository だけを対象に agy へ実装を委任し、終了後にGit不変条件を検収する。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WRAPPER="$SCRIPT_DIR/antigravity-wrapper.sh"
VERIFY="$SCRIPT_DIR/antigravity-verify.sh"
ERROR='[ANTIGRAVITY_IMPLEMENT_ERROR]'
die() { printf '%s %s\n' "$ERROR" "$*" >&2; exit 1; }
b64e() { printf '%s' "$1" | base64 | tr -d '\r\n'; }
b64d() {
    if printf '' | base64 --decode >/dev/null 2>&1; then
        printf '%s' "$1" | base64 --decode 2>/dev/null
    else
        printf '%s' "$1" | base64 -D 2>/dev/null
    fi
}

REPO=''; SPEC_FILE=''; MODEL=''; TIMEOUT=600; ATTACHMENTS=(); SESSION=''; CLOSE_SESSION=0; ADOPT_CHANGES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) [[ $# -ge 2 ]] || die '--repo requires a value.'; REPO="$2"; shift 2 ;;
        --spec-file) [[ $# -ge 2 ]] || die '--spec-file requires a value.'; SPEC_FILE="$2"; shift 2 ;;
        --attachment) [[ $# -ge 2 ]] || die '--attachment requires a value.'; ATTACHMENTS+=("$2"); shift 2 ;;
        --model) [[ $# -ge 2 ]] || die '--model requires a value.'; MODEL="$2"; shift 2 ;;
        --timeout) [[ $# -ge 2 ]] || die '--timeout requires a value.'; TIMEOUT="$2"; shift 2 ;;
        --session) [[ $# -ge 2 ]] || die '--session requires a value.'; SESSION="$2"; shift 2 ;;
        --close-session) CLOSE_SESSION=1; shift ;;
        --adopt-changes) ADOPT_CHANGES=1; shift ;;
        *) die "Unknown option: $1" ;;
    esac
done
[[ -n "$REPO" ]] || die '--repo is required.'
if [[ "$CLOSE_SESSION" -eq 1 ]]; then
    [[ -n "$SESSION" ]] || die '--close-session requires --session.'
    [[ -z "$SPEC_FILE" ]] || die '--close-session cannot be combined with --spec-file.'
else
    [[ -n "$SPEC_FILE" && -f "$SPEC_FILE" ]] || die '--spec-file must name an existing file.'
fi
if [[ "$ADOPT_CHANGES" -eq 1 && ( -z "$SESSION" || "$CLOSE_SESSION" -eq 1 ) ]]; then
    die '--adopt-changes is only valid when continuing a session.'
fi
ROOT="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || die 'Not a Git repository.'
ROOT="$(cd "$ROOT" && pwd -P)"

SESSION_PATH=''
SNAP_SIDECAR=''
if [[ -n "$SESSION" ]]; then
    SESSION_DIR="$(dirname "$SESSION")"
    [[ -d "$SESSION_DIR" ]] || die "Session directory not found: $SESSION_DIR"
    SESSION_DIR="$(cd "$SESSION_DIR" && pwd -P)"
    SESSION_PATH="$SESSION_DIR/$(basename "$SESSION")"
    [[ "$SESSION_PATH" != "$ROOT" && "$SESSION_PATH" != "$ROOT/"* ]] || die "Session file must be outside the repository: $SESSION"
    SNAP_SIDECAR="$SESSION_PATH.snapshot"
fi

if [[ "$CLOSE_SESSION" -eq 1 ]]; then
    [[ -f "$SESSION_PATH" ]] || die "Session file not found: $SESSION"
    rm -f "$SESSION_PATH" "$SNAP_SIDECAR"
    printf '[ANTIGRAVITY_SESSION] closed path=%s\n' "$SESSION_PATH"
    exit 0
fi

# Dirty set as repo-relative, NUL-separated paths (rename entries carry two paths).
dirty_paths() {
    local list=() entry status path
    while IFS= read -r -d '' entry; do
        status="${entry:0:2}"
        path="${entry:3}"
        list+=("$path")
        if [[ "$status" == *R* ]]; then
            IFS= read -r -d '' path || true
            list+=("$path")
        fi
    done < <(git -C "$ROOT" -c core.excludesFile= status --porcelain=v1 --untracked-files=all -z)
    printf '%s\n' "${list[@]:-}" | sed '/^$/d' | sort -u
}

read_session_field() {
    # $1=file $2=key ; values are base64-encoded except round which is a plain int
    awk -F= -v key="$2" '$1==key{print substr($0, length($1)+2); exit}' "$1"
}

session_write() {
    # $1=session path $2=snapshot path $3=round $4=owned (newline separated, may be empty)
    umask 077
    {
        printf 'version=1\n'
        printf 'repo=%s\n' "$(b64e "$ROOT")"
        printf 'snapshot=%s\n' "$(b64e "$2")"
        printf 'round=%s\n' "$3"
        if [[ -n "$4" ]]; then
            while IFS= read -r p; do
                [[ -n "$p" ]] || continue
                printf 'owned=%s\n' "$(b64e "$p")"
            done <<<"$4"
        fi
    } >"$1"
}

IS_CONTINUATION=0
OWNED=''
ROUND=1
SNAP=''

if [[ -n "$SESSION_PATH" && -f "$SESSION_PATH" ]]; then
    IS_CONTINUATION=1
    SVERSION="$(read_session_field "$SESSION_PATH" version)"
    [[ "$SVERSION" == 1 ]] || die 'Unsupported session version.'
    SREPO="$(b64d "$(read_session_field "$SESSION_PATH" repo)")" || die 'Invalid session repo.'
    [[ "$SREPO" == "$ROOT" ]] || die "Session belongs to a different repository: $SREPO"
    SNAP="$(b64d "$(read_session_field "$SESSION_PATH" snapshot)")" || die 'Invalid session snapshot path.'
    [[ -f "$SNAP" ]] || die "Session snapshot not found: $SNAP"
    SROUND="$(read_session_field "$SESSION_PATH" round)"
    ROUND=$((SROUND + 1))
    OWNED="$(awk -F= '$1=="owned"{print substr($0, length($1)+2)}' "$SESSION_PATH" | while IFS= read -r enc; do b64d "$enc"; printf '\n'; done)"
    CURRENT_DIRTY="$(dirty_paths)"
    OUTSIDE=''
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        if ! grep -qxF "$p" <<<"$OWNED"; then
            OUTSIDE+="${OUTSIDE:+,}$p"
        fi
    done <<<"$CURRENT_DIRTY"
    if [[ -n "$OUTSIDE" ]]; then
        if [[ "$ADOPT_CHANGES" -ne 1 ]]; then
            die "Working tree has changes outside this delegation session: $OUTSIDE"
        fi
        OWNED="$( { printf '%s\n' "$OWNED"; IFS=','; for p in $OUTSIDE; do printf '%s\n' "$p"; done; } | sed '/^$/d' | sort -u)"
        printf '[ANTIGRAVITY_SESSION] adopted=%s paths=%s\n' "$(tr ',' '\n' <<<"$OUTSIDE" | sed '/^$/d' | wc -l | tr -d ' ')" "$OUTSIDE"
        printf 'ANTIGRAVITY: adopted=%s\n' "$OUTSIDE" >&2
    fi
else
    if [[ "$ADOPT_CHANGES" -eq 1 ]]; then
        die '--adopt-changes is only valid when continuing a session.'
    fi
    STATUS="$(git -C "$ROOT" -c core.excludesFile= status --porcelain=v1 --untracked-files=all)"
    [[ -z "$STATUS" ]] || die 'Working tree must be clean before delegation.'
    if [[ -n "$SESSION_PATH" ]]; then
        SNAP="$SNAP_SIDECAR"
    else
        SNAP="$(mktemp "${TMPDIR:-/tmp}/antigravity_implement_snapshot.XXXXXX")"
        rm -f "$SNAP"
    fi
    "$VERIFY" snapshot --repo "$ROOT" --out "$SNAP" >/dev/null
    if [[ -n "$SESSION_PATH" ]]; then
        session_write "$SESSION_PATH" "$SNAP" 1 ''
    fi
fi

INSTRUCTION="$(mktemp "${TMPDIR:-/tmp}/antigravity_implement_prompt.XXXXXX")"
cleanup() {
    [[ -n "$SESSION_PATH" ]] || rm -f "$SNAP"
    rm -f "$INSTRUCTION"
}
trap cleanup EXIT HUP INT TERM
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

if [[ -n "$SESSION_PATH" ]]; then
    FINAL_DIRTY="$(dirty_paths)"
    NEW_OWNED="$( { printf '%s\n' "$OWNED"; printf '%s\n' "$FINAL_DIRTY"; } | sed '/^$/d' | sort -u)"
    OWNED_COUNT=0
    [[ -z "$NEW_OWNED" ]] || OWNED_COUNT="$(printf '%s\n' "$NEW_OWNED" | sed '/^$/d' | wc -l | tr -d ' ')"
    session_write "$SESSION_PATH" "$SNAP" "$ROUND" "$NEW_OWNED"
    printf '[ANTIGRAVITY_SESSION] round=%s owned=%s path=%s\n' "$ROUND" "$OWNED_COUNT" "$SESSION_PATH"
    OWNED_CSV="$(printf '%s\n' "$NEW_OWNED" | sed '/^$/d' | paste -sd, -)"
    printf 'ANTIGRAVITY: owned=%s\n' "$OWNED_CSV" >&2
fi

[[ "$check_code" -eq 0 ]] || exit "$check_code"
if [[ "$run_code" -ne 0 ]]; then
    printf '%s Antigravity run failed with exit code %s. See the wrapper output above.
' "$ERROR" "$run_code"
    exit "$run_code"
fi
exit 0
