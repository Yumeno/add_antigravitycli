#!/usr/bin/env bash
# Imports an agy-reported artifact (image) into the repository after validating
# its real path, content magic bytes/dimensions, and the destination location.
#
# Threat model: validation and the copy are separate operations, so this helper is NOT
# safe against a concurrent writer with access to the same directories (same-user TOCTOU
# races). It defends against wrong/hostile paths reported by the agent, links, and
# unsupported/malformed content -- not against a racing process swapping files mid-import.
# Output-line contract: source=/destination= are printed raw and are the last two fields,
# specifically because paths may contain '=' or spaces; both are validated to contain no
# CR/LF so no line can be forged by an embedded newline.
set -euo pipefail
ERROR='[ANTIGRAVITY_ARTIFACT_ERROR]'
die() { printf '%s %s\n' "$ERROR" "$*"; exit 1; }

# Image size limits. Normal workload is agy-generated images in the 1024-1376px range;
# these caps just keep this helper from processing pathological/hostile input.
MAX_IMAGE_DIMENSION=8192
MAX_IMAGE_PIXELS=64000000

CMD="${1:-}"; [[ "$CMD" == "import" ]] || die "Unknown subcommand: $CMD"
shift || true
REPO=''; SOURCE=''; DEST=''; OVERWRITE=0; CONVERSATION_ID=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) [[ $# -ge 2 ]] || die '--repo requires a value.'; REPO="$2"; shift 2 ;;
        --source) [[ $# -ge 2 ]] || die '--source requires a value.'; SOURCE="$2"; shift 2 ;;
        --destination) [[ $# -ge 2 ]] || die '--destination requires a value.'; DEST="$2"; shift 2 ;;
        --conversation-id) [[ $# -ge 2 ]] || die '--conversation-id requires a value.'; CONVERSATION_ID="$2"; shift 2 ;;
        --overwrite) OVERWRITE=1; shift ;;
        *) die "Unknown option: $1" ;;
    esac
done
[[ -n "$REPO" ]] || die '--repo is required.'
[[ -n "$SOURCE" ]] || die '--source is required.'
[[ -n "$DEST" ]] || die '--destination is required.'
[[ -n "$CONVERSATION_ID" ]] || die '--conversation-id is required.'
case "$SOURCE" in *$'\r'*|*$'\n'*) die 'path contains a line break' ;; esac
case "$DEST" in *$'\r'*|*$'\n'*) die 'path contains a line break' ;; esac
case "$CONVERSATION_ID" in
    *..*) die "Invalid conversation id: $CONVERSATION_ID" ;;
esac
case "$CONVERSATION_ID" in
    ''|*[!A-Za-z0-9-]*) die "Invalid conversation id: $CONVERSATION_ID" ;;
esac

[[ -d "$REPO" ]] || die "Repository not found: $REPO"
REQUESTED="$(cd "$REPO" && pwd -P)"
ROOT="$(git -C "$REQUESTED" rev-parse --show-toplevel 2>/dev/null)" || die "Not a Git repository: $REQUESTED"
ROOT="$(cd "$ROOT" && pwd -P)"

BRAIN_DIR="${ANTIGRAVITY_BRAIN_DIR:-$HOME/.gemini/antigravity-cli/brain}"
[[ -d "$BRAIN_DIR" ]] || die "Brain directory not found: $BRAIN_DIR"
BRAIN_DIR="$(cd "$BRAIN_DIR" && pwd -P)"

# Rejects the path itself and every ancestor directory component that is a link.
any_component_is_link() {
    local current="$1"
    while :; do
        [[ ! -L "$current" ]] || return 0
        local parent
        parent="$(dirname "$current")"
        [[ "$parent" != "$current" ]] || break
        current="$parent"
    done
    return 1
}

