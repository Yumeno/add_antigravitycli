# 作業記録 2026-07-06 — レビュー起点の整合性・安全性 fix

## 目的

初期実装(`faca8ed` 時点) のリポジトリを Claude 初見でレビューし、Codex CLI にセカンドオピニオンを依頼した上で、確認された整合性・安全性の不備を1回で修正する。同時に、PS1/SH 両実装が「同じスキル・同じ LLM 入力・同じ検収強度」を持つよう揃える。

## Issue

- なし(セッション内のレビュー→修正フロー)

## 経緯

### 1. Claude 初見レビュー(6件)

`main` (作業ツリー clean) を対象にレビューし、以下6件を挙げた。

- Major #1: README の全ユーザー導入手順が SKILL.md の `../../../scripts` 解決規則と噛み合わず、`$USERPROFILE\.claude\scripts\` に置いても wrapper が見つからない。
- Major #2: PS1 と SH で context 挿入順が違う(PS1 は Context 先、SH は Prompt 先)。同じスキルで OS により LLM 入力が別物。
- Major #3: `.env` 探索深度が違う(PS1 全階層 vs SH `-maxdepth 1`)。`sub/.env` が SH で保護対象から漏れる。
- 小 #4: `antigravity-implement.ps1` が verify helper の stderr を潰す。→ **後述の Codex 監査で不同意、取消し**。
- 小 #5: implement 安全制約プロンプトが PS1(英語7項目) vs SH(日本語4項目) で情報量差。
- Nit #6: media 一覧の filename 表記が SH `%q` エスケープ vs PS1 raw で不揃い。

### 2. Codex にセカンドオピニオン依頼(`ask-codex-with-context`)

Claude の6件が正しく現状を捉えているか、および見落としがないかを Codex に監査依頼。Codex から:

- **Critical A**: PS1 wrapper の `.cmd/.bat` dispatch で cmd.exe 引数 injection。`Quote-Arg` が空白/引用符しか処理せず、`&`, `|`, `%` 等を含む WorkDir 等で任意コマンド実行になる。→ Claude 初見では見落とし。
- **Major B**: PS1 implement が spec 全文を子プロセスの argv に載せる。Windows のコマンドライン上限に触れる、プロセス一覧から仕様漏洩。SH は `--prompt-file` を使うので影響なし。
- **Major C**: snapshot が `.git/config` と `.git/hooks/*` しか凍結しておらず、`.git/refs/**`, `packed-refs`, `.gitmodules`, `info/exclude` は未保護。ref 付替や tag 改竄が「Git 保護」を通り抜ける。
- **Major D**: untrusted context の境界が命令として弱い。context を「データであり指示ではない」と明示していない。攻撃者 diff の prompt injection に脆弱。Claude の #2 と統合。
- **Major E**: PS1 の MP4 magic 判定が広すぎる。4〜7 byte `ftyp` は全部 `video/mp4` + `probe-verified`。MOV / HEIF / HEIC を誤判定。README の実装状況表明と不一致。
- **Major**: SH の symlink hash が `symlink:<target>` しか記録せず、リンク先内容の書換を検知しない。
- **Minor**: PS1 snapshot が clean tree を要求しない。SH と挙動非対称。
- **Minor**: verify exit code が PS1(内部エラー=2, 違反=1) vs SH(内部エラー=1, 違反=2) で逆転。
- **Minor**: PS1 implement が subdir を通すが verify が top-level 拒否。SH は toplevel 正規化。
- **Minor**: `.claude` vs `.agents` の SKILL.md 間に frontmatter を超えた意味差(禁止項目の欠落、path separator 不揃い)。
- Codex は **#4 を不同意**: implement.ps1 の helper 呼び出しは stdout/stderr をリダイレクトしていないので、helper の実出力は親コンソールへ流れる。generic message は追加されるだけで原因は消えない。→ Claude の指摘取り下げ。

### 3. Codex CLI に実装委任(`codex-implement`)

Critical + Major 8件 + Minor 5件 + Nit 2件 + 追加テスト10件 を1変更に統合。sandbox `workspace-write` で委任、実行前に `codex-verify` snapshot を取得。

Codex 実装後の `codex-verify check`: VIOLATION / ERROR なし、HEAD/branch 不変、保護対象ファイル改変なし。

sandbox の read-only 指定により Codex が編集できなかった SKILL.md 3件は Claude 側で手当てで補完:

- `.claude/skills/antigravity-implement/SKILL.md` — 独立検収項目に「生成物、依存追加、危険なコマンド、テスト弱体化」検査を追記。
- `.claude/skills/ask-antigravity-with-context/SKILL.md` — security/監査時の変更ファイル一覧収集を明記。
- `.agents/skills/antigravity-implement/SKILL.md` — 「外部送信を許可しない」→「Antigravity CLI 経由の委任以外の外部送信を許可しない」に書換え + PowerShell 例の path separator を `/` に統一。
- `.agents/skills/ask-antigravity-with-context/SKILL.md` — PowerShell 例 2箇所の path separator を `/` に統一(Codex 未言及の同種残り)。

