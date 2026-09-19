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
    output="$(PATH="$SHIM:$PATH" bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" --timeout 5 2>/dev/null)"
    code=$?; unset FAKE_AGY_WRITE_FILE
    [[ $code -eq 0 && -f "$ROOT/new.txt" && "$(cat "$SHIM/stdin")" == *'READMEを追加する'* ]] || return 1
    # model response must precede the verification log
    [[ "$output" == *'--- git status --short ---'* && "${output%%--- git status --short ---*}" == *implemented* ]]
}
case_dirty() {
    new_repo; printf dirty >>"$ROOT/file.txt"
    set +e; output="$(PATH="$SHIM:$PATH" bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" 2>&1)"; code=$?; set -e
    [[ $code -eq 1 && "$output" == *'must be clean'* ]]
}
case_wrapper_failure() {
    new_repo; export FAKE_AGY_EXIT=7 FAKE_AGY_STDERR='fake failure'
    set +e; output="$(PATH="$SHIM:$PATH" bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_EXIT FAKE_AGY_STDERR
    # exit code preserved, verify log still emitted, sentinel appended last
    [[ $code -eq 7 && "$output" == *'--- git status --short ---'* && "${output##*--- git status --short ---}" == *'[ANTIGRAVITY_IMPLEMENT_ERROR] Antigravity run failed with exit code 7'* ]]
}
case_protected() {
    new_repo; export FAKE_AGY_WRITE_FILE="$ROOT/.env"
    set +e; output="$(PATH="$SHIM:$PATH" bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" 2>&1)"; code=$?; set -e
    unset FAKE_AGY_WRITE_FILE
    [[ $code -eq 3 && "$output" == *'[ANTIGRAVITY_VERIFY_VIOLATION]'* ]]
}
testcase() {
    local name="$1"; shift; total=$((total+1))
    if "$@"; then printf 'PASS: %s\n' "$name"; passed=$((passed+1)); else printf 'FAIL: %s\n' "$name"; fi
}
testcase normal_edit case_success
testcase wrapper_failure_exit_code case_wrapper_failure
testcase dirty_tree_refused case_dirty
testcase protected_file_violation case_protected
printf 'Passed: %d / %d\n' "$passed" "$total"
[[ "$passed" -eq "$total" ]]
