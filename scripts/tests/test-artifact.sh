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
# Additional malformed/edge-case fixtures for structural validation tests.
JPEG_PROGRESSIVE_HEX="ffd8ffc20011080002000303011100011100011100ffd9"
JPEG_APPN_HEX="ffd8ffe000104a46494600010100000100010000ffc00011080002000303011100011100011100ffd9"
JPEG_BADLEN_HEX="ffd8ffc00002ffd9"
JPEG_TRUNCATED_HEX="ffd8ffc000110800"
JPEG_SOS_BEFORE_SOF_HEX="ffd8ffda0002ffd9"
PNG_WRONG_IHDR_LEN_HEX="89504e470d0a1a0a0000000c49484452000000010000000108060000001f15c489"
PNG_HUGE_HEX="89504e470d0a1a0a0000000d4948445200004000000040000806000000a9c81084"
PNG_ZERO_HEX="89504e470d0a1a0a0000000d4948445200000000000000010806000000f0d7afb7"

hex_to_file() {
    # $1=hex $2=out file
    printf '%s' "$1" | xxd -r -p >"$2" 2>/dev/null || printf '%s' "$1" | python3 -c 'import sys,binascii;sys.stdout.buffer.write(binascii.unhexlify(sys.argv[1]))' "$1" >"$2"
}

