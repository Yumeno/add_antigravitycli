---
name: ask-antigravity
description: Antigravity CLIに設計判断、バグ調査、実装方針などのセカンドオピニオンを求める。ユーザーが「Antigravityに聞いて」「ask-antigravity」など、Antigravity CLIへの問い合わせを明示した場合に使う。ファイルやdiffを渡す場合はask-antigravity-with-contextを使う。
---

# Antigravity CLIに質問する

ユーザーの質問を改変せず、wrapperへ渡す。現在の作業ディレクトリを前提にせず、この `SKILL.md` のディレクトリ直下の `scripts/` を絶対パスへ解決する。

## 手順

1. 質問が空なら内容を確認する。
2. OSに合うwrapperを、シェル演算子や出力リダイレクトを組み合わせず、単独のコマンドとして実行する。
3. Windowsでは次を使う。

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File "<解決したscripts>\antigravity-wrapper.ps1" -Prompt "質問"
```

4. Linux/macOSでは次を使う。

```bash
bash "<解決したscripts>/antigravity-wrapper.sh" --prompt "質問"
```

5. wrapperが返す失敗sentinelをAntigravityの回答として扱わず、呼び出し失敗として提示する。
6. 成功時は回答を「Antigravity CLIの回答」として引用し、必要なら自身の見解との差分を短く補足する。

wrapperはAntigravity CLIのboolean `--sandbox` を常に有効化する。sandboxへmode値を渡そうとしない。

モデルをユーザーが指定した場合だけ `-Model` / `--model` を追加する。モデル名を推測しない。
