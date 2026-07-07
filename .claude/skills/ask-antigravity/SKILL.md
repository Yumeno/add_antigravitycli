---
name: ask-antigravity
description: Antigravity CLIに設計判断やバグ調査のセカンドオピニオンを求める。ユーザーがAntigravityへの問い合わせを明示した場合に使う。
disable-model-invocation: true
allowed-tools: Bash Read
---

# Antigravity CLIに質問する

`$ARGUMENTS` を質問として使う。この `SKILL.md` のディレクトリ（通常 `$CLAUDE_SKILL_DIR`）直下の `scripts/` を絶対パスへ解決し、OSに合う同梱wrapperを単独コマンドで実行する。現在の作業ディレクトリや共通 `$HOME/scripts` を前提にしない。

```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "<解決したscripts>/antigravity-wrapper.ps1" -Prompt "$ARGUMENTS"
```

```bash
bash "<解決したscripts>/antigravity-wrapper.sh" --prompt "$ARGUMENTS"
```

失敗sentinelを回答として扱わない。成功時は「Antigravity CLIの回答」として提示する。wrapperはboolean `--sandbox` を常に有効化するため、sandboxへmode値を渡さない。モデル名はユーザーが指定した場合だけ渡す。ファイルやdiffを送る場合は `/ask-antigravity-with-context` を使う。
