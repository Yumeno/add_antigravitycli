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
b64e_test() { printf '%s' "$1" | base64 | tr -d '\r\n'; }
SESSION="$ROOT.session"
case_session_start_requires_clean() {
    new_repo; printf dirty >>"$ROOT/file.txt"; rm -f "$SESSION" "$SESSION.snapshot"
    set +e; output="$(PATH="$SHIM:$PATH" bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" --session "$SESSION" 2>&1)"; code=$?; set -e
    [[ $code -eq 1 && "$output" == *'must be clean'* && ! -f "$SESSION" ]]
}
case_session_round1_and_round2() {
    new_repo; rm -f "$SESSION" "$SESSION.snapshot"
    export FAKE_AGY_WRITE_FILE="$ROOT/new.txt"
    output="$(PATH="$SHIM:$PATH" bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" --timeout 5 --session "$SESSION" 2>/dev/null)"
    code=$?
    [[ $code -eq 0 && "$output" == *'[ANTIGRAVITY_SESSION] round=1 owned=1'* && "$output" == *'--- git status --short ---'* ]] || return 1
    [[ -f "$SESSION" && -f "$SESSION.snapshot" ]] || return 1
    export FAKE_AGY_WRITE_FILE="$ROOT/second.txt"
    output="$(PATH="$SHIM:$PATH" bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" --timeout 5 --session "$SESSION" 2>/dev/null)"
    code=$?
    unset FAKE_AGY_WRITE_FILE
    [[ $code -eq 0 && "$output" == *'[ANTIGRAVITY_SESSION] round=2 owned=2'* && "$output" == *'--- git status --short ---'* ]]
}
case_session_rejects_unrelated_change() {
    printf unrelated >"$ROOT/unrelated.txt"
    rm -f "$SHIM/argv"
    set +e; output="$(PATH="$SHIM:$PATH" bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" --session "$SESSION" 2>&1)"; code=$?; set -e
    rm -f "$ROOT/unrelated.txt"
    [[ $code -eq 1 && "$output" == *'outside this delegation session'* && "$output" == *'unrelated.txt'* && ! -f "$SHIM/argv" ]]
}
case_session_wrapper_failure_still_records() {
    export FAKE_AGY_EXIT=7 FAKE_AGY_WRITE_FILE="$ROOT/failedround.txt"
    set +e; output="$(PATH="$SHIM:$PATH" bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" --session "$SESSION" 2>/dev/null)"; code=$?; set -e
    unset FAKE_AGY_EXIT FAKE_AGY_WRITE_FILE
    [[ $code -eq 7 && "$output" == *'[ANTIGRAVITY_SESSION] round=3 owned=3'* ]]
}
case_session_adopt_changes() {
    printf artifact >"$ROOT/artifact.txt"
    set +e; output="$(PATH="$SHIM:$PATH" bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" --session "$SESSION" 2>&1)"; code=$?; set -e
    [[ $code -eq 1 && "$output" == *'outside this delegation session'* ]] || return 1
    output="$(PATH="$SHIM:$PATH" bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" --session "$SESSION" --adopt-changes 2>/dev/null)"
    code=$?
    [[ $code -eq 0 && "$output" == *'[ANTIGRAVITY_SESSION] adopted=1 paths=artifact.txt'* && "$output" == *'[ANTIGRAVITY_SESSION] round=4 owned=4'* ]] || return 1
    grep -q "$(b64e_test artifact.txt)" "$SESSION"
}
case_adopt_requires_continuation() {
    set +e; output="$(bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" --adopt-changes 2>&1)"; code=$?; set -e
    [[ $code -ne 0 ]] || return 1
    local NEWSESSION="$ROOT.session2"
    rm -f "$NEWSESSION" "$NEWSESSION.snapshot"
    set +e; output="$(bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" --session "$NEWSESSION" --adopt-changes 2>&1)"; code=$?; set -e
    [[ $code -ne 0 && "$output" == *'only valid when continuing a session'* && ! -f "$NEWSESSION" ]]
}
case_session_close() {
    output="$(bash "$IMPLEMENT" --repo "$ROOT" --session "$SESSION" --close-session 2>&1)"; code=$?
    [[ $code -eq 0 && "$output" == *'[ANTIGRAVITY_SESSION] closed'* && ! -f "$SESSION" && ! -f "$SESSION.snapshot" ]] || return 1
    set +e; output2="$(bash "$IMPLEMENT" --repo "$ROOT" --session "$SESSION" --close-session 2>&1)"; code2=$?; set -e
    [[ $code2 -ne 0 ]]
}
case_session_path_inside_repo_rejected() {
    set +e; output="$(bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" --session "$ROOT/s.json" 2>&1)"; code=$?; set -e
    [[ $code -eq 1 ]]
}
case_no_session_unchanged() {
    new_repo
    output="$(PATH="$SHIM:$PATH" bash "$IMPLEMENT" --spec-file "$SPEC" --repo "$ROOT" --timeout 5 2>/dev/null)"
    code=$?
    [[ $code -eq 0 && "$output" != *'[ANTIGRAVITY_SESSION]'* ]]
}
testcase() {
    local name="$1"; shift; total=$((total+1))
    if "$@"; then printf 'PASS: %s\n' "$name"; passed=$((passed+1)); else printf 'FAIL: %s\n' "$name"; fi
}
testcase normal_edit case_success
testcase wrapper_failure_exit_code case_wrapper_failure
testcase dirty_tree_refused case_dirty
testcase protected_file_violation case_protected
testcase session_start_requires_clean case_session_start_requires_clean
testcase session_round1_and_round2 case_session_round1_and_round2
testcase session_rejects_unrelated_change case_session_rejects_unrelated_change
testcase session_wrapper_failure_still_records case_session_wrapper_failure_still_records
testcase session_adopt_changes case_session_adopt_changes
testcase adopt_requires_continuation case_adopt_requires_continuation
testcase session_close case_session_close
testcase session_path_inside_repo_rejected case_session_path_inside_repo_rejected
testcase no_session_unchanged case_no_session_unchanged
printf 'Passed: %d / %d\n' "$passed" "$total"
[[ "$passed" -eq "$total" ]]
