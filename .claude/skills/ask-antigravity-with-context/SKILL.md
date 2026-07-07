---
name: ask-antigravity-with-context
description: テキスト、複数の画像・音声・動画・PDF、git diffを添えてAntigravity CLIにレビュー、監査、設計相談を依頼する。Antigravityによるmediaまたはコンテキスト付き確認を明示された場合に使う。
disable-model-invocation: true
allowed-tools: Bash Read Write Grep Glob
---

# コンテキスト付きでAntigravityに質問する

1. ファイル指定、`git diff`、`git diff --staged`、`git log --oneline -20`、security/監査時は変更ファイル一覧も、依頼に必要なものだけを収集する。
2. 秘密情報や無関係な内容を除外する。外部送信の可否が不明なら停止して確認する。
3. UTF-8の一時ファイルに質問、対象説明、原文をまとめる。黙ってsize capを適用しない。
   - mediaはユーザー指定順を保持し、画像・音声・動画・PDF・異種混在を同列に扱う。
4. この `SKILL.md` のディレクトリ（通常 `$CLAUDE_SKILL_DIR`）直下の `scripts/` を絶対パスへ解決し、同梱されたwrapperを単独コマンドで呼ぶ。現在の作業ディレクトリや共通 `$HOME/scripts` を前提にしない。

```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "<解決したscripts>/antigravity-wrapper.ps1" -Prompt "$ARGUMENTS" -ContextFile "C:/absolute/path/context.txt"
```

複数mediaは絶対pathを1行1件で並べたUTF-8ファイルを作り、`-AttachmentList`で渡す。単一mediaだけなら`-Attachment`も使える。

```bash
bash "<解決したscripts>/antigravity-wrapper.sh" --prompt "$ARGUMENTS" --context-file "/tmp/context.txt"
```

bashでは`--attachment`を必要な数だけ順序どおり反復する。

5. 回答と失敗sentinelを区別し、自身でも指摘を検証する。
6. 自分が作った一時ファイルだけを削除する。

wrapperはboolean `--sandbox` を常に有効化するため、sandboxへmode値を渡さない。
順序、MIME、byte数、`probe-verified` / `experimental`を報告し、未検証形式を対応保証済みと表現しない。暗黙変換しない。

編集を許可しない。実装委任には `/antigravity-implement` を明示的に使う。
