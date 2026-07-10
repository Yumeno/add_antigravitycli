# 作業記録 2026-07-10 — agy 1.1.1 の --print 仕様変更への追従

## 目的

Issue [#7](https://github.com/Yumeno/add_antigravitycli/issues/7) の修正。Antigravity CLI 1.1.1 で `--print` が値必須の string flag に変わり、wrapper の全呼び出しが誤動作していた。

## 発見の経緯

Issue #5(画像生成 reference)の実機検証中に発見。生成 probe 1 件目は成功したが、数分後の 2 件目から「プロンプトと無関係に `--print-timeout` フラグの解説が返る」誤動作が再現するようになった。切り分けの結果:

1. wrapper なしの直接呼び出しでも再現 → wrapper 起因ではない
2. `agy changelog` に 1.1.1 の変更を発見: 「no longer reading stdin when a prompt is provided via a flag」
3. `--print` を値なしで置くと `flag needs an argument: -print` → **string flag 化を確認**
4. 現 wrapper の argv では「prompt = 文字列 `--print-timeout`」と解釈され、後続の `--sandbox` / `--new-project` / `--add-dir` も positional 落ちして**適用されていなかった**(安全機構の無言解除)
5. stdin パイプ(非 TTY)+ `--print` なしで非対話モードになり、全フラグが正常適用されることを実機確認

probe 1 件目の成功と 2 件目以降の失敗の間に agy の自動更新が挟まったと推定。

## 修正内容

- `scripts/antigravity-wrapper.{ps1,sh}`: agy 引数から `--print` を除去(stdin 経由のプロンプト渡しと他フラグは不変)
- `scripts/tests/test-wrapper.{ps1,sh}`: 期待 argv から `--print` を除き、「`--print` を含まない」回帰検査を追加
- 全 skill 同梱 bundle を sync tool で再配布(20 ファイル)
- README: 前提条件を「agy 1.1.1 以降」に更新、トラブルシューティングに旧 bundle の症状と installer 再実行の案内を追加

## 検証

- unit: test-wrapper.ps1 13/13、test-wrapper.sh 9/9、test-skill-bundles.ps1、test-implement.{ps1,sh} 全 PASS
- 実 agy E2E(修正後 wrapper 経由、1 件): 正常応答
- 実 agy で `--sandbox` / `--new-project` / `--add-dir` の適用も切り分け時に確認済み(add-dir 先へのファイル作成成功)

## 教訓

- **上流 CLI の自動更新は breaking change を随時持ち込む**。wrapper の argv 契約は「作った時点で正しい」だけでは足りず、実機 E2E を回帰の検知線にする必要がある(unit test の fake-agy は旧仕様を模倣し続けるため、この種の破壊は検知できない)。
- 誤動作時の応答が「もっともらしい解説文」なので、sentinel ベースの失敗検知には映らない。off-task 応答は上流仕様変更のシグナルとして疑うこと。
