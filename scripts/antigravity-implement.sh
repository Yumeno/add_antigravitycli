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
# Display-only: join an array with commas, replacing embedded newlines with the
# literal text "\n" so a single log line cannot be split by a crafted filename.
# Never feed this back into comparison logic -- arrays are the source of truth.
display_join() {
    local out='' first=1 p esc
    for p in "$@"; do
        esc="${p//$'\n'/\\n}"
        [[ "$first" -eq 1 ]] || out+=','
        out+="$esc"
        first=0
    done
    printf '%s' "$out"
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
LOCK_PATH=''
LOCK_HELD=0
if [[ -n "$SESSION" ]]; then
    SESSION_DIR="$(dirname "$SESSION")"
    [[ -d "$SESSION_DIR" ]] || die "Session directory not found: $SESSION_DIR"
    # Resolve the parent directory to its real path (follows symlinks) so a
    # symlinked parent cannot be used to smuggle the session inside the repo.
    SESSION_DIR="$(cd "$SESSION_DIR" && pwd -P)"
    SESSION_PATH="$SESSION_DIR/$(basename "$SESSION")"
    [[ "$SESSION_PATH" != "$ROOT" && "$SESSION_PATH" != "$ROOT/"* ]] || die "Session file must be outside the repository: $SESSION"
    SNAP_SIDECAR="$SESSION_PATH.snapshot"
    [[ "$SNAP_SIDECAR" != "$ROOT" && "$SNAP_SIDECAR" != "$ROOT/"* ]] || die "Session snapshot must be outside the repository: $SNAP_SIDECAR"
    # Refuse if either path already exists as a symlink: following it could
    # write session data through an attacker-controlled link.
    [[ ! -L "$SESSION_PATH" ]] || die 'Session file must not be a link.'
    [[ ! -L "$SNAP_SIDECAR" ]] || die 'Session file must not be a link.'
    LOCK_PATH="$SESSION_PATH.lock"
fi

acquire_lock() {
    # Exclusive create: noclobber makes a plain redirect fail if the file
    # already exists, so this can never race past a concurrent run's lock.
    # Scoped to this function only (on/off) so it never affects other writes.
    set -o noclobber
    local ok=0
    printf 'pid=%s time=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$LOCK_PATH" 2>/dev/null && ok=1
    set +o noclobber
    if [[ "$ok" -eq 1 ]]; then
        LOCK_HELD=1
        return 0
    fi
    local info=''
    [[ -f "$LOCK_PATH" ]] && info="$(cat "$LOCK_PATH" 2>/dev/null || true)"
    die "Session is locked by another run (lock: $LOCK_PATH, $info). Remove the lock file manually if that run is no longer active."
}
release_lock() {
    [[ "$LOCK_HELD" -eq 1 ]] || return 0
    rm -f "$LOCK_PATH"
    LOCK_HELD=0
}

if [[ "$CLOSE_SESSION" -eq 1 ]]; then
    acquire_lock
    trap release_lock EXIT HUP INT TERM
    [[ -f "$SESSION_PATH" ]] || die "Session file not found: $SESSION"
    rm -f "$SESSION_PATH" "$SNAP_SIDECAR"
    printf '[ANTIGRAVITY_SESSION] closed path=%s\n' "$SESSION_PATH"
    exit 0
fi

if [[ -n "$SESSION_PATH" ]]; then
    acquire_lock
    trap release_lock EXIT HUP INT TERM
fi

# Dirty set as repo-relative NUL-separated paths, loaded into a bash array.
# Rename entries carry two NUL fields (old path, new path); both are kept.
# Fails closed: on any git error the caller must treat the tree as unknown-dirty.
dirty_paths() {
    local -n _out="$1"
    _out=()
    local raw_file entry status path
    raw_file="$(mktemp "${TMPDIR:-/tmp}/antigravity_status.XXXXXX")"
    if ! git -C "$ROOT" -c core.excludesFile= status --porcelain=v1 --untracked-files=all -z >"$raw_file" 2>/dev/null; then
        rm -f "$raw_file"
        die 'Could not read Git status.'
    fi
    while IFS= read -r -d '' entry; do
        [[ ${#entry} -ge 3 ]] || continue
        status="${entry:0:2}"
        path="${entry:3}"
        _out+=("$path")
        if [[ "$status" == *R* ]]; then
            IFS= read -r -d '' path || true
            _out+=("$path")
        fi
    done <"$raw_file"
    rm -f "$raw_file"
}

# Deduplicate an array of NUL-safe strings, output via nameref (sorted, unique).
dedup_sorted() {
    local -n _src="$1" _dst="$2"
    local -A seen=()
    local sorted=()
    local p
    for p in "${_src[@]}"; do
        [[ -n "$p" ]] || continue
        [[ -z "${seen[$p]+x}" ]] || continue
        seen[$p]=1
        sorted+=("$p")
    done
    if [[ ${#sorted[@]} -gt 0 ]]; then
        mapfile -t sorted < <(printf '%s\n' "${sorted[@]}" | sort)
    fi
    _dst=("${sorted[@]}")
}

read_session_field() {
    # $1=file $2=key ; values are base64-encoded except round which is a plain int.
    awk -F= -v key="$2" '$1==key{print substr($0, length($1)+2); exit}' "$1"
}
count_session_field() {
    awk -F= -v key="$2" '$1==key{c++} END{print c+0}' "$1"
}
read_session_owned() {
    # $1=array name (nameref) $2=session file path
    local -n _out="$1"
    local _sfile="$2"
    _out=()
    local enc dec
    while IFS= read -r enc; do
        [[ -n "$enc" ]] || continue
        dec="$(b64d "$enc")" || die 'Session file is invalid: unreadable owned entry.'
        _out+=("$dec")
    done < <(awk -F= '$1=="owned"{print substr($0, length($1)+2)}' "$_sfile")
}

validate_owned_path() {
    # Non-empty, relative, forward-slash, no ".." segment, not absolute.
    local p="$1"
    [[ -n "$p" ]] || die 'Session file is invalid: empty owned entry.'
    [[ "$p" != /* ]] || die "Session file is invalid: owned entry is absolute: $p"
    [[ "$p" != *'\'* ]] || die "Session file is invalid: owned entry must use forward slashes: $p"
    local seg
    IFS='/' read -ra _segs <<<"$p"
    for seg in "${_segs[@]}"; do
        [[ "$seg" != '..' ]] || die "Session file is invalid: owned entry contains '..': $p"
    done
}

session_write() {
    # $1=session path $2=snapshot path $3=round $4-... owned entries (array elements)
    local sfile="$1" path="$2" round="$3"
    shift 3
    umask 077
    {
        printf 'version=1\n'
        printf 'repo=%s\n' "$(b64e "$ROOT")"
        printf 'snapshot=%s\n' "$(b64e "$path")"
        printf 'round=%s\n' "$round"
        local p
        for p in "$@"; do
            [[ -n "$p" ]] || continue
            printf 'owned=%s\n' "$(b64e "$p")"
        done
    } >"$sfile"
}

# Create a file exclusively (fails if it already exists), so a pre-existing
# link at that path can never be followed when we first materialize it.
create_exclusive() {
    ( set -o noclobber; : >"$1" ) 2>/dev/null || die "Could not create session file exclusively: $1"
}

IS_CONTINUATION=0
OWNED=()
ROUND=1
SNAP=''

if [[ -n "$SESSION_PATH" && -f "$SESSION_PATH" ]]; then
    IS_CONTINUATION=1
    # --- strict session integrity validation ---
    for field in version repo snapshot round; do
        cnt="$(count_session_field "$SESSION_PATH" "$field")"
        [[ "$cnt" -eq 1 ]] || die "Session file is invalid: duplicated or missing '$field' field."
    done
    SVERSION="$(read_session_field "$SESSION_PATH" version)"
    [[ "$SVERSION" == 1 ]] || die 'Session file is invalid: unsupported version.'
    SREPO="$(b64d "$(read_session_field "$SESSION_PATH" repo)")" || die 'Session file is invalid: unreadable repo field.'
    [[ "$SREPO" == "$ROOT" ]] || die "Session belongs to a different repository: $SREPO"
    SNAP="$(b64d "$(read_session_field "$SESSION_PATH" snapshot)")" || die 'Session file is invalid: unreadable snapshot field.'
    [[ "$SNAP" == "$SNAP_SIDECAR" ]] || die "Session file is invalid: unexpected snapshot path: $SNAP"
    [[ -f "$SNAP" ]] || die "Session snapshot not found: $SNAP"
    SROUND="$(read_session_field "$SESSION_PATH" round)"
    [[ "$SROUND" =~ ^[0-9]+$ && "$SROUND" -ge 1 ]] || die "Session file is invalid: round is not a positive integer: $SROUND"
    ROUND=$((SROUND + 1))
    read_session_owned OWNED "$SESSION_PATH"
    for p in "${OWNED[@]}"; do validate_owned_path "$p"; done
    # Verify the sidecar snapshot's own repo field matches before trusting it.
    SNAP_REPO_LINE="$(grep -m1 '^repo=' "$SNAP" 2>/dev/null || true)"
    if [[ -n "$SNAP_REPO_LINE" ]]; then
        SNAP_REPO="$(b64d "${SNAP_REPO_LINE#repo=}")" || die 'Session snapshot is invalid: unreadable repo field.'
        [[ "$SNAP_REPO" == "$ROOT" ]] || die "Session snapshot belongs to a different repository: $SNAP_REPO"
    fi

    dirty_paths CURRENT_DIRTY
    declare -A OWNED_SET=()
    for p in "${OWNED[@]}"; do OWNED_SET["$p"]=1; done
    OUTSIDE=()
    for p in "${CURRENT_DIRTY[@]}"; do
        [[ -n "$p" ]] || continue
        [[ -n "${OWNED_SET[$p]+x}" ]] || OUTSIDE+=("$p")
    done
    dedup_sorted OUTSIDE OUTSIDE
    if [[ ${#OUTSIDE[@]} -gt 0 ]]; then
        if [[ "$ADOPT_CHANGES" -ne 1 ]]; then
            die "Working tree has changes outside this delegation session: $(display_join "${OUTSIDE[@]}")"
        fi
        ADOPTED=("${OWNED[@]}" "${OUTSIDE[@]}")
        dedup_sorted ADOPTED OWNED
        printf '[ANTIGRAVITY_SESSION] adopted=%s paths=%s\n' "${#OUTSIDE[@]}" "$(display_join "${OUTSIDE[@]}")"
        printf 'ANTIGRAVITY: adopted=%s\n' "$(display_join "${OUTSIDE[@]}")" >&2
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
    # antigravity-verify.sh already creates the snapshot exclusively (refuses
    # an existing file or symlink at --out), so only the session file itself
    # needs an explicit exclusive create here.
    "$VERIFY" snapshot --repo "$ROOT" --out "$SNAP" >/dev/null
    if [[ -n "$SESSION_PATH" ]]; then
        create_exclusive "$SESSION_PATH"
        session_write "$SESSION_PATH" "$SNAP" 1
    fi
fi

INSTRUCTION="$(mktemp "${TMPDIR:-/tmp}/antigravity_implement_prompt.XXXXXX")"
cleanup() {
    [[ -n "$SESSION_PATH" ]] || rm -f "$SNAP"
    rm -f "$INSTRUCTION"
    release_lock
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

# Failure ordering precedence (most severe first):
#   1. session write failure -> exit 4, reporting the wrapper/verify codes too
#   2. verify (check) failure -> its own exit code
#   3. wrapper failure -> its own exit code
#   4. success -> exit 0
session_write_failed=0
if [[ -n "$SESSION_PATH" ]]; then
    dirty_paths FINAL_DIRTY
    NEW_OWNED_RAW=("${OWNED[@]}" "${FINAL_DIRTY[@]}")
    dedup_sorted NEW_OWNED_RAW NEW_OWNED
    if session_write "$SESSION_PATH" "$SNAP" "$ROUND" "${NEW_OWNED[@]}"; then
        printf '[ANTIGRAVITY_SESSION] round=%s owned=%s path=%s\n' "$ROUND" "${#NEW_OWNED[@]}" "$SESSION_PATH"
        printf 'ANTIGRAVITY: owned=%s\n' "$(display_join "${NEW_OWNED[@]}")" >&2
    else
        session_write_failed=1
    fi
fi

if [[ "$session_write_failed" -eq 1 ]]; then
    printf '%s Could not update session file %s (wrapper_exit=%s verify_exit=%s)\n' "$ERROR" "$SESSION_PATH" "$run_code" "$check_code" >&2
    exit 4
fi
[[ "$check_code" -eq 0 ]] || exit "$check_code"
if [[ "$run_code" -ne 0 ]]; then
    printf '%s Antigravity run failed with exit code %s. See the wrapper output above.
' "$ERROR" "$run_code"
    exit "$run_code"
fi
exit 0
