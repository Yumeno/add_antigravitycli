---
name: list-antigravity-models
description: Antigravity CLIで利用できるモデルの確認方法と、antigravity-wrapperの現在のモデル設定を表示する。ユーザーがAntigravityのモデル一覧、利用可能モデル、現在のwrapper設定を尋ねた場合に使う。
---

# Antigravityモデル設定を確認する

`agy models` で利用可能モデルを確認する。この `SKILL.md` のディレクトリから `../../../scripts` を絶対パスへ解決し、OSに合うwrapperで保存設定も表示する。現在の作業ディレクトリを前提にしない。

```powershell
agy models
powershell -ExecutionPolicy Bypass -NoProfile -File "<解決したscripts>\antigravity-wrapper.ps1" -ShowModel
```

```bash
agy models
bash "<解決したscripts>/antigravity-wrapper.sh" --show-model
```

各コマンドは単独で実行する。Antigravity CLIが完全なモデル一覧を提供しない場合、推測で一覧を作らない。CLIが示すモデル選択方法、現在保存されたwrapper設定、未設定時はCLI既定へ委ねることを区別して報告する。
