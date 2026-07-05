# add_antigravitycli

Claude CodeまたはCodexからAntigravity CLIへ質問、レビュー、実装委任を行うためのAgent Skillsです。

## 提供するスキル

| スキル | 用途 |
|---|---|
| `ask-antigravity` | コンテキストなしの質問、セカンドオピニオン |
| `ask-antigravity-with-context` | ファイル、diff、履歴を添えたレビューや監査 |
| `antigravity-implement` | cleanなGitリポジトリでの明示的な実装委任と独立検収 |
| `list-antigravity-models` | モデル指定方法と現在のwrapper設定の確認 |
| `set-antigravity-model` | wrapperの既定モデルの保存、確認 |

`ask-*` は読み取り専用です。`antigravity-implement` だけが書き込みを伴い、ユーザーが明示的に実装委任した場合に限って起動します。

## 前提条件

- Antigravity CLI（`agy`）がインストール・認証済みであること
- Windows PowerShell 5.1+、またはbash
- 実装委任では対象がGitリポジトリで、開始時点のworktreeがcleanであること

## 構成と互換性

- `.agents/skills/`: Codex向けの正本。Agent Skills標準に合わせ、frontmatterは `name` と `description` のみ。
- `.claude/skills/`: Claude Code向け配布コピー。手動起動を保証するため `disable-model-invocation: true` と最小限の `allowed-tools` を追加。
- `scripts/`: CLI呼び出し、実装、検収を担うクロスプラットフォームhelper。

両ディレクトリの手順は同じ動作を意図しますが、frontmatterは機械的に同一化しません。機能変更時は `.agents` を先に更新し、Claude Code固有メタデータを保ったまま `.claude` へ同期してください。

## インストール

### Codex

プロジェクト内で使う場合は、このリポジトリの `.agents/skills/` をそのまま利用します。ユーザー全体へ導入する場合:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.agents\skills" | Out-Null
Get-ChildItem .agents\skills -Directory | Copy-Item -Destination "$env:USERPROFILE\.agents\skills" -Recurse -Force
New-Item -ItemType Directory -Force "$env:USERPROFILE\.agents\scripts" | Out-Null
Copy-Item scripts\antigravity-* "$env:USERPROFILE\.agents\scripts\" -Force
```

### Claude Code

プロジェクト内で使う場合は `.claude/skills/` を利用します。ユーザー全体へ導入する場合:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\skills" | Out-Null
Get-ChildItem .claude\skills -Directory | Copy-Item -Destination "$env:USERPROFILE\.claude\skills" -Recurse -Force
New-Item -ItemType Directory -Force "$env:USERPROFILE\.claude\scripts" | Out-Null
Copy-Item scripts\antigravity-* "$env:USERPROFILE\.claude\scripts\" -Force
```

各Skillは自身の配置場所から `../../../scripts` を解決します。そのため、ユーザー全体への導入ではSkillと同じツールディレクトリ配下の `scripts/` も必須です。プロジェクト配置ではリポジトリ直下の `scripts/` を参照します。

## 使用例

```text
$ask-antigravity この設計のtrade-offを評価して
$ask-antigravity-with-context 現在のgit diffをセキュリティレビューして
$antigravity-implement issue #12を実装して。依存追加は禁止
$list-antigravity-models
$set-antigravity-model model-name
```

Claude Codeでは `/ask-antigravity ...` のように呼び出します。

## 安全設計

- プロンプトはコマンドラインへ直接展開せず、wrapperが安全な入力経路でCLIへ渡します。
- wrapperは値を取らないboolean `agy --sandbox` を常に有効化します。`read-only` や `workspace-write` のようなmode値は渡しません。
- コンテキストは依頼に必要な範囲だけを外部サービスへ送信します。
- helperの失敗sentinelとLLM回答を区別します。
- 実装委任前にclean treeとsnapshotを確認し、実行後はGit diffとテストを呼び出し元が独立検収します。
- commit、push、PR作成、既存変更の破棄、権限拡大は自動実行しません。

## テスト

実通信を必要としないunit testを先に実行してください。

```powershell
Get-ChildItem scripts\tests\test-*.ps1 | ForEach-Object {
    powershell -ExecutionPolicy Bypass -NoProfile -File $_.FullName
}
```

実際のAntigravity CLIを使うE2Eは、認証、課金、レート制限を確認してから代表ケース1件で実行してください。

## トラブルシューティング

`Please sign in...` と表示される場合は、wrapperやスキルの問題ではなくAntigravity CLIが未認証です。Antigravity CLIでサインインを完了してから再実行してください。認証を伴うE2Eを自動で繰り返さないでください。

## ライセンス

[MIT License](LICENSE)
