---
name: antigravity-implement
description: Antigravity CLIを実装担当として明示的に起動し、必要に応じて複数の画像・音声・動画・PDFを参照させ、cleanなGitリポジトリ内を最小権限で編集させて変更を独立検収する。ユーザーが「antigravity-implement」「Antigravityに実装させて」など実装委任を明示した場合に限って使う。
---

# Antigravity CLIへ実装を委任する

外部エージェントへ書き込み権限を渡す高リスク操作として扱う。ユーザーの明示指定なしに起動しない。

## 実行前チェック

1. 対象がGitリポジトリであることを確認する。
2. `git status --short` でclean treeを確認する。既存変更があれば停止し、勝手にstash、破棄、上書きしない。
3. 現在の `HEAD`、ブランチ、statusを記録する。
4. タスク、変更可能範囲、変更禁止範囲、受け入れ条件、実行すべきテストをUTF-8の一時仕様ファイルへ具体的に記述する。
5. コミット、push、PR作成、Antigravity CLI 経由の委任以外の外部送信、依存追加、破壊的操作を許可しない。dangerous flagや承認回避フラグは既定で禁止する。必要なら個別にユーザー承認を得る。

## 実行

この `SKILL.md` のディレクトリから `../../../scripts` を絶対パスへ解決し、implement helperを単独コマンドで呼ぶ。現在の作業ディレクトリを前提にしない。

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File "<解決したscripts>/antigravity-implement.ps1" -SpecFile "C:/absolute/spec.txt" -Repo "C:/absolute/repo"
```

複数mediaは絶対pathを1行1件で並べたUTF-8ファイルを作り、`-AttachmentList`で渡す。

```bash
bash "<解決したscripts>/antigravity-implement.sh" --spec-file "/absolute/spec.txt" --repo "/absolute/repo"
```

bashでは`--attachment`を必要な数だけ順序どおり反復する。

wrapperはAntigravity CLIのboolean `--sandbox` を常に有効化する。sandboxへmode値を渡そうとしない。権限拡大や対話承認の自動化を行わない。

## 独立検収

1. helperの成功申告を根拠に完了扱いしない。
2. 実行前snapshotと比較し、`git status --short`、`git diff --stat`、`git diff` を自分で確認する。
3. 依頼外変更、秘密情報、生成物、依存追加、危険なコマンド、テスト弱体化を検査する。
4. 既存環境で受け入れ条件に対応するテストを実行する。新しいテスト依存を勝手に追加しない。
5. 問題があれば、変更内容を保持したまま具体的に報告する。無断でresetやcheckoutを行わない。
6. 検収結果、変更ファイル、テスト結果、残課題をユーザーへ報告する。
7. 自分が作成した一時仕様ファイルだけを、絶対パスと対象範囲を確認して削除する。
