# add_antigravitycli

Claude CodeまたはCodexからAntigravity CLIへ質問、レビュー、実装委任を行うためのAgent Skillsです。

> Agent Skills to delegate questions, code reviews, and implementation tasks to Google Antigravity CLI (`agy`) from Claude Code or Codex CLI. Documentation is in Japanese.

## 提供するスキル

| スキル | 用途 |
|---|---|
| `ask-antigravity` | コンテキストなしの質問、セカンドオピニオン |
| `ask-antigravity-with-context` | テキスト、複数media、diff、履歴を添えたレビューや監査 |
| `antigravity-implement` | 複数mediaも参照できる、cleanなGitリポジトリでの実装委任と独立検収 |
| `list-antigravity-models` | モデル指定方法と現在のwrapper設定の確認 |
| `set-antigravity-model` | wrapperの既定モデルの保存、確認 |

`ask-*` は読み取り専用です。`antigravity-implement` だけが書き込みを伴い、ユーザーが明示的に実装委任した場合に限って起動します。

## 前提条件

- Antigravity CLI（`agy`）1.1.9 以降がインストール・認証済みであること（1.1.1 で `--print` の仕様が変わり、1.1.9 で print mode のスラッシュコマンド/スキル展開と `--disable-slash-commands` が追加された。wrapper は同フラグを常時付加するため、それ以前のバージョンは非対応。動作確認は 1.2.7）
- Windows PowerShell 5.1+、またはbash
- 実装委任では対象がGitリポジトリで、開始時点のworktreeがcleanであること（同一セッションの再委任は helper の `-Session` / `--session` で継続可能）

## 構成と互換性

- `.agents/skills/`: Codex CLI と Antigravity CLI(`agy`) が読む正本。Agent Skills標準に合わせ、frontmatterは `name` と `description` のみ。
- `.claude/skills/`: Claude Code向け配布コピー。手動起動を保証するため `disable-model-invocation: true` と最小限の `allowed-tools` を追加。
- `scripts/`: 開発用正本。CLI呼び出し、実装、検収、画像生成物の取り込み(`antigravity-artifact`)を担うクロスプラットフォームhelper。
- `*/skills/<skill>/scripts/`: 配布用コピー。各Skillは必要なhelperを同梱し、共通 `$HOME/scripts` を前提にしません。

両ディレクトリの手順は同じ動作を意図しますが、frontmatterは機械的に同一化しません。機能変更時は `.agents` を先に更新し、Claude Code固有メタデータを保ったまま `.claude` へ同期してください。

## インストール

### Codex

プロジェクト内で使う場合は、このリポジトリの `.agents/skills/` をそのまま利用します。ユーザー全体へ導入する場合:

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\install-for-codex.ps1
```
```bash
bash scripts/install-for-codex.sh
```

### Claude Code

プロジェクト内で使う場合は `.claude/skills/` を利用します。ユーザー全体へ導入する場合:

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\install-for-claude-code.ps1
```
```bash
bash scripts/install-for-claude-code.sh
```

### Antigravity CLI (`agy`)

Antigravity CLI 自身のグローバルスキルとして導入します。CLI 版もフォルダ + `SKILL.md` 方式(`.agents` と同じ構造)を受け付けます。ソースは `.agents/skills/` を流用します。

