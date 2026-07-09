#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; INSTALL="$HERE/../install-for-claude-code.sh"; ROOT="$(mktemp -d "${TMPDIR:-/tmp}/add_antigravitycli_install.XXXXXX")"; DEST="$ROOT/install root"; trap 'chmod -R u+w "$ROOT" 2>/dev/null || true;rm -rf "$ROOT"' EXIT
names=(ask-antigravity ask-antigravity-with-context antigravity-implement list-antigravity-models set-antigravity-model);passed=0;total=0
check(){ local n="$1";shift;total=$((total+1));if "$@";then printf 'PASS: %s\n' "$n";passed=$((passed+1));else printf 'FAIL: %s\n' "$n";fi; }
run(){ bash "$INSTALL" "$DEST" >/dev/null; }
t_install(){ run&&for n in "${names[@]}";do [[ -f "$DEST/skills/$n/SKILL.md" && -d "$DEST/skills/$n/scripts" ]]||return 1;done; }
t_placeholders(){ ! grep -R -F '{{SCRIPTS_ROOT}}' "$DEST/skills"/*/SKILL.md; }
t_helpers(){ for n in "${names[@]}";do [[ -f "$DEST/skills/$n/scripts/antigravity-wrapper.ps1" && -f "$DEST/skills/$n/scripts/antigravity-wrapper.sh" ]]||return 1;done;for f in antigravity-implement.ps1 antigravity-implement.sh antigravity-verify.ps1 antigravity-verify.sh antigravity-implement-safety.txt;do [[ -f "$DEST/skills/antigravity-implement/scripts/$f" ]]||return 1;done; }
t_preserve(){ mkdir -p "$DEST/skills/unrelated" "$DEST/skills/ask-antigravity";:>"$DEST/skills/unrelated/keep.txt";:>"$DEST/skills/ask-antigravity/stale.txt";run&&[[ -f "$DEST/skills/unrelated/keep.txt" && ! -e "$DEST/skills/ask-antigravity/stale.txt" ]]; }
t_idempotent(){ run&&mkdir -p "$DEST/skills/ask-antigravity.new"&&:>"$DEST/skills/ask-antigravity.new/leftover.txt"&&run&&[[ ! -e "$DEST/skills/ask-antigravity.new" ]]; }
t_readonly(){ mkdir -p "$DEST/readonly/skills/ask-antigravity";:>"$DEST/readonly/skills/ask-antigravity/previous.txt";chmod 555 "$DEST/readonly/skills";if mkdir "$DEST/readonly/skills/.permission-probe" 2>/dev/null;then rmdir "$DEST/readonly/skills/.permission-probe";chmod 755 "$DEST/readonly/skills";printf 'SKIP: read-only permission enforcement unavailable\n';return 0;fi;set +e;out="$(bash "$INSTALL" "$DEST/readonly" 2>&1)";code=$?;set -e;chmod 755 "$DEST/readonly/skills";[[ $code -ne 0 && -f "$DEST/readonly/skills/ask-antigravity/previous.txt" && "$out" == *'Failed to promote new skill:'* ]]; }
t_clean(){ ! find "$DEST" -name '*.new' -o -name '*.old' -o -name '.add-antigravitycli-stage-*'|grep -q .; }
check installs_skills t_install;check no_legacy_placeholders t_placeholders;check bundled_helpers t_helpers;check preserves_unrelated_and_replaces_stale t_preserve;check idempotent_and_absorbs_new t_idempotent;check readonly_preserves_prior_content t_readonly;check cleans_artifacts t_clean;printf 'Passed: %d / %d\n' "$passed" "$total";[[ $passed -eq $total ]]