# --- validate source ---
[[ -e "$SOURCE" || -L "$SOURCE" ]] || die "Source not found: $SOURCE"
if any_component_is_link "$SOURCE"; then die "Source path must not contain a link"; fi
[[ -f "$SOURCE" ]] || die "Source is not a regular file: $SOURCE"
SOURCE_DIR="$(cd "$(dirname "$SOURCE")" && pwd -P)" || die "Could not resolve source directory: $SOURCE"
SOURCE_REAL="$SOURCE_DIR/$(basename "$SOURCE")"
[[ ! -L "$SOURCE_REAL" ]] || die "Source path must not contain a link"
# Source must live directly inside <brain>/<conversation-id>/ (exactly one path component
# below that directory) -- not in a subdirectory, and not in a different conversation's tree.
CONV_DIR="$BRAIN_DIR/$CONVERSATION_ID"
[[ -d "$CONV_DIR" ]] || die "Source is not inside the conversation directory: $BRAIN_DIR/$CONVERSATION_ID"
CONV_DIR_REAL="$(cd "$CONV_DIR" && pwd -P)" || die "Source is not inside the conversation directory: $BRAIN_DIR/$CONVERSATION_ID"
if [[ "$SOURCE_DIR" != "$CONV_DIR_REAL" ]]; then
    die "Source is not inside the conversation directory: $BRAIN_DIR/$CONVERSATION_ID"
fi
SOURCE_BYTES="$(wc -c <"$SOURCE_REAL" | tr -d ' ')"
[[ "$SOURCE_BYTES" -gt 0 ]] || die "Source file is empty: $SOURCE"

# Reads N bytes starting at offset (0-based) as decimal byte values, one per line.
read_bytes() {
    local off="$1" len="$2"
    dd if="$SOURCE_REAL" bs=1 skip="$off" count="$len" 2>/dev/null | od -An -tu1 -v | tr -s ' \n' ' '
}
be16() { # $1=high $2=low
    echo $(( ($1 << 8) | $2 ))
}
be32() { # $1..$4 big-endian bytes
    echo $(( ($1 << 24) | ($2 << 16) | ($3 << 8) | $4 ))
}

HEAD8="$(read_bytes 0 8)"
read -r -a H8 <<<"$HEAD8"
TYPE=''
WIDTH=0
HEIGHT=0
if [[ "${#H8[@]}" -ge 8 && "${H8[0]}" -eq 137 && "${H8[1]}" -eq 80 && "${H8[2]}" -eq 78 && "${H8[3]}" -eq 71 && \
      "${H8[4]}" -eq 13 && "${H8[5]}" -eq 10 && "${H8[6]}" -eq 26 && "${H8[7]}" -eq 10 ]]; then
    TYPE="png"
    # First chunk must be IHDR with length exactly 13, and the file must contain the whole
    # chunk plus its 4-byte CRC (>= 8 sig + 4 len + 4 tag + 13 data + 4 crc = 33 bytes).
    [[ "$SOURCE_BYTES" -ge 33 ]] || die "could not read image dimensions"
    IHDR_TAG="$(dd if="$SOURCE_REAL" bs=1 skip=12 count=4 2>/dev/null)"
    LENB="$(read_bytes 8 4)"
    read -r -a LNB <<<"$LENB"
    [[ "${#LNB[@]}" -ge 4 ]] || die "could not read image dimensions"
    IHDR_LEN="$(be32 "${LNB[0]}" "${LNB[1]}" "${LNB[2]}" "${LNB[3]}")"
    [[ "$IHDR_TAG" == "IHDR" && "$IHDR_LEN" -eq 13 ]] || die "could not read image dimensions"
    IHDR="$(read_bytes 16 8)"
    read -r -a IB <<<"$IHDR"
    [[ "${#IB[@]}" -ge 8 ]] || die "could not read image dimensions"
    WIDTH="$(be32 "${IB[0]}" "${IB[1]}" "${IB[2]}" "${IB[3]}")"
    HEIGHT="$(be32 "${IB[4]}" "${IB[5]}" "${IB[6]}" "${IB[7]}")"
