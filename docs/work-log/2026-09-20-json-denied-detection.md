# 作業記録 2026-09-20 — wrapper を `--output-format json` 化し、headless の権限拒否を可視化

## 目的

Issue [#14](https://github.com/Yumeno/add_antigravitycli/issues/14) の対応。agy が headless で tool 権限を自動拒否すると stdout 空・exit 0 で終わり、wrapper は `agy returned empty output` としか報告できず原因が分からなかった(#12 の作業で切り分けに時間を要した)。#17 の方針(sandbox 維持 + host 駆動ループ)の前提として、拒否を機械的に検知できるようにする。

## 体制

- 設計・仕様書・レビュー・検証: Fable 5.1(メインループ)
- 実装(wrapper 両版、fake agy、テスト): Sonnet サブエージェント
- 文書(README、ask 系 SKILL.md): Fable 5.1

## 一次情報(agy 1.2.7 実測)

- `--output-format json` は stdout に JSON 1 オブジェクト: `status`(`SUCCESS`)、`response`(本文)、`denied_actions`(拒否時のみ、`[{action, display_name}]`)、`conversation_id`、`usage` 等
- 拒否時: `"response":""`、`"status":"SUCCESS"`、`"denied_actions":[{"action":"escalate_admin","display_name":"Bash"}]`。CLI としては正常終了なので、`status` だけでは判定できない
- `stream-json` は `init` / `step_update`(text_delta)/ `result` のイベント行。今回は採用せず(#16 のストリーミング対応で検討)
- Bash 版 wrapper も元々 stdout をファイルに全量取ってから出力していたので、JSON 化によるストリーミングの後退はない

## 設計

- 両 wrapper で `--output-format json` を常時付加し、`response` を従来どおり本文として出力する(呼び出し側の契約は不変)
- `denied_actions` は常に可視化: stderr に `ANTIGRAVITY: denied_actions=...`、stdout 末尾に `[ANTIGRAVITY_DENIED_ACTIONS] <action (display_name), ...>`
- `response` 空 + 拒否あり → `[ANTIGRAVITY_WRAPPER_ERROR] agy produced no response because tool permissions were denied in headless mode.` で exit 1
- `response` 空 + 拒否なし → 従来の `agy returned empty output.`
- `status` が `SUCCESS` 以外 → `agy reported status <status>.` で exit 1(拒否一覧と本文があれば併記)
- JSON として解析できない → `agy returned unparseable output.` + 先頭 500 文字で exit 1
- `response` あり + 拒否あり → 本文を出し末尾に拒否行、exit 0(依頼が完了しているかは host が判断。Codex の助言「CLI の正常終了と依頼の完了を分ける」に従う)
- Bash 版の JSON 解析は `jq` → `python3` → `python` → `node` の順で自動選択。いずれも無ければ従来の text 出力に戻り、stderr に警告(ランタイム依存を増やさない)。`ANTIGRAVITY_WRAPPER_JSON_TOOL=none` でテスト用に強制

## 変更内容

- `scripts/antigravity-wrapper.{ps1,sh}`: 上記
- `scripts/tests/fake-agy.{ps1,sh}`: argv に `--output-format json` があれば JSON envelope で応答。`FAKE_DENIED` / `FAKE_AGY_DENIED`(`action:display_name,...`)、`FAKE_STATUS` / `FAKE_AGY_STATUS`、`FAKE_RAW` / `FAKE_AGY_RAW`(生文字列)、`FAKE_RAW_EMPTY` / `FAKE_AGY_RAW_EMPTY`(完全な空)を追加
- `scripts/tests/test-wrapper.{ps1,sh}`: 期待 argv に `--output-format json` を追加。拒否 + 空応答、拒否 + 応答あり(本文が拒否行より前)、非 SUCCESS、解析不能、完全な空、(sh のみ)parser 無しフォールバック、の各ケースを追加
- README: 安全設計とトラブルシューティングに拒否検知の説明を追加
- `ask-antigravity` / `ask-antigravity-with-context` の SKILL.md(両コピー): `[ANTIGRAVITY_DENIED_ACTIONS]` の意味と、空応答で失敗したら「tool を使わず答える」を指示に加えて再実行する手順を追加
- 全 skill 同梱 bundle を sync tool で再配布

## 検証

- unit: test-wrapper.ps1 18/18、test-wrapper.sh 15/15、test-implement.ps1 OK、test-implement.sh 4/4、test-verify.ps1 OK、test-skill-bundles.ps1 OK、sync -Check 同期済み
- 実 agy 1.2.7 E2E(両 wrapper、各 2 件): 成功時は本文のみ(日本語含む)、`git status` を実行させる拒否ケースは `[ANTIGRAVITY_DENIED_ACTIONS] escalate_admin (Bash)` 付きで exit 1