new_fixtures() {
    rm -rf "$ROOT"; mkdir -p "$CONV" "$BRAIN/conv2"
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
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.png" --destination "$dest"
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
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.jpg" --destination "$dest"
    [[ $code -eq 0 && "$output" == *'type=jpeg'* && "$output" == *'width=3 height=2'* ]]
}
t_source_outside_brain() {
    new_fixtures
    local outside="$ROOT/outside.png"
    cp "$CONV/img.png" "$outside"
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$outside" --destination "$REPO/x.png"
    [[ $code -ne 0 && "$output" == *'[ANTIGRAVITY_ARTIFACT_ERROR]'* ]]
}
t_source_link() {
    new_fixtures
    local link="$CONV/link.png"
    ln -s "$CONV/img.png" "$link" 2>/dev/null
    [[ -L "$link" ]] || return 0
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$link" --destination "$REPO/y.png"
    [[ $code -ne 0 && "$output" == *'[ANTIGRAVITY_ARTIFACT_ERROR]'* ]]
}
t_unrecognized_content() {
    new_fixtures
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/notes.txt" --destination "$REPO/notes.png"
    [[ $code -ne 0 && "$output" == *'unsupported or unrecognized image content'* ]]
}
t_extension_mismatch() {
    new_fixtures
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.jpg" --destination "$REPO/mismatch.png"
    [[ $code -ne 0 && "$output" == *'destination extension does not match image type jpeg'* ]]
}
t_destination_outside_repo() {
    new_fixtures
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.png" --destination "$ROOT/outside2.png"
    [[ $code -ne 0 && "$output" == *'[ANTIGRAVITY_ARTIFACT_ERROR]'* ]]
}
t_destination_exists_without_overwrite() {
    new_fixtures
    cp "$CONV/img.png" "$REPO/exists.png"
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.png" --destination "$REPO/exists.png"
    [[ $code -ne 0 && "$output" == *'already exists'* ]]
}
t_destination_exists_with_overwrite() {
    # Reuses state from the previous case within the same fixture set.
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.png" --destination "$REPO/exists.png" --overwrite
    [[ $code -eq 0 && "$output" == *'[ANTIGRAVITY_ARTIFACT_OK]'* ]]
}
t_destination_protected() {
    new_fixtures
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.png" --destination "$REPO/.env.png"
    [[ $code -ne 0 ]]
}
t_destination_under_git() {
    new_fixtures
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.png" --destination "$REPO/.git/evil.png"
    [[ $code -ne 0 ]]
}
t_missing_parent() {
    new_fixtures
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.png" --destination "$REPO/nope/x.png"
    [[ $code -ne 0 && "$output" == *'parent directory does not exist'* ]]
}
t_truncated_png() {
    new_fixtures
    head -c 20 "$CONV/img.png" >"$CONV/trunc.png"
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/trunc.png" --destination "$REPO/trunc.png"
    [[ $code -ne 0 && "$output" == *'could not read image dimensions'* ]]
}
t_conversation_id_mismatch() {
    new_fixtures
    run_artifact import --repo "$REPO" --conversation-id conv2 --source "$CONV/img.png" --destination "$REPO/mismatch1.png"
    [[ $code -ne 0 && "$output" == *'not inside the conversation directory'* ]]
}
t_conversation_id_invalid() {
    new_fixtures
    run_artifact import --repo "$REPO" --conversation-id '../x' --source "$CONV/img.png" --destination "$REPO/mismatch2.png"
    [[ $code -ne 0 && "$output" == *'Invalid conversation id'* ]]
}
t_source_nested_dir() {
    new_fixtures
    mkdir -p "$CONV/sub"
    cp "$CONV/img.png" "$CONV/sub/nested.png"
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/sub/nested.png" --destination "$REPO/nested.png"
    [[ $code -ne 0 && "$output" == *'not inside the conversation directory'* ]]
}
t_sof2_progressive() {
    new_fixtures
    hex_to_file "$JPEG_PROGRESSIVE_HEX" "$CONV/prog.jpg"
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/prog.jpg" --destination "$REPO/prog.jpg"
    [[ $code -eq 0 && "$output" == *'width=3 height=2'* ]]
}
t_appn_before_sof() {
    new_fixtures
    hex_to_file "$JPEG_APPN_HEX" "$CONV/appn.jpg"
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/appn.jpg" --destination "$REPO/appn.jpg"
    [[ $code -eq 0 && "$output" == *'width=3 height=2'* ]]
}
t_jpeg_bad_segment_length() {
    new_fixtures
    hex_to_file "$JPEG_BADLEN_HEX" "$CONV/badlen.jpg"
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/badlen.jpg" --destination "$REPO/badlen.jpg"
    [[ $code -ne 0 && "$output" == *'could not read image dimensions'* ]]
}
t_jpeg_truncated_before_sof() {
    new_fixtures
    hex_to_file "$JPEG_TRUNCATED_HEX" "$CONV/jtrunc.jpg"
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/jtrunc.jpg" --destination "$REPO/jtrunc.jpg"
    [[ $code -ne 0 && "$output" == *'could not read image dimensions'* ]]
}
t_jpeg_sos_before_sof() {
    new_fixtures
    hex_to_file "$JPEG_SOS_BEFORE_SOF_HEX" "$CONV/sos.jpg"
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/sos.jpg" --destination "$REPO/sos.jpg"
    [[ $code -ne 0 && "$output" == *'could not read image dimensions'* ]]
}
t_png_ihdr_length_wrong() {
    new_fixtures
    hex_to_file "$PNG_WRONG_IHDR_LEN_HEX" "$CONV/wronglen.png"
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/wronglen.png" --destination "$REPO/wronglen.png"
    [[ $code -ne 0 && "$output" == *'could not read image dimensions'* ]]
}
t_png_huge_dimensions() {
    new_fixtures
    hex_to_file "$PNG_HUGE_HEX" "$CONV/huge.png"
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/huge.png" --destination "$REPO/huge.png"
    [[ $code -ne 0 && "$output" == *'image dimensions out of range'* ]]
}
t_png_zero_dimension() {
    new_fixtures
    hex_to_file "$PNG_ZERO_HEX" "$CONV/zero.png"
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/zero.png" --destination "$REPO/zero.png"
    [[ $code -ne 0 && "$output" == *'could not read image dimensions'* ]]
}
t_git_dir_case_variant() {
    new_fixtures
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.png" --destination "$REPO/.GIT/x.png"
    [[ $code -ne 0 ]]
}
t_temp_cleanup_on_failure() {
    new_fixtures
    local before after
    before="$(find "$REPO" -maxdepth 1 -name '.antigravity-artifact.*' 2>/dev/null | wc -l)"
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/notes.txt" --destination "$REPO/shouldfail.png"
    [[ $code -ne 0 ]] || return 1
    after="$(find "$REPO" -maxdepth 1 -name '.antigravity-artifact.*' 2>/dev/null | wc -l)"
    [[ "$before" -eq "$after" ]]
}
t_crlf_path_rejected() {
    new_fixtures
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.png" --destination "$REPO/evil"$'\r'".png"
    [[ $code -ne 0 && "$output" == *'path contains a line break'* ]]
}
t_ads_destination_rejected() {
    new_fixtures
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.png" --destination "$REPO/.git:artifact.png"
    [[ $code -ne 0 && "$output" == *'alternate data stream'* && -d "$REPO/.git" ]]
}
t_reserved_device_name_rejected() {
    new_fixtures
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.png" --destination "$REPO/nul.png"
    [[ $code -ne 0 && "$output" == *'reserved device name'* ]] || return 1
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.png" --destination "$REPO/nul.foo.png"
    [[ $code -ne 0 && "$output" == *'reserved device name'* ]] || return 1
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.png" --destination "$REPO/COM1.x.PNG"
    [[ $code -ne 0 && "$output" == *'reserved device name'* ]]
}
t_overwrite_failure_keeps_original() {
    new_fixtures
    local dest="$REPO/overwrite_ok.png"
    cp "$CONV/img.png" "$dest"
    local original_hash; original_hash="$(sha256_of "$dest")"
    # A mismatched-extension import fails before any write to $dest.
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.jpg" --destination "$dest" --overwrite
    [[ $code -ne 0 ]] || return 1
    [[ "$(sha256_of "$dest")" == "$original_hash" ]] || return 1
    # A successful overwrite does replace the file.
    run_artifact import --repo "$REPO" --conversation-id conv1 --source "$CONV/img.png" --destination "$dest" --overwrite
    [[ $code -eq 0 && "$output" == *'[ANTIGRAVITY_ARTIFACT_OK]'* ]]
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
testcase conversation_id_mismatch_rejected t_conversation_id_mismatch
testcase conversation_id_invalid_rejected t_conversation_id_invalid
testcase source_nested_dir_rejected t_source_nested_dir
testcase sof2_progressive_accepted t_sof2_progressive
testcase appn_before_sof_accepted t_appn_before_sof
testcase jpeg_bad_segment_length_rejected t_jpeg_bad_segment_length
testcase jpeg_truncated_before_sof_rejected t_jpeg_truncated_before_sof
testcase jpeg_sos_before_sof_rejected t_jpeg_sos_before_sof
testcase png_ihdr_length_wrong_rejected t_png_ihdr_length_wrong
testcase png_huge_dimensions_rejected t_png_huge_dimensions
testcase png_zero_dimension_rejected t_png_zero_dimension
testcase git_dir_case_variant_rejected t_git_dir_case_variant
testcase temp_cleanup_on_failure t_temp_cleanup_on_failure
testcase crlf_path_rejected t_crlf_path_rejected
testcase ads_destination_rejected t_ads_destination_rejected
testcase reserved_device_name_rejected t_reserved_device_name_rejected
testcase overwrite_failure_keeps_original t_overwrite_failure_keeps_original

printf 'Passed: %d / %d\n' "$passed" "$total"
[[ "$passed" -eq "$total" ]]
