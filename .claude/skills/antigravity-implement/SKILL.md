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

Antigravity CLIは画像生成を内包しており、このスキルのフロー(仕様書 → wrapper → 検収)のまま画像アセットの生成・編集を委任できる。画像タスクの仕様書を書く前に、このスキル同梱の `references/image-generation.md`(この `SKILL.md` と同じディレクトリの `references/` 配下)を読むこと。要点: 保存先はリポジトリ内の**絶対パス**で仕様書に明示する(曖昧な指定はagyのscratchに落ちてGit検収に映らない)。編集はリファレンス画像の絶対パスを書き、変更点の限定列挙 + 維持項目の明示列挙で指示する。生成モデル名は応答に出ないため報告させない・推測で書かない。検収ではmagic bytes・バイト数・目視を省かない。
