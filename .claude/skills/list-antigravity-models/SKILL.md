---
name: list-antigravity-models
description: Antigravity CLIのモデル指定方法とantigravity-wrapperの現在のモデル設定を確認する。
disable-model-invocation: true
allowed-tools: Bash Read
---

# Antigravityモデル設定を確認する

この `SKILL.md` のディレクトリ（通常 `$CLAUDE_SKILL_DIR`）直下の `scripts/` を絶対パスへ解決する。現在の作業ディレクトリや共通 `$HOME/scripts` を前提にしない。

```bash
agy models
powershell -ExecutionPolicy Bypass -NoProfile -File "<解決したscripts>/antigravity-wrapper.ps1" -ShowModel
```

```bash
agy models
bash "<解決したscripts>/antigravity-wrapper.sh" --show-model
```

各コマンドは単独で実行する。CLIが完全な一覧を返さない場合は推測しない。モデル選択方法、保存設定、CLI既定を区別して表示する。
