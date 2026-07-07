# 作業記録 2026-07-07 — Skill同梱helper化

## 目的

Issue #3「Codex/Claude Codeへのインストールで Skill/scripts パスが整合しない」への対応として、Skillは仕様どおり `.agents/skills` に置きつつ、helper scriptsを各Skill配下へ同梱する構成へ変更した。

## 設計判断

- Codex向けSkill配置は `.agents/skills` / `$HOME/.agents/skills` を維持する。
- Claude Code向けSkill配置は `.claude/skills` を維持する。
- helper scriptsは `$HOME/scripts` や `$HOME/.agents/scripts` へ置かず、各Skill配下の `scripts/` に同梱する。
- runtime/user configはSkillごとに分けない。`set-antigravity-model` の保存値を他Skillも読む必要があるため、bundle共有設定として `$HOME/.agents/add_antigravitycli/antigravity-wrapper.conf` を既定にした。
- `ANTIGRAVITY_WRAPPER_CONFIG` は引き続き最優先の明示config pathとして扱う。
- repo直下 `scripts/` は開発用正本として残し、配布コピーは同期toolで生成・検証する。

## 変更内容

- `scripts/antigravity-wrapper.ps1`
  - 既定config pathを `$PSScriptRoot/antigravity-wrapper.conf` から `$USERPROFILE\.agents\add_antigravitycli\antigravity-wrapper.conf` へ変更。
  - `-SetModel` 時にconfigディレクトリを自動作成。
- `scripts/antigravity-wrapper.sh`
  - 既定config pathを `$HOME/.agents/add_antigravitycli/antigravity-wrapper.conf` へ変更。
  - `--set-model` 時にconfigディレクトリを自動作成。
- `.agents/skills/*/scripts/` と `.claude/skills/*/scripts/`
  - 各Skillが必要とするhelperを同梱。
  - `antigravity-implement` は wrapper / implement / verify / safety text を同梱。
  - その他のSkillは wrapperのみ同梱。
- 各 `SKILL.md`
  - `../../../scripts` 解決ではなく、自身のディレクトリ直下 `scripts/` を使うよう記述変更。
- `tools/sync-skill-scripts.ps1` / `.sh`
  - repo直下 `scripts/` から各Skill配下へ配布コピーを同期。
  - `--check` / `-Check` で同梱helperと正本のbyte一致を検証。
- `scripts/tests/test-skill-bundles.ps1`
  - 同梱helperの同期漏れを検出するテストを追加。
- README
  - `$USERPROFILE\scripts` / `$USERPROFILE\.gemini\scripts` へのコピー手順を削除。
  - helper同梱とbundle共有configの役割分担を明記。

## 検証

- `powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync-skill-scripts.ps1 -Check`
  - 成功。
- 全PowerShellファイルのUTF-8 BOM確認
  - 成功。
- `Get-ChildItem scripts\tests\test-*.ps1 | ForEach-Object { powershell -ExecutionPolicy Bypass -NoProfile -File $_.FullName }`
  - `test-implement.ps1`: OK
  - `test-skill-bundles.ps1`: OK
  - `test-verify.ps1`: OK
  - `test-wrapper.ps1`: 13/13 PASS
- `.agents/skills/*` の `quick_validate.py`
  - 5/5 valid。

## 補足

Claude Code向け `.claude/skills/*/SKILL.md` は `disable-model-invocation` などClaude固有frontmatterを保持しているため、Codex用 `quick_validate.py` の対象外とした。