elif [[ "${#H8[@]}" -ge 3 && "${H8[0]}" -eq 255 && "${H8[1]}" -eq 216 && "${H8[2]}" -eq 255 ]]; then
    TYPE="jpeg"
    POS=2
    FOUND=0
    while [[ $((POS + 2)) -le "$SOURCE_BYTES" ]]; do
        PAIR="$(read_bytes "$POS" 2)"
        read -r -a P <<<"$PAIR"
        [[ "${#P[@]}" -ge 2 ]] || break
        if [[ "${P[0]}" -ne 255 ]]; then POS=$((POS + 1)); continue; fi
        MARKER="${P[1]}"
        if [[ "$MARKER" -eq 255 ]]; then POS=$((POS + 1)); continue; fi
        # Standalone markers (no length field): RST0-7, TEM, SOI.
        if [[ "$MARKER" -ge 208 && "$MARKER" -le 215 ]]; then POS=$((POS + 2)); continue; fi
        if [[ "$MARKER" -eq 1 || "$MARKER" -eq 216 ]]; then POS=$((POS + 2)); continue; fi
        # EOI or SOS reached before a SOF: no dimensions found.
        if [[ "$MARKER" -eq 217 || "$MARKER" -eq 218 ]]; then break; fi
        [[ $((POS + 4)) -le "$SOURCE_BYTES" ]] || die "could not read image dimensions"
        LENB="$(read_bytes $((POS + 2)) 2)"
        read -r -a LB <<<"$LENB"
        [[ "${#LB[@]}" -ge 2 ]] || die "could not read image dimensions"
        SEGLEN="$(be16 "${LB[0]}" "${LB[1]}")"
        [[ "$SEGLEN" -ge 2 && $((POS + 2 + SEGLEN)) -le "$SOURCE_BYTES" ]] || die "could not read image dimensions"
        IS_SOF=0
        if [[ "$MARKER" -ge 192 && "$MARKER" -le 207 && "$MARKER" -ne 196 && "$MARKER" -ne 200 && "$MARKER" -ne 204 ]]; then
            IS_SOF=1
        fi
        if [[ "$IS_SOF" -eq 1 ]]; then
            [[ "$SEGLEN" -ge 8 ]] || die "could not read image dimensions"
            NFB="$(read_bytes $((POS + 9)) 1)"
            read -r -a NB <<<"$NFB"
            [[ "${#NB[@]}" -ge 1 ]] || die "could not read image dimensions"
            NF="${NB[0]}"
            [[ "$SEGLEN" -eq $((8 + 3 * NF)) ]] || die "could not read image dimensions"
            DIMS="$(read_bytes $((POS + 5)) 4)"
            read -r -a DB <<<"$DIMS"
            [[ "${#DB[@]}" -ge 4 ]] || die "could not read image dimensions"
            HEIGHT="$(be16 "${DB[0]}" "${DB[1]}")"
            WIDTH="$(be16 "${DB[2]}" "${DB[3]}")"
            FOUND=1
            break
        fi
        POS=$((POS + 2 + SEGLEN))
    done
    [[ "$FOUND" -eq 1 ]] || die "could not read image dimensions"
else
    die "unsupported or unrecognized image content"
fi
[[ "$WIDTH" -gt 0 && "$HEIGHT" -gt 0 ]] || die "could not read image dimensions"
if [[ "$WIDTH" -gt "$MAX_IMAGE_DIMENSION" || "$HEIGHT" -gt "$MAX_IMAGE_DIMENSION" || $((WIDTH * HEIGHT)) -gt "$MAX_IMAGE_PIXELS" ]]; then
    die "image dimensions out of range: ${WIDTH}x${HEIGHT}"
fi

