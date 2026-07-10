#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; SOURCE="$HERE/../.agents/skills"
destination_root="${1:-${HOME:?HOME is not set}/.gemini/antigravity-cli}"
names=(ask-antigravity ask-antigravity-with-context antigravity-implement list-antigravity-models set-antigravity-model)
for name in "${names[@]}"; do [[ -d "$SOURCE/$name" && -f "$SOURCE/$name/SKILL.md" ]] || { printf 'Missing source skill: %s\n' "$name" >&2; exit 1; }; done
mkdir -p -- "$destination_root"; stage="$(mktemp -d "$destination_root/.add-antigravitycli-stage.XXXXXX")"; trap 'rm -rf -- "$stage"' EXIT
mkdir -p -- "$stage/skills" "$destination_root/skills"
for name in "${names[@]}"; do cp -R -- "$SOURCE/$name" "$stage/skills/$name"; done
for name in "${names[@]}"; do
 final_dest="$destination_root/skills/$name"; new_dest="$final_dest.new"; old_dest="$final_dest.old"; rm -rf -- "$new_dest"
 if ! mv -- "$stage/skills/$name" "$new_dest"; then printf 'Failed to stage new skill: %s\n' "$name" >&2; exit 1; fi
 if [[ -e "$final_dest" ]]; then
  rm -rf -- "$old_dest"
  if ! mv -- "$final_dest" "$old_dest"; then printf 'Failed to retire current skill: %s\n' "$name" >&2; exit 1; fi
 fi
 if ! mv -- "$new_dest" "$final_dest"; then if [[ -e "$old_dest" ]]; then if ! mv -- "$old_dest" "$final_dest" 2>/dev/null; then printf 'Rollback also failed for %s (leftover: %s)\n' "$name" "$old_dest" >&2; fi; fi; printf 'Failed to promote new skill: %s\n' "$name" >&2; exit 1; fi
 rm -rf -- "$old_dest"
done
printf 'Antigravity CLI用Skillをインストールしました。\n'
