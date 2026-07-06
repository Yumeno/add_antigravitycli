#!/usr/bin/env bash
# Git snapshot/check。通常の作業ファイル変更は報告し、Git状態・機密候補の変更は違反とする。
set -euo pipefail
ERROR='[ANTIGRAVITY_VERIFY_ERROR]'
VIOLATION='[ANTIGRAVITY_VERIFY_VIOLATION]'
ALLOWED='[ANTIGRAVITY_VERIFY_ALLOWED]'
die() {
    local code=1
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then code="$1"; shift; fi
    printf '%s %s\n' "$ERROR" "$*" >&2
    exit "$code"
}
b64e() { printf '%s' "$1" | base64 | tr -d '\r\n'; }
b64d() {
    if printf '' | base64 --decode >/dev/null 2>&1; then
        printf '%s' "$1" | base64 --decode 2>/dev/null
    else
        printf '%s' "$1" | base64 -D 2>/dev/null
    fi
}
hash_path() {
    if [[ -L "$1" ]]; then
        local target digest='unresolvable'
        target="$(readlink "$1")"
        if [[ -f "$1" ]]; then
            if command -v sha256sum >/dev/null 2>&1; then digest="$(sha256sum "$1" | awk '{print $1}')"
            else digest="$(shasum -a 256 "$1" | awk '{print $1}')"; fi
        fi
        printf 'symlink:%s:%s' "$target" "$digest"
    elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

CMD="${1:-}"; [[ -n "$CMD" ]] || die 1 'Expected snapshot or check.'; shift || true
REPO=''; OUT=''; SNAP=''; ALLOWS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) [[ $# -ge 2 ]] || die '--repo requires a value.'; REPO="$2"; shift 2 ;;
        --out) [[ $# -ge 2 ]] || die '--out requires a value.'; OUT="$2"; shift 2 ;;
        --snapshot) [[ $# -ge 2 ]] || die '--snapshot requires a value.'; SNAP="$2"; shift 2 ;;
        --allow) [[ $# -ge 2 ]] || die '--allow requires a value.'; ALLOWS+=("$2"); shift 2 ;;
        *) die "Unknown option: $1" ;;
    esac
done
[[ "$CMD" == snapshot || "$CMD" == check ]] || die "Unknown subcommand: $CMD"
REPO="${REPO:-$PWD}"; [[ -d "$REPO" ]] || die "Repository directory not found: $REPO"
REQUESTED="$(cd "$REPO" && pwd -P)"
REPO="$(git -C "$REQUESTED" rev-parse --show-toplevel 2>/dev/null)" || die "Not a git repository: $REQUESTED"
REPO="$(cd "$REPO" && pwd -P)"
git_repo() { git -C "$REPO" "$@"; }
GIT_DIR="$(git_repo rev-parse --absolute-git-dir)" || die 2 'Unable to resolve Git directory.'
CONFIG="$GIT_DIR/config"
HOOKS="$GIT_DIR/hooks"

rel() {
    if [[ "$1" == "$CONFIG" ]]; then printf '.git/config'
    elif [[ "$1" == "$HOOKS/"* ]]; then printf '.git/hooks/%s' "${1#"$HOOKS/"}"
    elif [[ "$1" == "$GIT_DIR/refs/"* ]]; then printf '.git/refs/%s' "${1#"$GIT_DIR/refs/"}"
    elif [[ "$1" == "$GIT_DIR/"* ]]; then printf '.git/%s' "${1#"$GIT_DIR/"}"
    else printf '%s' "${1#"$REPO/"}"; fi
}
enumerate() {
    local dest="$1"; : >"$dest"
    find "$REPO" -path "$REPO/.git" -prune -o \( -type f -o -type l \) \
        \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' \) -print0 >>"$dest"
    [[ ! -e "$REPO/.gitmodules" && ! -L "$REPO/.gitmodules" ]] || printf '%s\0' "$REPO/.gitmodules" >>"$dest"
    [[ ! -e "$CONFIG" && ! -L "$CONFIG" ]] || printf '%s\0' "$CONFIG" >>"$dest"
    [[ ! -d "$HOOKS" ]] || find "$HOOKS" -maxdepth 1 \( -type f -o -type l \) ! -name '*.sample' -print0 >>"$dest"
    for p in "$GIT_DIR/HEAD" "$GIT_DIR/packed-refs" "$GIT_DIR/info/exclude"; do
        [[ ! -e "$p" && ! -L "$p" ]] || printf '%s\0' "$p" >>"$dest"
    done
    [[ ! -d "$GIT_DIR/refs" ]] || find "$GIT_DIR/refs" \( -type f -o -type l \) -print0 >>"$dest"
}
LIST="$(mktemp "${TMPDIR:-/tmp}/antigravity_verify.XXXXXX")" || die 'Unable to create temp file.'
CURRENT_FILE="$(mktemp "${TMPDIR:-/tmp}/antigravity_current.XXXXXX")" || die 'Unable to create temp file.'
trap 'rm -f "$LIST" "$CURRENT_FILE"' EXIT

canonical_out() {
    local parent; parent="$(dirname "$1")"; [[ -d "$parent" ]] || die "Snapshot parent directory not found: $parent"
    parent="$(cd "$parent" && pwd -P)"
    printf '%s/%s' "$parent" "$(basename "$1")"
}

if [[ "$CMD" == snapshot ]]; then
    [[ -z "$SNAP" ]] || die '--snapshot is invalid with snapshot.'
    [[ -n "$OUT" ]] || OUT="$(mktemp -u "${TMPDIR:-/tmp}/antigravity_snapshot.XXXXXX")"
    FULL="$(canonical_out "$OUT")"
    [[ "$FULL" != "$REPO" && "$FULL" != "$REPO/"* ]] || die 'snapshot file must be outside the repository'
    [[ ! -e "$FULL" && ! -L "$FULL" ]] || die "Snapshot file already exists: $FULL"
    STATUS="$(git_repo status --porcelain=v1 -uall)" || die 2 'Unable to read Git status.'
    [[ -z "$STATUS" ]] || die 'Working tree must be clean before snapshot.'
    HEAD="$(git_repo rev-parse HEAD)" || die 2 'Unable to read HEAD.'
    BRANCH="$(git_repo symbolic-ref --quiet --short HEAD 2>/dev/null || printf '(detached)')"
    enumerate "$LIST"
    umask 077
    {
        printf 'version=1\nrepo=%s\nhead=%s\nbranch=%s\n' "$(b64e "$REPO")" "$HEAD" "$(b64e "$BRANCH")"
        while IFS= read -r -d '' p; do printf 'protected=%s:%s\n' "$(b64e "$(rel "$p")")" "$(hash_path "$p")"; done <"$LIST"
    } >"$FULL"
    printf 'snapshot=%s\nhead=%s\nbranch=%s\n' "$FULL" "$HEAD" "$BRANCH"
    exit 0
fi

[[ -z "$OUT" ]] || die '--out is invalid with check.'
[[ -n "$SNAP" && -f "$SNAP" ]] || die "Snapshot file not found: $SNAP"
VERSION="$(awk -F= '$1=="version"{print $2; exit}' "$SNAP")"; [[ "$VERSION" == 1 ]] || die 'Unsupported snapshot version.'
SREPO64="$(awk -F= '$1=="repo"{print substr($0,6); exit}' "$SNAP")"
SREPO="$(b64d "$SREPO64")" || die 'Invalid snapshot repo.'
[[ "$SREPO" == "$REPO" ]] || die 'Snapshot belongs to another repository.'
OLD_HEAD="$(awk -F= '$1=="head"{print $2; exit}' "$SNAP")"
OLD_BRANCH64="$(awk -F= '$1=="branch"{print substr($0,8); exit}' "$SNAP")"
OLD_BRANCH="$(b64d "$OLD_BRANCH64")" || die 'Invalid snapshot branch.'
NEW_HEAD="$(git_repo rev-parse HEAD)" || die 'Unable to read HEAD.'
NEW_BRANCH="$(git_repo symbolic-ref --quiet --short HEAD 2>/dev/null || printf '(detached)')"
violations=0
if [[ "$OLD_HEAD" != "$NEW_HEAD" ]]; then printf '%s HEAD changed: %s -> %s\n' "$VIOLATION" "$OLD_HEAD" "$NEW_HEAD"; violations=1; fi
if [[ "$OLD_BRANCH" != "$NEW_BRANCH" ]]; then printf '%s branch changed: %s -> %s\n' "$VIOLATION" "$OLD_BRANCH" "$NEW_BRANCH"; violations=1; fi

enumerate "$LIST"
while IFS= read -r -d '' p; do
    path="$(rel "$p")"
    printf '%s:%s\n' "$(b64e "$path")" "$(hash_path "$p")" >>"$CURRENT_FILE"
done <"$LIST"

allowed() { local a; for a in "${ALLOWS[@]}"; do [[ "$a" == "$1" ]] && return 0; done; return 1; }
report_change() {
    local path="$1" action="$2"
    if allowed "$path"; then printf '%s protected file %s (allowed): %s\n' "$ALLOWED" "$action" "$path"
    else printf '%s protected file %s: %s\n' "$VIOLATION" "$action" "$path"; violations=1; fi
}
while IFS= read -r line; do
    payload="${line#protected=}"; enc="${payload%%:*}"; old="${payload#*:}"
    path="$(b64d "$enc")" || die 'Invalid snapshot protected path.'
    [[ -n "$path" && "$old" =~ ^([0-9a-f]{64}|symlink:.*)$ ]] || die 'Invalid snapshot protected entry.'
    now="$(awk -F: -v key="$enc" '$1==key {print substr($0,length($1)+2); exit}' "$CURRENT_FILE")"
    [[ "$old" == "$now" ]] && continue
    if [[ -z "$now" ]]; then report_change "$path" deleted; else report_change "$path" modified; fi
done < <(grep '^protected=' "$SNAP" || true)
while IFS= read -r line; do
    enc="${line%%:*}"
    grep -q "^protected=${enc}:" "$SNAP" && continue
    path="$(b64d "$enc")" || die 'Invalid current protected path.'
    report_change "$path" added
done <"$CURRENT_FILE"
printf '%s\n' '--- git status --short ---'
git_repo status --short
printf '%s\n' '--- changed files ---'
git_repo diff --name-only
git_repo diff --cached --name-only
[[ "$violations" -eq 0 ]] || exit 3
