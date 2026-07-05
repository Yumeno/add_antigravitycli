#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
IMPLEMENT="$HERE/../antigravity-implement.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agy_implement_test.XXXXXX")"
SHIM="$(mktemp -d "${TMPDIR:-/tmp}/agy_implement_shim.XXXXXX")"
SPEC="$ROOT.spec"
trap 'rm -rf "$ROOT" "$SHIM"; rm -f "$SPEC"' EXIT
cp "$HERE/fake-agy.sh" "$SHIM/agy"; chmod +x "$SHIM/agy"
export FAKE_AGY_ARGV="$SHIM/argv" FAKE_AGY_STDIN="$SHIM/stdin" FAKE_AGY_OUTPUT='implemented'
printf 'READMEを追加する\n' >"$SPEC"
passed=0; total=0
new_repo() {
    rm -rf "$ROOT"; mkdir "$ROOT"; git -C "$ROOT" init -q
    git -C "$ROOT" config user.name Test; git -C "$ROOT" config user.email test@example.com
    printf base >"$ROOT/file.txt"; git -C "$ROOT" add file.txt; git -C "$ROOT" commit -qm initial
}
case_success() {
    new_repo; export FAKE_AGY_WRITE_FILE="$ROOT/new.txt"
    PATH="$SHIM:$PATH" bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" --timeout 5 >/dev/null 2>&1
    code=$?; unset FAKE_AGY_WRITE_FILE
    [[ $code -eq 0 && -f "$ROOT/new.txt" && "$(cat "$SHIM/stdin")" == *'READMEを追加する'* ]]
}
case_dirty() {
    new_repo; printf dirty >>"$ROOT/file.txt"
    set +e; output="$(PATH="$SHIM:$PATH" bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" 2>&1)"; code=$?; set -e
    [[ $code -eq 1 && "$output" == *'must be clean'* ]]
}
case_protected() {
    new_repo; export FAKE_AGY_WRITE_FILE="$ROOT/.env"
    set +e; output="$(PATH="$SHIM:$PATH" bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" 2>&1)"; code=$?; set -e
    unset FAKE_AGY_WRITE_FILE
    [[ $code -eq 2 && "$output" == *'[ANTIGRAVITY_VERIFY_VIOLATION]'* ]]
}
testcase() {
    local name="$1"; shift; total=$((total+1))
    if "$@"; then printf 'PASS: %s\n' "$name"; passed=$((passed+1)); else printf 'FAIL: %s\n' "$name"; fi
}
testcase normal_edit case_success
testcase dirty_tree_refused case_dirty
testcase protected_file_violation case_protected
printf 'Passed: %d / %d\n' "$passed" "$total"
[[ "$passed" -eq "$total" ]]
