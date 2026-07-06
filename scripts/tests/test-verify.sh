#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VERIFY="$HERE/../antigravity-verify.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agy_verify_test.XXXXXX")"
SNAP="$ROOT.snapshot"
trap 'rm -rf "$ROOT"; rm -f "$SNAP"' EXIT
passed=0; total=0
new_repo() {
    rm -rf "$ROOT"; rm -f "$SNAP"; mkdir "$ROOT"
    git -C "$ROOT" init -q
    git -C "$ROOT" config user.name Test
    git -C "$ROOT" config user.email test@example.com
    printf 'base\n' >"$ROOT/file.txt"; git -C "$ROOT" add file.txt; git -C "$ROOT" commit -qm initial
}
snapshot() { bash "$VERIFY" snapshot --repo "$ROOT" --out "$SNAP" >/dev/null; }
run_check() { set +e; output="$(bash "$VERIFY" check --repo "$ROOT" --snapshot "$SNAP" 2>&1)"; code=$?; set -e; }
testcase() { name="$1"; shift; total=$((total+1)); if "$@"; then printf 'PASS: %s\n' "$name"; passed=$((passed+1)); else printf 'FAIL: %s\n' "$name"; fi; }
t_clean() { new_repo; snapshot; run_check; [[ $code -eq 0 ]]; }
t_dirty_refused() {
    new_repo; printf x >>"$ROOT/file.txt"; set +e; output="$(bash "$VERIFY" snapshot --repo "$ROOT" --out "$SNAP" 2>&1)"; code=$?; set -e
    [[ $code -eq 1 && "$output" == *'must be clean'* ]]
}
t_edit_reported() { new_repo; snapshot; printf x >>"$ROOT/file.txt"; run_check; [[ $code -eq 0 && "$output" == *'file.txt'* ]]; }
t_head() { new_repo; snapshot; printf x >>"$ROOT/file.txt"; git -C "$ROOT" commit -qam next; run_check; [[ $code -eq 3 && "$output" == *'HEAD changed'* ]]; }
t_branch() { new_repo; snapshot; git -C "$ROOT" checkout -qb other; run_check; [[ $code -eq 3 && "$output" == *'branch changed'* ]]; }
t_env() { new_repo; printf a >"$ROOT/.env"; git -C "$ROOT" add -f .env; git -C "$ROOT" commit -qm env; snapshot; printf b >"$ROOT/.env"; run_check; [[ $code -eq 3 && "$output" == *'protected file modified: .env'* ]]; }
t_nested_env() { new_repo; snapshot; mkdir "$ROOT/sub"; printf a >"$ROOT/sub/.env"; run_check; [[ $code -eq 3 && "$output" == *'sub/.env'* ]]; }
t_config() { new_repo; snapshot; git -C "$ROOT" config x.y z; run_check; [[ $code -eq 3 && "$output" == *'.git/config'* ]]; }
t_ref() { new_repo; snapshot; mkdir -p "$ROOT/.git/refs/tags"; git -C "$ROOT" rev-parse HEAD >"$ROOT/.git/refs/tags/foo"; run_check; [[ $code -eq 3 && "$output" == *'.git/refs/tags/foo'* ]]; }
t_gitmodules() { new_repo; snapshot; printf '[submodule "x"]\n' >"$ROOT/.gitmodules"; run_check; [[ $code -eq 3 && "$output" == *'.gitmodules'* ]]; }
t_symlink_target() {
    new_repo; printf one >"$ROOT/secret"; ln -s secret "$ROOT/.env" 2>/dev/null || return 0
    [[ -L "$ROOT/.env" ]] || return 0
    git -C "$ROOT" add -f .env secret; git -C "$ROOT" commit -qm symlink; snapshot
    printf two >"$ROOT/secret"; run_check
    [[ $code -eq 3 && "$output" == *'.env'* ]]
}
t_inside() {
    new_repo; set +e; output="$(bash "$VERIFY" snapshot --repo "$ROOT" --out "$ROOT/snap" 2>&1)"; code=$?; set -e
    [[ $code -eq 1 && "$output" == *'outside the repository'* ]]
}
testcase clean t_clean
testcase dirty_snapshot_refused t_dirty_refused
testcase ordinary_edit_reported t_edit_reported
testcase head_violation t_head
testcase branch_violation t_branch
testcase env_violation t_env
testcase nested_env_violation t_nested_env
testcase git_config_violation t_config
testcase git_ref_violation t_ref
testcase gitmodules_violation t_gitmodules
testcase symlink_target_violation t_symlink_target
testcase snapshot_outside_repo t_inside
printf 'Passed: %d / %d\n' "$passed" "$total"
[[ "$passed" -eq "$total" ]]
