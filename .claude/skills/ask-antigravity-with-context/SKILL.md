---
name: ask-antigravity-with-context
description: ファイル内容やgit diffを添えてAntigravity CLIにレビュー、監査、設計相談を依頼する。Antigravityによるコンテキスト付き確認を明示された場合に使う。
disable-model-invocation: true
allowed-tools: Bash Read Write Grep Glob
---

# コンテキスト付きでAntigravityに質問する

1. ファイル指定、`git diff`、`git diff --staged`、`git log --oneline -20` から依頼に必要なものだけを収集する。
2. 秘密情報や無関係な内容を除外する。外部送信の可否が不明なら停止して確認する。
3. UTF-8の一時ファイルに質問、対象説明、原文をまとめる。黙ってsize capを適用しない。
4. この `SKILL.md` のディレクトリ（通常 `$CLAUDE_SKILL_DIR`）から `../../../scripts` を絶対パスへ解決し、wrapperを単独コマンドで呼ぶ。現在の作業ディレクトリを前提にしない。

```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "<解決したscripts>/antigravity-wrapper.ps1" -Prompt "$ARGUMENTS" -ContextFile "C:/absolute/path/context.txt"
```

```bash
bash "<解決したscripts>/antigravity-wrapper.sh" --prompt "$ARGUMENTS" --context-file "/tmp/context.txt"
```

5. 回答と失敗sentinelを区別し、自身でも指摘を検証する。
6. 自分が作った一時ファイルだけを削除する。

wrapperはboolean `--sandbox` を常に有効化するため、sandboxへmode値を渡さない。

編集を許可しない。実装委任には `/antigravity-implement` を明示的に使う。