このスキル群の主な想定ホストは Claude Code / Codex です。Antigravity CLI 自身への導入は自己呼び出しになるため用途は限定的ですが、会話履歴を持たない新規インスタンスへの同一モデル並列レビュー(fresh-context セカンドオピニオン)や、`antigravity-implement` の独立検収ハーネスとして使えます。不要であれば導入しなくて構いません。

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\install-for-antigravity.ps1
```
```bash
bash scripts/install-for-antigravity.sh
```

各 installer は配置ルートを bash の第1引数、PowerShell の `-DestinationRoot` で上書きできます。管理対象の5 skillだけを retire-then-promote 方式で更新し、他の skill は削除しません。更新に失敗した場合は skill 単位で旧版への復元を試みます。アンインストールするには、配置先の `skills/` から管理対象5ディレクトリを手動で削除してください。`$USERPROFILE\.agents\add_antigravitycli\` の bundle 共有設定は残して構いません。

Antigravity CLI 側では `SKILL.md` の frontmatter のうち `disable-model-invocation` や `allowed-tools` の解釈が公式ドキュメントに明記されていません(参考: [Antigravity CLI Skills](https://antigravity.google/docs/cli/plugins))。動作は代表 1 ケースで確認してから運用してください。

Antigravity CLI が公式にサポートする Plugin 形式(`plugin.json` + `plugins/<name>/skills/`)でラップして `agy plugin install <path>` する経路もあります。単独スキル配布で足りない場合はこちらを検討してください。

### helperと設定ファイルの配置

各Skillは自身のディレクトリ直下の `scripts/` に必要helperを同梱しています。プロジェクト配置でもユーザー全体への導入でも、別途 `$USERPROFILE\scripts`、`$USERPROFILE\.agents\scripts`、`$USERPROFILE\.gemini\scripts` へコピーする必要はありません。

一方で、モデル既定値などのruntime/user configはSkillごとに分けません。`set-antigravity-model` で保存した値を他Skillからも読むため、既定では次のbundle共有ファイルを使います。

```text
$USERPROFILE\.agents\add_antigravitycli\antigravity-wrapper.conf
```

優先順位は `-Model` / `--model`、`ANTIGRAVITY_WRAPPER_MODEL`、`ANTIGRAVITY_WRAPPER_CONFIG` または上記config、Antigravity CLI既定の順です。

開発時はrepo直下 `scripts/` を正本として編集し、配布コピーは同期toolで更新します。

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File tools\sync-skill-scripts.ps1
powershell -ExecutionPolicy Bypass -NoProfile -File tools\sync-skill-scripts.ps1 -Check
```

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
- mediaは元ファイルを直接workspaceへ公開せず、wrapper所有の一時workspaceへcopyします。順序、元ファイル名、MIME、byte数をmanifest化します。
- ディレクトリ、symlink / reparse point、認識できない形式を拒否します。未検証形式を暗黙変換しません。
- helperの失敗sentinelとLLM回答を区別します。wrapper は `agy --output-format stream-json` を逐次解析して本文を到着順に出力し(tool の開始・完了は stderr の `ANTIGRAVITY: tool=...` 行)、headless で自動拒否された tool 権限(`denied_actions`)を `[ANTIGRAVITY_DENIED_ACTIONS]` 行で常に可視化します。応答が空で拒否がある場合は `[ANTIGRAVITY_WRAPPER_ERROR]` で失敗します。
- 実装委任前にclean treeとsnapshotを確認し、実行後はGit diffとテストを呼び出し元が独立検収します。agy 1.2.7 の非対話実行では agent がシェルコマンドを実行できないため、テストは呼び出し元が実行し、失敗ログを添えて同じセッションで再委任します（helper はセッションが記録した差分以外の変更があれば停止します）。
- 実装委任時の共通制約は `scripts/antigravity-implement-safety.txt` で管理します。
- Windows の `.cmd` / `.bat` dispatch では、`WorkDir` などの引数にcmd.exe特殊文字を含めないでください。該当する入力はfail-closedで拒否します。
- commit、push、PR作成、既存変更の破棄、権限拡大は自動実行しません。

## 複数media

画像に限定せず、認識可能な画像・音声・動画・PDFを順序付きで渡せます。PNG、JPEG、WAV、MP3、MP4は実CLI probe済みです。それ以外はunit testでstagingを確認した段階では`experimental`と表示し、形式別E2Eが完了するまで対応保証済みとは扱いません。

| 状態 | MIME |
|---|---|
| `probe-verified` | `image/png`, `image/jpeg`, `audio/wav`, `audio/mpeg`, `video/mp4` |
| `experimental` | GIF, WebP, BMP, TIFF, SVG, PDF, FLAC, OGG, MOV, WebM, AVI |

これは「任意バイナリ対応」ではありません。magic bytesまたはOSのmedia判定で認識でき、allowlistに含まれる通常ファイルだけを受け付けます。

Windowsでは絶対pathを1行1件で記載したUTF-8リストを使います。

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File scripts\antigravity-wrapper.ps1 `
    -Prompt "順番に比較して" -AttachmentList "C:\path\attachments.txt"
```

bashでは同じ`--attachment`を反復します。

```bash
bash scripts/antigravity-wrapper.sh --prompt "順番に比較して" \
  --attachment "/path/first.png" \
  --attachment "/path/second.wav" \
  --attachment "/path/third.mp4"
```

正常ワークロードの実測前に一律size capを設けていません。総byte数を実行前に表示し、利用者が送信量を判断できるようにします。

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

wrapper の応答が依頼と無関係に `--print-timeout` フラグの解説になる場合、bundle 内の wrapper が古い（`--print` を渡す旧版）状態です。installer を再実行して更新してください。

`[ANTIGRAVITY_WRAPPER_ERROR] agy produced no response because tool permissions were denied in headless mode.` と `[ANTIGRAVITY_DENIED_ACTIONS] ...` が出る場合、agent がシェルコマンド等の承認を要する tool を使おうとし、非対話実行のため自動拒否されています(agy 1.2.7 + `--sandbox` では Windows 上のシェルコマンドが該当します)。レビュー・質問用途では「tool を使わずコンテキストだけで答える」旨を指示に含めてください。実装委任でテスト実行やファイル複製が必要な場合の扱いは issue #17 を参照してください。

Bash 版 wrapper は JSON 解析に `python3`、`python`、`node`(逐次出力)、または `jq`(完了後にまとめて出力)を使います。いずれも無い環境では従来の text 出力に戻り、拒否検知は無効になります(stderr に警告)。

## 運用方針

個人開発・個人管理のプロジェクトです。利用・forkは歓迎しますが、issueやPRへの応答・取り込みは保証しません。脆弱性の報告は issue ではなく [SECURITY.md](SECURITY.md) の手順(GitHub Private Vulnerability Reporting)でお願いします。

## ライセンス

[MIT License](LICENSE)
