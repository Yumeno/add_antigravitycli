# 作業記録 2026-09-20 — wrapper を stream-json 化して実行中の進捗を可視化

## 目的

Issue [#16](https://github.com/Yumeno/add_antigravitycli/issues/16)。PowerShell 版 wrapper は agy の stdout を完了まで全量バッファし、#14 で両 wrapper を `--output-format json` にしたことで「完了まで何も出ない」構造が固定された。長い implement 実行中にフリーズと区別がつかないため、`stream-json` に切り替えて本文を逐次出力し、tool の開始・完了を stderr に流す。

## 一次情報(agy 1.2.7 実測、`--output-format stream-json`)

1 行 1 JSON:
- `{"event":"init","conversation_id":"<id>","init":{...}}` が先頭
- `{"event":"step_update","step_update":{"step_index":N,"state":"ACTIVE"|"DONE","step_type":"user_input"|"agent_response"|"tool",...}}`。`agent_response` は `text_delta`(本文の断片。ACTIVE で複数回来るのが本来で、実測では最後の DONE に末尾の改行が乗った)、`tool` は `tool_name` と `tool_info.parameters`、DONE 時に `tool_info.error.{type,message}`(拒否されたコマンドは `TOOL_ERROR` / `context canceled`)
- `{"event":"result","result":{"status","response","denied_actions",...}}` が末尾(実測 3 件)。実測した単一応答では `response` は全 `text_delta` の連結と一致したが、agy 自身のレビューによれば tool 呼び出しを挟む複数ターンや正規化で差異が出る場合があり、`result` の後に行が続く・異常終了で `result` が無い場合もある(UNSURE 付き)。wrapper は差異を warning にとどめ、`result` 欠落は失敗にする
- agy のレビューが挙げたその他のイベント: `{"event":"error","error":{"type","message"}}`(致命的エラー時)、`thought` / `reasoning` 等の step_type(思考モデル)。実測では未観測(UNSURE)だが、wrapper は未知イベントを stderr に可視化する

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

## レビュー Round 1 と反映

- agy(仕様): Major 3 → (1) 本文を流した後に stdout へ sentinel が結合する → 直前に改行を補う(拒否行と同じ扱いを全エラー経路へ)、(2) `event: "error"` の未処理で根本原因が隠れる → stderr に `ANTIGRAVITY: fatal_error=` を出し、`result` 欠落時の失敗文に含める、(3) PS 版の出力エンコーディングが cp932 で壊れる → wrapper 冒頭で `[Console]::OutputEncoding` を UTF-8 にしており、実機でも UTF-8 バイト列を確認済みのため否定(ただし子プロセスのデコード設定は Codex 指摘のとおり明示化)。Minor: 非 JSON 行の可視化、未知 step_type(`thought` 等)の進捗表示。Nit: work-log の断定表現 → すべて反映
- Codex gpt-5.6-terra(コード): Major 3 → (1) `ProcessStartInfo.StandardOutputEncoding` 未設定 → 明示設定(実機では Console 設定の継承で動いていた)、(2) parser の異常終了(exit 1 等、EPIPE)が「result 欠落」と誤診される → parser の exit を伝播、(3) 途中の壊れた行を黙って無視し成功扱い → **失敗にはせず** stderr に件数と先頭 500 バイトを warning として出し、`result` が無い場合は失敗文に含める(agy が「上流の通知等で非 JSON 行が混ざり得る」と述べており、装飾的な行で毎回失敗する方が実害が大きいと判断)。Minor: PS 版の先頭 BOM、全 delta と raw の全量保持 → SHA-256 と先頭 500 バイトに、`timeout --kill-after`、PS の deadline 境界、liveness テストの内容検証、`date +%s%N` の移植性 → 反映

## 検証

- unit: test-wrapper.sh 36/36 を python 既定・node 強制・jq 強制(buffered fallback)の 3 経路で実行、test-wrapper.ps1 37/37、test-implement 両版(26/26、OK)、test-artifact 両版 30/30、test-skill-bundles OK、sync -Check 同期済み
- 実 agy 1.2.7 E2E(両版): README を読ませる依頼で `ANTIGRAVITY: tool=view_file state=ACTIVE/DONE` が先に stderr に出てから本文が届く。`git status` を打たせる依頼は `tool=run_command ... error=TOOL_ERROR: context canceled` の後に従来どおり拒否 sentinel で exit 1(node 経路でも同じ)。3 秒タイムアウトは両版 exit 2
- Round 1 反映後の再 E2E: 両版で日本語を含む本文が UTF-8 バイト列のまま逐次出力(PS 版は od で確認)、tool 進捗、拒否 sentinel(stderr tail 付き)を再確認
