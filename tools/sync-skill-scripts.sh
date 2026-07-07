#!/usr/bin/env bash
set -euo pipefail

check=0
if [[ "${1:-}" == "--check" ]]; then
    check=1
elif [[ $# -gt 0 ]]; then
    printf 'usage: %s [--check]\n' "$0" >&2
    exit 2
fi

tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$tool_dir/.." && pwd -P)"
source_dir="$repo_root/scripts"
skill_roots=("$repo_root/.agents/skills" "$repo_root/.claude/skills")
common_scripts=(antigravity-wrapper.ps1 antigravity-wrapper.sh)
implement_scripts=(
    antigravity-wrapper.ps1
    antigravity-wrapper.sh
    antigravity-implement.ps1
    antigravity-implement.sh
    antigravity-verify.ps1
    antigravity-verify.sh
    antigravity-implement-safety.txt
)

expected_scripts() {
    if [[ "$1" == "antigravity-implement" ]]; then
        printf '%s\n' "${implement_scripts[@]}"
    else
        printf '%s\n' "${common_scripts[@]}"
    fi
}

mismatches=0
for skill_root in "${skill_roots[@]}"; do
    [[ -d "$skill_root" ]] || continue
    for skill in "$skill_root"/*; do
        [[ -d "$skill" ]] || continue
        skill_name="$(basename "$skill")"
        target_dir="$skill/scripts"
        mapfile -t expected < <(expected_scripts "$skill_name")
        if [[ "$check" -eq 1 ]]; then
            if [[ ! -d "$target_dir" ]]; then
                printf 'missing scripts directory: %s\n' "$skill" >&2
                mismatches=1
                continue
            fi
            for name in "${expected[@]}"; do
                if ! cmp -s "$source_dir/$name" "$target_dir/$name"; then
                    printf 'out of sync: %s/%s\n' "$target_dir" "$name" >&2
                    mismatches=1
                fi
            done
            for existing in "$target_dir"/*; do
                [[ -f "$existing" ]] || continue
                existing_name="$(basename "$existing")"
                found=0
                for name in "${expected[@]}"; do
                    [[ "$existing_name" == "$name" ]] && found=1
                done
                if [[ "$found" -eq 0 ]]; then
                    printf 'unexpected bundled script: %s\n' "$existing" >&2
                    mismatches=1
                fi
            done
        else
            mkdir -p "$target_dir"
            find "$target_dir" -maxdepth 1 -type f -delete
            for name in "${expected[@]}"; do
                cp "$source_dir/$name" "$target_dir/$name"
            done
        fi
    done
done

if [[ "$check" -eq 1 ]]; then
    [[ "$mismatches" -eq 0 ]] || exit 1
    printf 'skill bundled scripts are in sync\n'
fi
