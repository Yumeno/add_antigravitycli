# 作業記録 2026-09-20 — wrapper を stream-json 化して実行中の進捗を可視化

## 目的

Issue [#16](https://github.com/Yumeno/add_antigravitycli/issues/16)。PowerShell 版 wrapper は agy の stdout を完了まで全量バッファし、#14 で両 wrapper を `--output-format json` にしたことで「完了まで何も出ない」構造が固定された。長い implement 実行中にフリーズと区別がつかないため、`stream-json` に切り替えて本文を逐次出力し、tool の開始・完了を stderr に流す。

## 一次情報(agy 1.2.7 実測、`--output-format stream-json`)

1 行 1 JSON:
- `{"event":"init","conversation_id":"<id>","init":{...}}` が先頭
- `{"event":"step_update","step_update":{"step_index":N,"state":"ACTIVE"|"DONE","step_type":"user_input"|"agent_response"|"tool",...}}`。`agent_response` は `text_delta`(本文の断片。最後の DONE に末尾の改行が乗ることが多い)、`tool` は `tool_name` と `tool_info.parameters`、DONE 時に `tool_info.error.{type,message}`(拒否されたコマンドは `TOOL_ERROR` / `context canceled`)
- `{"event":"result","result":{"status","response","denied_actions",...}}` が末尾。`response` は全 `text_delta` の連結と一致

## 体制

- 設計・仕様書・文書・レビュー指揮・検証・選択順と Node 終了処理の修正: Fable 5.1(メインループ)
- 実装(wrapper 両版、fake agy、テスト): Sonnet サブエージェント

## 設計

- 両 wrapper で `--output-format stream-json`。`text_delta` を受け取り次第 stdout にバイト列のまま書き出し、`result` を受けてから従来どおりの判定(status / 空応答 / denied_actions / unparseable)。本文は既に流しているので `result.response` は再出力しない(連結と不一致なら stderr に warning)
- stderr の進捗: `ANTIGRAVITY: conversation_id=<id>`(init)、`ANTIGRAVITY: tool=<name> state=ACTIVE|DONE[ error=<type>: <message>]`
- `result` が来ずに agy が終了した場合は `agy stream ended without a result event.` で exit 1
- PowerShell: `ReadLineAsync()` + `Task.Wait(残り時間)` で行を読み、`-Timeout` の kill(exit 2)を維持
- Bash: 行ごとの解析は python / node の常駐 1 プロセス(パイプ、agy の exit は PIPESTATUS)。tool の選択順を `python3 → python → node → jq` に変更(逐次出力できるものを優先。jq しか無い環境は従来の buffered `json` モードに戻して stderr に注意、parser 無しは従来の text)。Node は `process.exit()` ではなく `exitCode` で終了し stdout の切り捨てを避ける
- 契約(sentinel、exit code、stdout の最終バイト列、stderr 診断)は #14 のまま

## 変更内容

- `scripts/antigravity-wrapper.{ps1,sh}`、`scripts/tests/fake-agy.{ps1,sh}`(stream-json イベント列、`FAKE_STREAM_DELAY` / `FAKE_TOOL_EVENT` / `FAKE_NO_RESULT`)、`scripts/tests/test-wrapper.{ps1,sh}`(liveness、tool 進捗、result 欠落、バイト一致、拒否行の改行、jq fallback)
- README: ストリーミングと tool 選択の記述

## 実装中に見つけた問題(メインループ側で修正)

- Sonnet の実装は Bash の tool 選択順が `jq` 優先のままで、この端末では既定で buffered モードになりストリーミングされなかった。選択順を `python3 → python → node → jq` に変更したところ、失敗系 5 ケース(非ゼロ終了、タイムアウト、解析不能、完全な空、stderr tail)がストリーミング経路で落ちた。原因はパイプライン全体をサブシェル `( agy | parser )` で包んでいたため `PIPESTATUS[0]` が agy ではなく parser の終了コードになっていたこと。左辺だけをサブシェルにして修正。jq 既定で通っていたため Sonnet のテストでは見えていなかった
- Node parser の `process.exit()` を `process.exitCode` に変更(パイプ先で stdout が切り捨てられる既知の問題の回避)
- Sonnet が「自動で入った変更」と誤認して私の work-log と README の編集を削除していたため復元

## 検証

- unit: test-wrapper.sh 30/30 を python 既定・node 強制・jq 強制(buffered fallback)の 3 経路で実行、test-wrapper.ps1 32/32、test-implement 両版(26/26、OK)、test-artifact 両版 30/30、test-skill-bundles OK、sync -Check 同期済み
- 実 agy 1.2.7 E2E(両版): README を読ませる依頼で `ANTIGRAVITY: tool=view_file state=ACTIVE/DONE` が先に stderr に出てから本文が届く。`git status` を打たせる依頼は `tool=run_command ... error=TOOL_ERROR: context canceled` の後に従来どおり拒否 sentinel で exit 1(node 経路でも同じ)。3 秒タイムアウトは両版 exit 2
