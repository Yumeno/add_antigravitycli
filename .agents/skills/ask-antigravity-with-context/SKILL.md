---
name: ask-antigravity-with-context
description: ファイル内容、git diff、git logなどのコンテキストを添えてAntigravity CLIにレビュー、監査、設計相談を依頼する。ユーザーがAntigravityによるレビューや、ファイルパス・diff・security・監査と併せた質問を明示した場合に使う。
---

# コンテキスト付きでAntigravity CLIに質問する

送信対象をユーザーの依頼に必要な範囲へ限定する。秘密情報、認証情報、無関係なファイルを含めない。

## 手順

1. 対象を決める。
   - ファイルパス指定: そのファイルを読む。
   - `review` / `レビュー` / `diff`: `git diff` と `git diff --staged` を確認する。
   - `security` / `セキュリティ` / `監査` / `audit`: diffと変更ファイル一覧を確認する。
   - `log` / `履歴` / `history`: `git log --oneline -20` を確認する。
2. 外部サービスへ送信すべきでない内容が見つかったら停止し、ユーザーへ対象除外または許可を求める。
3. 質問、対象の説明、必要な原文をUTF-8の一時ファイルへまとめる。正常ワークロードを黙って切り詰めない。大きすぎる場合は警告し、分割方針を示す。
4. この `SKILL.md` のディレクトリから `../../../scripts` を絶対パスへ解決し、wrapperを単独コマンドで実行する。現在の作業ディレクトリを前提にしない。

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File "<解決したscripts>\antigravity-wrapper.ps1" -Prompt "レビューしてください" -ContextFile "C:\absolute\path\context.txt"
```

```bash
bash "<解決したscripts>/antigravity-wrapper.sh" --prompt "レビューしてください" --context-file "/tmp/context.txt"
```

5. 失敗sentinelは回答と区別する。成功時はAntigravityの指摘と自身の検証結果を分けて提示する。
6. 作成した一時ファイルだけを、絶対パスと対象範囲を確認して削除する。

wrapperはAntigravity CLIのboolean `--sandbox` を常に有効化する。sandboxへmode値を渡そうとしない。

このスキルは読み取りと質問用である。Antigravityへ編集を許可しない。実装委任には `antigravity-implement` を明示的に使う。
