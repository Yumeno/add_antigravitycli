# 作業記録 2026-07-10 — 3ホストCLI向けinstaller実装

## 目的

Issue [#4](https://github.com/Yumeno/add_antigravitycli/issues/4) の実装。README の手動 `Copy-Item` 手順を、姉妹リポジトリ [`Yumeno/add_codexcli`](https://github.com/Yumeno/add_codexcli) で実績のある retire-then-promote 方式の installer に置き換える。

## 体制

- 計画・仕様策定・検収: Fable 5(メインループ)
- 移植元調査: Sonnet 5 サブエージェント(add_codexcli の installer 4本 + テスト 4本を全文読解)
- 実装: Codex CLI(`codex-implement` フロー、sandbox `workspace-write`)

## 調査で判明した移植上の要点

1. **移植元 ps1 版の未修正欠陥**: rollback 用 `Move-Item` が try/catch で保護されておらず、rollback 自体が例外を投げると診断 `throw` に到達しない(bash 版は issue #29 で修正済み、ps1 版は未対応)。**移植版では rollback を try/catch で包み、成否に関わらず `Failed to promote new skill:` へ到達するよう堅牢化**。
2. **同梱 helper 構成の差**: `list-antigravity-models` に専用スクリプトは無い(wrapper のみ。`agy models` + `--show-model` で代替)。`antigravity-implement` は 7 ファイル同梱。テストの期待値は移植元のファイル名でなく実態に合わせた。
3. **ステージングディレクトリ名**: `.add-codexcli-stage.*` → `.add-antigravitycli-stage.*` へ改名(他プロジェクト名の残骸禁止)。
4. **bash テストの house style**: 移植元は逐次 assert、当リポジトリは名前付きケース + passed/total 集計。後者に合わせて書き直し。
5. **`{{SCRIPTS_ROOT}}` 置換は実装せず**、回帰ガードのテストのみ移植(bundle 方式では最初から不要)。

## 追加ファイル

- installer 6本: `scripts/install-for-{codex,claude-code,antigravity}.{sh,ps1}`
  - Codex CLI: `.agents/skills` → `$HOME/.agents/skills/`
  - Claude Code: `.claude/skills` → `$HOME/.claude/skills/`
  - Antigravity CLI: `.agents/skills` → `$HOME/.gemini/antigravity-cli/skills/`
  - 3段階(事前検証 → 同一ボリューム staging → skill 単位 retire-then-promote)
  - allowlist 5 skill のみ更新、未管理 skill には構造的に触れない
  - `.new`/`.old` 残骸は次回実行で自動吸収
- テスト 6本: `scripts/tests/test-install-{codex,claude-code,antigravity}.{sh,ps1}`
  - ps1 各10ケース(ACL Deny による read-only rollback 検証、BOM 検査含む)
  - bash 各7ケース(chmod 555 + セルフプローブ、効かない環境では SKIP)
  - 日本語を含む一時ディレクトリ名(ps1)、スペースを含むパス(bash)で耐性を同時検証
- README: インストール節を installer 呼び出しへ書き換え。引数上書き・非破壊契約・アンインストール手順(手動削除、bundle 共有設定は残す)を明記

## レビューラウンド(Codex レビュー → 差し戻し修正)

初回実装を Codex にレビューさせたところ Critical 1 + Major 3 が確定し、同一 PR 内で修正した。

1. **【Critical】`.old` の削除順序**: 初回実装は promote 前に `.new` と `.old` を一括削除しており、「前回実行が retire 後にクラッシュして `.old` が旧版の唯一コピー」という状態からの再実行で旧版を失う。移植元と同じ「`.old` の吸収は final が存在する時の retire 直前のみ」に修正。
2. **【Major】staging / retire 失敗時の診断欠落**: `set -e` / `$ErrorActionPreference=Stop` で skill 名入り診断なしに即死していた。`Failed to stage new skill:` / `Failed to retire current skill:` を追加。
3. **【Major】claude-code / antigravity 用 ps1 テストが shim**: `$Installer` を設定するだけで codex 用テストを再実行する 1 行 shim になっており、自分の installer を検証していなかった。完全な独立テストに書き直し。
4. **【Major】read-only ACL テストが SKIP 固定**: `Write-Host "SKIP..."` を PASS として数えており、初回検収時の「read-only ケースも実 PASS」という記録は誤りだった(この作業記録の初版にもその誤記があった)。ACL Deny + セルフプローブ + finally 復元の実テストに書き直し、SKIP は独立カウントに変更。

再発防止として crash recovery ケース(`.old` だけが残る状態からの再実行)を全 6 テストに追加。

### 第2ラウンド(再レビュー → テストのみ修正)

修正後の再レビューで、前回 4 件の修正完了を確認した上で、テスト側に新規 3 件:

1. **P1**: bash read-only テストの期待メッセージが `Failed to promote` 固定で、診断追加後の実際の失敗箇所(staging)と不一致。chmod が強制される Linux では正しい挙動なのに FAIL する回帰 → `Failed to (stage|retire|promote)` 許容に修正。
2. **P1**: crash recovery テストが成功経路のみで Critical の順序退行を検知できない → 「`.old`-only 状態 + Write Deny で installer を失敗させ、`.old` の生存を確認する」ケースを追加(旧実装なら Write Deny 下でも Delete 権で `.old` が先に消えるため検知できる)。
3. **P2**: ACL 復元を `RemoveAccessRule()` から SDDL 丸ごと保存・復元方式へ変更。

## 検証結果(修正後、ホスト側で全件再実行)

| テスト | 結果 |
|---|---|
| test-install-{codex,claude-code,antigravity}.ps1 | 各 12/12 PASS / 0 SKIP(ACL Deny の 2 ケースとも実発火・検証) |
| test-install-{codex,claude-code,antigravity}.sh | 各 7 PASS / 2 SKIP(chmod 非強制の Git Bash では権限系 2 ケースを正直に SKIP) |
| 既存 test-wrapper.{ps1,sh} | 13/13 / 9/9 PASS |
| 既存 test-verify.{ps1,sh} | PASS / 12/12 PASS |
| 既存 test-implement.{ps1,sh} | PASS / 3/3 PASS |
| 既存 test-skill-bundles.ps1 | PASS |

`codex-verify check`: 両ラウンドとも VIOLATION なし。変更ファイルは Codex 報告と一致。

## 教訓

- Codex の「PASS」報告と、テストコードの実体は別物。初回はテストの中身(shim・SKIP 固定)を読まずに PASS 数だけで検収し、誤った記録を残した。**テストが「何を検証して PASS したのか」をコードで確認するまで検収完了としない。**

## 残課題

- `-Uninstall` フラグは未実装(移植元と同じく手動削除手順で対応)
- Linux 実機での bash テストは未実行(Git Bash では全 PASS、read-only ケースは SKIP)→ 姉妹リポジトリ #40 と同種の CI 課題