# --- validate destination ---
case "$DEST" in
    /*) DEST_FULL="$DEST" ;;
    *) DEST_FULL="$ROOT/$DEST" ;;
esac
DEST_PARENT_RAW="$(dirname "$DEST_FULL")"
DEST_NAME="$(basename "$DEST_FULL")"
[[ -d "$DEST_PARENT_RAW" ]] || die "Destination parent directory does not exist: $DEST_PARENT_RAW"
if any_component_is_link "$DEST_PARENT_RAW"; then die "Destination parent must not contain a link"; fi
DEST_PARENT_REAL="$(cd "$DEST_PARENT_RAW" && pwd -P)" || die "Could not resolve destination parent: $DEST_PARENT_RAW"
DEST_RESOLVED="$DEST_PARENT_REAL/$DEST_NAME"
case "$DEST_RESOLVED" in
    "$ROOT"/*) ;;
    *) die "Destination must be inside the repository: $DEST" ;;
esac
DEST_REL="${DEST_RESOLVED#"$ROOT"/}"

# Protected-path and extension checks are case-insensitive: normalize with LC_ALL=C tr so
# the comparison does not depend on locale-specific case folding.
DEST_REL_LOWER="$(printf '%s' "$DEST_REL" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
is_protected() {
    local p="$1" name
    name="$(basename "$p")"
    case "$p" in
        .git|.git/*) return 0 ;;
    esac
    case "$name" in
        .env|.env.*) return 0 ;;
    esac
    case "$name" in
        *.pem|*.key|*.p12|*.pfx) return 0 ;;
    esac
    return 1
}
if is_protected "$DEST_REL_LOWER"; then die "Destination is a protected path: $DEST_REL"; fi

LOWER_NAME="$(printf '%s' "$DEST_NAME" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
case "$LOWER_NAME" in
    *.png) EXT_TYPE="png" ;;
    *.jpg|*.jpeg) EXT_TYPE="jpeg" ;;
    *) EXT_TYPE="" ;;
esac
[[ "$EXT_TYPE" == "$TYPE" ]] || die "destination extension does not match image type $TYPE"

[[ ! -L "$DEST_RESOLVED" ]] || die "Destination must not be a link"
if [[ -e "$DEST_RESOLVED" ]]; then
    [[ "$OVERWRITE" -eq 1 ]] || die "Destination already exists: $DEST_REL"
fi

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}
# Hash the source once before copying: this is the expected hash. Never re-hash the source
# path again after this point (the copy below is the only other read of that path).
SOURCE_HASH="$(sha256_of "$SOURCE_REAL")"

# --- copy: create the temp file atomically with mktemp (unpredictable name, 0600 perms via
# umask), then copy INTO it, then move into place. Any failure after temp creation removes it.
umask 077
TMP_DEST="$(mktemp "$DEST_PARENT_REAL/.antigravity-artifact.XXXXXX")" || die 'Unable to create a temporary file for the copy.'
cleanup() { rm -f "$TMP_DEST"; }
trap cleanup EXIT HUP INT TERM
if [[ -L "$TMP_DEST" || ! -f "$TMP_DEST" ]]; then die "Temporary file is not a regular file: $TMP_DEST"; fi
cat -- "$SOURCE_REAL" >"$TMP_DEST"
DEST_HASH="$(sha256_of "$TMP_DEST")"
[[ "$SOURCE_HASH" == "$DEST_HASH" ]] || die "Copied file hash does not match source"
# Final link re-check happens as close as possible to the rename that replaces $Overwrite's
# target, so the destination is never lost except by this one atomic move.
[[ ! -L "$DEST_RESOLVED" ]] || die "Destination must not be a link"
mv -f -- "$TMP_DEST" "$DEST_RESOLVED"
trap - EXIT HUP INT TERM

printf '[ANTIGRAVITY_ARTIFACT_OK] type=%s width=%s height=%s bytes=%s sha256=%s source=%s destination=%s\n' \
    "$TYPE" "$WIDTH" "$HEIGHT" "$SOURCE_BYTES" "$SOURCE_HASH" "$SOURCE_REAL" "$DEST_REL"
exit 0
