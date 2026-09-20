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
- Bash 版の JSON 解析は `jq` → `python3` → `python` → `node` の順で自動選択。各候補は「実際に `{"a":1}` を解析できるか」で probe する(Windows の `python3` は PATH 上にあっても動かない Store スタブのことがある。この端末で実在)。いずれも無ければ従来の text 出力に戻り、stderr に警告(ランタイム依存を増やさない)。`ANTIGRAVITY_WRAPPER_JSON_TOOL=none` でテスト用に強制
- `status` が `TIMEOUT` なら wrapper 自身のタイムアウトと同じ exit 2
- 空応答・解析不能・拒否で空の失敗時は、agy の stderr 末尾 5 行(各 400 文字まで)を `agy stderr (tail):` として sentinel の後に転記(issue #14 の本題)
- `denied_actions` は配列・単一 object・null・欠落を正規化し、それ以外の型は `unexpected denied_actions type` で失敗。表示は初出順で重複排除
- `response` はバイト列をそのまま出力(末尾改行・CRLF を保持)。拒否行を続ける場合だけ改行を補う

## 変更内容

- `scripts/antigravity-wrapper.{ps1,sh}`: 上記
- `scripts/tests/fake-agy.{ps1,sh}`: argv に `--output-format json` があれば JSON envelope で応答。`FAKE_DENIED` / `FAKE_AGY_DENIED`(`action:display_name,...`)、`FAKE_STATUS` / `FAKE_AGY_STATUS`、`FAKE_RAW` / `FAKE_AGY_RAW`(生文字列)、`FAKE_RAW_EMPTY` / `FAKE_AGY_RAW_EMPTY`(完全な空)を追加
- `scripts/tests/test-wrapper.{ps1,sh}`: 期待 argv に `--output-format json` を追加。拒否 + 空応答、拒否 + 応答あり(本文が拒否行より前)、非 SUCCESS、解析不能、完全な空、(sh のみ)parser 無しフォールバック、の各ケースを追加
- README: 安全設計とトラブルシューティングに拒否検知の説明を追加
- `ask-antigravity` / `ask-antigravity-with-context` の SKILL.md(両コピー): `[ANTIGRAVITY_DENIED_ACTIONS]` の意味と、空応答で失敗したら「tool を使わず答える」を指示に加えて再実行する手順を追加
- 全 skill 同梱 bundle を sync tool で再配布

## レビュー Round 1 と反映

- Codex gpt-5.6-terra(コード): Major 3(PS 5.1 `ConvertFrom-Json` の約 2MB 上限、Bash 版が `denied_actions` 単一 object で解析失敗、PS 版が空応答時に stderr のヒントを出さない)、Minor 4(Bash の末尾改行欠落、stdout/stderr 分離テストなし、異常系・型・サイズのテスト不足、fake の JSON エスケープ不完全)、Nit 1(trap 上書き)
  - 2MB 上限は**この端末の PS 5.1(5.1.26100)では再現せず**(1,200 万文字の `response` も解析成功)。ただし `JavaScriptSerializer`(`MaxJsonLength = int.MaxValue`)への切替と 3MB 応答の回帰テストは無害なので採用
  - その他はすべて反映
- agy(仕様): Minor 2(Python/Node パーサーの BOM、重複排除)、Nit 1(Node の undefined)。`status` は `SUCCESS` の他に `ERROR` / `TIMEOUT` / `MAX_TURNS`(UNSURE)/ `CANCELLED` 等があり、`denied_actions` は非空 `response` と共存し得る・同一 action が複数回入り得る、との回答。すべて反映
- 修正中に Sonnet が発見した実バグ: この端末の jq 1.8.1 は stdout が text mode のとき文字列中の `
` を `
` に書き換える(複数行 `response` が壊れる)。jq 経路は `@base64` で取り出して `base64 -d` で復号する方式に変更し、CRLF・末尾複数改行を含む往復でバイト一致を確認
- fake-agy.ps1 は `[Console]::OutputEncoding` を UTF-8 にしないと cp932 で JSON を書いて日本語が壊れる(大サイズ日本語テストで顕在化)。テスト側の修正

## レビュー Round 2 と反映

- agy(仕様): NO MAJOR FINDINGS / CONVERGED
- Codex gpt-5.6-terra(コード): Major 1(PS 版の成功時出力が `TrimEnd` + `Write-Output` で末尾改行・CRLF を保持せず、Bash 版と契約が不一致)→ `[Console]::Out.Write` でバイト列をそのまま出力し、拒否行を続けるときだけ LF を補う形に修正。PS 側の CRLF テストも stdout をバイトで読んで入力と完全一致を検証するよう変更。従来の PS 版(`$stdout.TrimEnd()`)からの挙動変更: 末尾の空白・改行が保持される

## 検証

- unit: test-wrapper.ps1 27/27、test-wrapper.sh 24/24、test-implement.ps1 OK、test-implement.sh 4/4、test-verify.ps1 OK、test-skill-bundles.ps1 OK、sync -Check 同期済み
- 実 agy 1.2.7 E2E(両 wrapper、成功・拒否の各 2 件以上): 成功時は本文のみ(日本語・空行含む)、`git status` を実行させる拒否ケースは `[ANTIGRAVITY_DENIED_ACTIONS] escalate_admin (Bash)` と stderr tail 付きで exit 1。空行を含む返答を求めた際に agent が command ツールを使おうとして `command (RunCommand)` として検知された例もあり(display_name はツールにより異なる)
