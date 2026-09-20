---
name: antigravity-implement
description: Antigravity CLIを実装担当として起動し、必要に応じて複数の画像・音声・動画・PDFを参照させ、cleanなGitリポジトリを最小権限で編集させて変更を独立検収する。ユーザーがこのスキルまたはAntigravityへの実装委任を明示した場合に限って使う。
disable-model-invocation: true
allowed-tools: Bash Read Grep Glob
---

# Antigravityへ実装を委任する

`$ARGUMENTS` を実装指示として使う。質問やレビューから自動起動しない。

1. 対象がGitリポジトリか確認する。
2. `git status --short` がcleanでなければ停止する。stash、reset、checkoutを行わない（同一セッションの2回目以降は下記の継続委任を使う）。
3. `HEAD`、ブランチ、statusを記録する。
4. 変更範囲、禁止範囲、受け入れ条件、テストをUTF-8の一時仕様ファイルへ明記する。agentはシェルコマンド（テスト・ビルド・git）を実行できない前提で書く（agy 1.2.7 の非対話実行では自動拒否。安全制約テキストで禁止済み）。テストは自分が実行する。
5. commit、push、PR、依存追加、破壊的操作を許可しない。dangerous flagや承認回避フラグは既定で禁止する。
6. この `SKILL.md` のディレクトリ（通常 `$CLAUDE_SKILL_DIR`）直下の `scripts/` を絶対パスへ解決し、同梱されたhelperを単独コマンドで呼ぶ。現在の作業ディレクトリや共通 `$HOME/scripts` を前提にしない。

```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "<解決したscripts>/antigravity-implement.ps1" -SpecFile "C:/absolute/spec.txt" -Repo "C:/absolute/repo"
```

複数mediaは絶対pathを1行1件で並べたUTF-8ファイルを作り、`-AttachmentList`で渡す。

```bash
bash "<解決したscripts>/antigravity-implement.sh" --spec-file "/absolute/spec.txt" --repo "/absolute/repo"
```

bashでは`--attachment`を必要な数だけ順序どおり反復する。

7. 成功申告を信用せず、`git status --short`、`git diff --stat`、`git diff` と受け入れテストを自分で確認する。agentの `### Verification Plan` は提案にすぎない。差分を読んでから実行するテストを自分で選ぶ。
10. 継続委任: 1回目は `-Session <リポジトリ外のパス>`（bashは `--session`）を付けて実行する。テストが失敗したら、失敗ログの要点と「この失敗だけを直す」旨の新しい仕様ファイルで同じ `-Session` を付けて再実行する。helperはworking treeの変更がセッション記録の範囲内かを確認し、範囲外なら一覧を出して停止する。自分のテスト実行の副産物（`__pycache__` 等）が原因なら一覧を確認して `-AdoptChanges`（`--adopt-changes`）で取り込み、それ以外は取り込まずstashやresetもせず報告する。反復は既定3回まで。終了時に `-Session <path> -CloseSession`（`--close-session`）で削除する。`-Session` なしは従来どおりの単発実行。
8. 依頼外変更、秘密情報、生成物、依存追加、危険なコマンド、テスト弱体化を検査し、変更ファイル、テスト結果、残課題を報告する。問題があっても無断で変更を破棄しない。
9. 自分が作成した一時仕様ファイルだけを削除する。

wrapperはAntigravity CLIのboolean `--sandbox` を常に有効化する。sandboxへmode値を渡そうとしない。

## 画像アセットの生成・編集

Antigravity CLIは画像生成を内包しており、このスキルのフロー(仕様書 → wrapper → 検収)のまま画像アセットの生成・編集を委任できる。画像タスクの仕様書を書く前に、このスキル同梱の `references/image-generation.md`(この `SKILL.md` と同じディレクトリの `references/` 配下)を読むこと。要点: agy 1.2.7 の headless + sandbox では agent のシェルコマンドが権限拒否され(実測範囲)、生成物を指定パスへ複製・変換させると空応答になる。仕様書では「複製・変換・コマンド実行をしない」「`ARTIFACT_PATH:` に生成物の絶対パスを報告する」と指示する(1.2.7 で 1 件確認)。helper の自動検収は生成物を見ないので、helper 終了後に host が `ARTIFACT_PATH`(`~/.gemini/antigravity-cli/brain/` 配下であることを確認)からリポジトリ内へ複製(必要なら PNG 変換)し、magic bytes・寸法・目視で別途検収する。仕様書にはアスペクト比(`1:1` 既定、`16:9`/`9:16`/`4:3`/`3:4`/`3:2`/`2:3`)を書き、UI アセットは「デバイスフレームを含めず UI 画面のみ」を明記する。編集はリファレンス画像の絶対パス(最大 3 枚。パス直書きは 1.1.1 で実測、1.2.7 では未再検証)を書き、変更点の限定列挙 + 維持項目の明示列挙で指示する。生成モデル名は応答に出ないため報告させない・推測で書かない。検収ではmagic bytes・バイト数・目視を省かない。
