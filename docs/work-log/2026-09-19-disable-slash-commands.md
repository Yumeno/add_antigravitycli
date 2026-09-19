# 作業記録 2026-09-19 — wrapper に --disable-slash-commands を常時付加

## 目的

Issue [#10](https://github.com/Yumeno/add_antigravitycli/issues/10) の対応。`ask-antigravity-with-context` 等で未信頼コンテキスト(diff、ログ、ソースコード)を非対話モードの `agy` に渡す際、その中に含まれる `/commit` のようなスラッシュ記法や `$skill` 記法が CLI 側でコマンド・スキルとして展開されるのを防ぐ。

## 前提バージョン

- 実機 `agy` 1.2.7 で `--help` に `--disable-slash-commands  Disable slash command and skill expansion in print mode` の存在を確認。
- `agy changelog` で導入時期を確認: 1.1.9 で「print mode にスラッシュコマンド・スキル展開を追加、`--disable-slash-commands` で opt-out」。1.1.11 では対話専用スラッシュコマンドが print mode で明示的に失敗するよう変更されており、行頭に `/` を含む入力が展開・拒否される経路が実在する。
- 1.1.9 未満ではフラグ自体が無く引数エラーで wrapper が全滅するため、README の前提条件を「1.1.9 以降」に引き上げた(条件付与より前提引き上げを選択)。

## 仕様上の補足(agy レビューの指摘より)

- agy のスラッシュコマンド解釈は**行頭トークン**が対象。行途中の `// TODO: /fix` のような記述は展開されない。リスクは untrusted context 内の行頭 `/bin/sh` や `/test` 等が「未知/対話専用コマンド」として扱われ、応答の乱れや失敗を招くこと、および `$skill` 記法のスキル展開。
- 本フラグが防ぐのは CLI 側のコマンド/スキル解釈であり、LLM が未信頼コンテキストの指示に従う prompt injection そのものではない。多層防御の一層として位置づける。

## 修正内容

- `scripts/antigravity-wrapper.{ps1,sh}`: agy 引数に `--disable-slash-commands` を常時追加
- `scripts/tests/test-wrapper.{ps1,sh}`: 期待 argv に同フラグを追加
- 全 skill 同梱 bundle を sync tool で再配布(20 ファイル)
- README: 前提条件を「agy 1.1.9 以降」に更新

## 検証

- unit: test-wrapper.ps1 13/13、test-wrapper.sh 9/9、test-skill-bundles.ps1 OK、sync-skill-scripts.ps1 -Check 同期済み
- 実 agy 1.2.7 E2E(修正後 wrapper 経由、1 件): `/help /test /commit $skill` を含むプロンプトに対し、コマンド展開されず文字列がそのまま返った