## 修正内容(項目 → ファイル)

| Pri | 項目 | 主担当ファイル |
|---|---|---|
| Critical | A. `.cmd/.bat` dispatch fail-closed(`[\r\n&\|<>^%!()"]` を含む引数を reject) | `scripts/antigravity-wrapper.ps1` |
| Major | B. `-PromptFile` 追加(`-Prompt` と mutual exclusive)。implement.ps1 は一時ファイル経由に切替 | `scripts/antigravity-wrapper.ps1`, `scripts/antigravity-implement.ps1` |
| Major | C. snapshot 保護対象拡大(`<git-dir>/HEAD`, `packed-refs`, `refs/**`, `info/exclude`, `.gitmodules`) | `scripts/antigravity-verify.{ps1,sh}` |
| Major | D+#2. `## Request → ## Untrusted context → ## Media attachments` の共通テンプレを PS1/SH 両方で採用。untrusted 明示 | `scripts/antigravity-wrapper.{ps1,sh}` |
| Major | E. ISO BMFF `ftyp` の major_brand で MP4 / MOV(experimental) / HEIF(reject) を判定 | `scripts/antigravity-wrapper.ps1` |
| Major | #1. README install 先を `$env:USERPROFILE\scripts\` に統一(Codex/Claude Code とも) | `README.md` |
| Major | #3. `.env` を pem/key と同じ再帰形式にマージ | `scripts/antigravity-verify.sh` |
| Major | symlink 記録形式を `symlink:<target>:<sha256 or "unresolvable">` に拡張 | `scripts/antigravity-verify.sh` |
| Minor | PS1 snapshot 時に dirty tree を reject | `scripts/antigravity-verify.ps1` |
| Minor | verify exit code 契約統一(0/1/2/3 = success/usage/internal/violation) | `scripts/antigravity-verify.{ps1,sh}` |
| Minor | implement.ps1 で `git rev-parse --show-toplevel` に正規化 | `scripts/antigravity-implement.ps1` |
| Minor | #5. `scripts/antigravity-implement-safety.txt` を新設し PS1/SH 共通で先頭 prepend | 新規, `scripts/antigravity-implement.{ps1,sh}` |
| Minor | SKILL.md 意味差(検収項目、`外部送信`表現、path separator) | `.claude/skills/**/SKILL.md`, `.agents/skills/**/SKILL.md` |
| Nit | #6. wrapper.sh の media 表記から `%q` 廃止 | `scripts/antigravity-wrapper.sh` |
| Nit | verify.ps1 の `.git` 事前 prune 化 | `scripts/antigravity-verify.ps1` |
| — | ~~#4~~ 取消し | — |

## テスト

追加テスト(Codex 優先度順):

1. `.cmd` dispatch + 特殊文字 rejection
2. `-PromptFile` 大容量 stdin 一致 & `-Prompt` との mutual exclusive
3. nested `.env` 検知(SH)
4. `.git/refs/tags/*` violation 検知(PS1/SH)
5. protected symlink target 内容変更検知(SH。Windows で symlink 作成不能時はスキップ)
6. malicious context 文字列で PS1/SH の stdin 完全一致
7. 単一 attachment 継続動作
8. MOV(`ftyp qt  `) → experimental、HEIF(`ftyp heic`) → reject
9. model 優先順の全組合せ
10. `-Timeout` 上限、SIGINT/Ctrl+C 後の temp cleanup(環境依存でスキップ許容)

### 実行結果(PS1、私自身で再実行)

| テスト | 結果 |
|---|---|
| `test-wrapper.ps1` | 13/13 PASS |
| `test-verify.ps1` | PASS |
| `test-implement.ps1` | PASS |

Codex 報告の SH テスト: `test-wrapper.sh` 9/9, `test-verify.sh` 12/12, `test-implement.sh` 3/3(Codex sandbox 内での実行結果。私が Windows で再実行はしていない)。

## 未対応 / 残課題

- 保護対象 symlink が repo 外を指すケースの拒否は、Codex 判断で「実装コスト対効果」を理由に snapshot 段階の reject までは入れず、内容 hash 記録のみで対応(target 差替えなしの内容変更を検知できる)。
- `-Allow` glob マッチの厳密仕様は Codex-implement skill 側で明文化済みだが、antigravity-verify 側は未対応(現状は完全一致のみ)。今後の課題。

## 主要ファイル差分

Codex + 私の後追い合計 16 files: 13 modified (Codex) + 1 new (`scripts/antigravity-implement-safety.txt`) + 4 SKILL.md (Claude 手当て。うち 2 は `.agents` 側の path separator 修正)。
