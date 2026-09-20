#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ARTIFACT="$HERE/../antigravity-artifact.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agy_artifact_test.XXXXXX")"
BRAIN="$ROOT/brain"
CONV="$BRAIN/conv1"
REPO="$ROOT/repo"
trap 'rm -rf "$ROOT"' EXIT
passed=0; total=0

# 1x1 PNG (real fixed bytes) and a minimal 3x2 JPEG (SOF0 only).
PNG_HEX="89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d494441547801636000000002000173d24b5a0000000049454e44ae426082"
JPEG_HEX="ffd8ffc0001108000200030301220002110103110 1ffd9"
JPEG_HEX="${JPEG_HEX// /}"

hex_to_file() {
    # $1=hex $2=out file
    printf '%s' "$1" | xxd -r -p >"$2" 2>/dev/null || printf '%s' "$1" | python3 -c 'import sys,binascii;sys.stdout.buffer.write(binascii.unhexlify(sys.argv[1]))' "$1" >"$2"
}

new_fixtures() {
    rm -rf "$ROOT"; mkdir -p "$CONV"
    hex_to_file "$PNG_HEX" "$CONV/img.png"
    hex_to_file "$JPEG_HEX" "$CONV/img.jpg"
    printf 'not an image' >"$CONV/notes.txt"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    git -C "$REPO" config user.name Test
    git -C "$REPO" config user.email test@example.com
    printf 'base\n' >"$REPO/base.txt"
    git -C "$REPO" add base.txt
    git -C "$REPO" commit -qm base
    export ANTIGRAVITY_BRAIN_DIR="$BRAIN"
}

run_artifact() { set +e; output="$(bash "$ARTIFACT" "$@" 2>&1)"; code=$?; set -e; }
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}
testcase() { name="$1"; shift; total=$((total+1)); if "$@"; then printf 'PASS: %s\n' "$name"; passed=$((passed+1)); else printf 'FAIL: %s\n' "$name"; fi; }

t_png_ok() {
    new_fixtures
    local dest="$REPO/out.png"
    run_artifact import --repo "$REPO" --source "$CONV/img.png" --destination "$dest"
    [[ $code -eq 0 && "$output" == *'[ANTIGRAVITY_ARTIFACT_OK]'* && "$output" == *'type=png'* && "$output" == *'width=1 height=1'* && "$output" == *'destination=out.png'* ]] || return 1
    [[ -f "$dest" ]] || return 1
    local src_hash dst_hash
    src_hash="$(sha256_of "$CONV/img.png")"
    dst_hash="$(sha256_of "$dest")"
    [[ "$src_hash" == "$dst_hash" && "$output" == *"sha256=$src_hash"* ]] || return 1
    cmp -s "$CONV/img.png" "$dest"
}
t_jpeg_ok() {
    new_fixtures
    local dest="$REPO/out.jpg"
    run_artifact import --repo "$REPO" --source "$CONV/img.jpg" --destination "$dest"
    [[ $code -eq 0 && "$output" == *'type=jpeg'* && "$output" == *'width=3 height=2'* ]]
}
t_source_outside_brain() {
    new_fixtures
    local outside="$ROOT/outside.png"
    cp "$CONV/img.png" "$outside"
    run_artifact import --repo "$REPO" --source "$outside" --destination "$REPO/x.png"
    [[ $code -ne 0 && "$output" == *'[ANTIGRAVITY_ARTIFACT_ERROR]'* ]]
}
t_source_link() {
    new_fixtures
    local link="$CONV/link.png"
    ln -s "$CONV/img.png" "$link" 2>/dev/null
    [[ -L "$link" ]] || return 0
    run_artifact import --repo "$REPO" --source "$link" --destination "$REPO/y.png"
    [[ $code -ne 0 && "$output" == *'[ANTIGRAVITY_ARTIFACT_ERROR]'* ]]
}
t_unrecognized_content() {
    new_fixtures
    run_artifact import --repo "$REPO" --source "$CONV/notes.txt" --destination "$REPO/notes.png"
    [[ $code -ne 0 && "$output" == *'unsupported or unrecognized image content'* ]]
}
t_extension_mismatch() {
    new_fixtures
    run_artifact import --repo "$REPO" --source "$CONV/img.jpg" --destination "$REPO/mismatch.png"
    [[ $code -ne 0 && "$output" == *'destination extension does not match image type jpeg'* ]]
}
t_destination_outside_repo() {
    new_fixtures
    run_artifact import --repo "$REPO" --source "$CONV/img.png" --destination "$ROOT/outside2.png"
    [[ $code -ne 0 && "$output" == *'[ANTIGRAVITY_ARTIFACT_ERROR]'* ]]
}
t_destination_exists_without_overwrite() {
    new_fixtures
    cp "$CONV/img.png" "$REPO/exists.png"
    run_artifact import --repo "$REPO" --source "$CONV/img.png" --destination "$REPO/exists.png"
    [[ $code -ne 0 && "$output" == *'already exists'* ]]
}
t_destination_exists_with_overwrite() {
    # Reuses state from the previous case within the same fixture set.
    run_artifact import --repo "$REPO" --source "$CONV/img.png" --destination "$REPO/exists.png" --overwrite
    [[ $code -eq 0 && "$output" == *'[ANTIGRAVITY_ARTIFACT_OK]'* ]]
}
t_destination_protected() {
    new_fixtures
    run_artifact import --repo "$REPO" --source "$CONV/img.png" --destination "$REPO/.env.png"
    [[ $code -ne 0 ]]
}
t_destination_under_git() {
    new_fixtures
    run_artifact import --repo "$REPO" --source "$CONV/img.png" --destination "$REPO/.git/evil.png"
    [[ $code -ne 0 ]]
}
t_missing_parent() {
    new_fixtures
    run_artifact import --repo "$REPO" --source "$CONV/img.png" --destination "$REPO/nope/x.png"
    [[ $code -ne 0 && "$output" == *'parent directory does not exist'* ]]
}
t_truncated_png() {
    new_fixtures
    head -c 20 "$CONV/img.png" >"$CONV/trunc.png"
    run_artifact import --repo "$REPO" --source "$CONV/trunc.png" --destination "$REPO/trunc.png"
    [[ $code -ne 0 && "$output" == *'could not read image dimensions'* ]]
}

testcase png_import_ok t_png_ok
testcase jpeg_import_ok t_jpeg_ok
testcase source_outside_brain_rejected t_source_outside_brain
testcase source_link_rejected t_source_link
testcase unrecognized_content_rejected t_unrecognized_content
testcase extension_mismatch_rejected t_extension_mismatch
testcase destination_outside_repo_rejected t_destination_outside_repo
testcase destination_exists_without_overwrite_rejected t_destination_exists_without_overwrite
testcase destination_exists_with_overwrite_ok t_destination_exists_with_overwrite
testcase destination_protected_rejected t_destination_protected
testcase destination_under_git_rejected t_destination_under_git
testcase missing_parent_rejected t_missing_parent
testcase truncated_png_dimensions_rejected t_truncated_png

printf 'Passed: %d / %d\n' "$passed" "$total"
[[ "$passed" -eq "$total" ]]
