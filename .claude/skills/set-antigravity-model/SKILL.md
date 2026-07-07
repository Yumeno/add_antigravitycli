---
name: set-antigravity-model
description: antigravity-wrapperの既定モデルを保存または確認する。モデル変更はユーザーの明示指定時だけ行う。
disable-model-invocation: true
allowed-tools: Bash Read
---

# Antigravityの既定モデルを設定する

`$ARGUMENTS` が空なら設定を表示し、値があればモデル名として保存する。この `SKILL.md` のディレクトリ（通常 `$CLAUDE_SKILL_DIR`）直下の `scripts/` を絶対パスへ解決し、現在の作業ディレクトリや共通 `$HOME/scripts` を前提にしない。

```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "<解決したscripts>/antigravity-wrapper.ps1" -ShowModel
powershell -ExecutionPolicy Bypass -NoProfile -File "<解決したscripts>/antigravity-wrapper.ps1" -SetModel "$ARGUMENTS"
```

```bash
bash "<解決したscripts>/antigravity-wrapper.sh" --show-model
bash "<解決したscripts>/antigravity-wrapper.sh" --set-model "$ARGUMENTS"
```

モデル名を推測せず、設定先と優先順位をwrapperの出力どおりに報告する。
