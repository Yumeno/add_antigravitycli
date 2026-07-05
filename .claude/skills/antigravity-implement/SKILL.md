---
name: antigravity-implement
description: Antigravity CLIを実装担当として起動し、cleanなGitリポジトリを最小権限で編集させ、変更を独立検収する。ユーザーがこのスキルまたはAntigravityへの実装委任を明示した場合に限って使う。
disable-model-invocation: true
allowed-tools: Bash Read Grep Glob
---

# Antigravityへ実装を委任する

`$ARGUMENTS` を実装指示として使う。質問やレビューから自動起動しない。

1. 対象がGitリポジトリか確認する。
2. `git status --short` がcleanでなければ停止する。stash、reset、checkoutを行わない。
3. `HEAD`、ブランチ、statusを記録する。
4. 変更範囲、禁止範囲、受け入れ条件、テストをUTF-8の一時仕様ファイルへ明記する。
5. commit、push、PR、依存追加、破壊的操作を許可しない。dangerous flagや承認回避フラグは既定で禁止する。
6. この `SKILL.md` のディレクトリ（通常 `$CLAUDE_SKILL_DIR`）から `../../../scripts` を絶対パスへ解決し、helperを単独コマンドで呼ぶ。現在の作業ディレクトリを前提にしない。

```bash
powershell -ExecutionPolicy Bypass -NoProfile -File "<解決したscripts>/antigravity-implement.ps1" -SpecFile "C:/absolute/spec.txt" -Repo "C:/absolute/repo"
```

```bash
bash "<解決したscripts>/antigravity-implement.sh" --spec-file "/absolute/spec.txt" --repo "/absolute/repo"
```

7. 成功申告を信用せず、`git status --short`、`git diff --stat`、`git diff` と受け入れテストを自分で確認する。
8. 依頼外変更や秘密情報を検査し、変更ファイル、テスト結果、残課題を報告する。問題があっても無断で変更を破棄しない。
9. 自分が作成した一時仕様ファイルだけを削除する。

wrapperはAntigravity CLIのboolean `--sandbox` を常に有効化する。sandboxへmode値を渡そうとしない。
