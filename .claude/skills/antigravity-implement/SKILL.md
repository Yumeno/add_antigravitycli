---
name: antigravity-implement
description: Antigravity CLIを実装担当として起動し、必要に応じて複数の画像・音声・動画・PDFを参照させ、cleanなGitリポジトリを最小権限で編集させて変更を独立検収する。ユーザーがこのスキルまたはAntigravityへの実装委任を明示した場合に限って使う。
disable-model-invocation: true
allowed-tools: Bash Read Grep Glob
---

# Antigravityへ実装を委任する

`$ARGUMENTS` を実装指示として使う。質問やレビューから自動起動しない。

1. 対象がGitリポジトリか確認する。
2. `git status --short` がcleanでなければ停止する。stash、reset、checkoutを行わない。
3. `HEAD`、ブランチ、statusを記録する。
4. 変更範囲、禁止範囲、受け入れ条件、テストをUTF-8の一時仕様ファイルへ明記する。
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

7. 成功申告を信用せず、`git status --short`、`git diff --stat`、`git diff` と受け入れテストを自分で確認する。
8. 依頼外変更、秘密情報、生成物、依存追加、危険なコマンド、テスト弱体化を検査し、変更ファイル、テスト結果、残課題を報告する。問題があっても無断で変更を破棄しない。
9. 自分が作成した一時仕様ファイルだけを削除する。

wrapperはAntigravity CLIのboolean `--sandbox` を常に有効化する。sandboxへmode値を渡そうとしない。

## 画像アセットの生成・編集

Antigravity CLIは画像生成を内包しており、このスキルのフロー(仕様書 → wrapper → 検収)のまま画像アセットの生成・編集を委任できる。画像タスクの仕様書を書く前に、このスキル同梱の `references/image-generation.md`(この `SKILL.md` と同じディレクトリの `references/` 配下)を読むこと。要点: agy 1.2.7 の headless + sandbox では agent のシェルコマンドが権限拒否され(実測範囲)、生成物を指定パスへ複製・変換させると空応答になる。仕様書では「複製・変換・コマンド実行をしない」「`ARTIFACT_PATH:` に生成物の絶対パスを報告する」と指示する(1.2.7 で 1 件確認)。helper の自動検収は生成物を見ないので、helper 終了後に host が `ARTIFACT_PATH`(`~/.gemini/antigravity-cli/brain/` 配下であることを確認)からリポジトリ内へ複製(必要なら PNG 変換)し、magic bytes・寸法・目視で別途検収する。仕様書にはアスペクト比(`1:1` 既定、`16:9`/`9:16`/`4:3`/`3:4`/`3:2`/`2:3`)を書き、UI アセットは「デバイスフレームを含めず UI 画面のみ」を明記する。編集はリファレンス画像の絶対パス(最大 3 枚。パス直書きは 1.1.1 で実測、1.2.7 では未再検証)を書き、変更点の限定列挙 + 維持項目の明示列挙で指示する。生成モデル名は応答に出ないため報告させない・推測で書かない。検収ではmagic bytes・バイト数・目視を省かない。
