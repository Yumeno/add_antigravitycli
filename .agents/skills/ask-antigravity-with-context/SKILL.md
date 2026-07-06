---
name: ask-antigravity-with-context
description: テキスト、複数の画像・音声・動画・PDF、git diff、git logなどのコンテキストを添えてAntigravity CLIにレビュー、監査、設計相談を依頼する。ユーザーがAntigravityによるmedia確認や、ファイルパス・diff・security・監査と併せた質問を明示した場合に使う。
---

# コンテキスト付きでAntigravity CLIに質問する

送信対象をユーザーの依頼に必要な範囲へ限定する。秘密情報、認証情報、無関係なファイルを含めない。

## 手順

1. 対象を決める。
   - ファイルパス指定: そのファイルを読む。
   - `review` / `レビュー` / `diff`: `git diff` と `git diff --staged` を確認する。
   - `security` / `セキュリティ` / `監査` / `audit`: diffと変更ファイル一覧を確認する。
   - `log` / `履歴` / `history`: `git log --oneline -20` を確認する。
   - media指定: 指定された全ファイルをユーザーの順序どおり保持する。画像だけと仮定せず、音声・動画・PDF・異種混在を同列に扱う。
2. 外部サービスへ送信すべきでない内容が見つかったら停止し、ユーザーへ対象除外または許可を求める。
3. 質問、対象の説明、必要な原文をUTF-8の一時ファイルへまとめる。正常ワークロードを黙って切り詰めない。大きすぎる場合は警告し、分割方針を示す。
4. この `SKILL.md` のディレクトリから `../../../scripts` を絶対パスへ解決し、wrapperを単独コマンドで実行する。現在の作業ディレクトリを前提にしない。

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File "<解決したscripts>/antigravity-wrapper.ps1" -Prompt "レビューしてください" -ContextFile "C:/absolute/path/context.txt"
```

複数mediaの場合は、絶対pathを1行1件で並べたUTF-8ファイルを作り、`-AttachmentList`で渡す。単一mediaだけなら`-Attachment`も使える。

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File "<解決したscripts>/antigravity-wrapper.ps1" -Prompt "順番に比較してください" -AttachmentList "C:/absolute/path/attachments.txt"
```

```bash
bash "<解決したscripts>/antigravity-wrapper.sh" --prompt "レビューしてください" --context-file "/tmp/context.txt"
```

```bash
bash "<解決したscripts>/antigravity-wrapper.sh" --prompt "順番に比較してください" --attachment "/path/first.png" --attachment "/path/second.wav" --attachment "/path/third.mp4"
```

5. 失敗sentinelは回答と区別する。成功時はAntigravityの指摘と自身の検証結果を分けて提示する。
6. 作成した一時ファイルだけを、絶対パスと対象範囲を確認して削除する。

wrapperはAntigravity CLIのboolean `--sandbox` を常に有効化する。sandboxへmode値を渡そうとしない。

wrapperが表示する順序、MIME、byte数、`probe-verified` / `experimental`を報告する。`experimental`を対応保証済みと表現しない。未認識形式を別形式へ暗黙変換しない。

このスキルは読み取りと質問用である。Antigravityへ編集を許可しない。実装委任には `antigravity-implement` を明示的に使う。
