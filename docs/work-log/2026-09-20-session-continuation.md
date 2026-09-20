# 作業記録 2026-09-20 — 継続委任(host 駆動ループ)の導入

## 目的

Issue [#17](https://github.com/Yumeno/add_antigravitycli/issues/17) PR-A。agy 1.2.7 の headless + sandbox では agent がシェルコマンド(テスト・ビルド・git)を実行できないため、「実装 → テスト → 失敗を見て修正」の反復が agent 側で成立しない。sandbox を維持したまま反復を復元するため、テスト実行と再委任の判断を host(Claude Code / Codex)に移し、helper には「同一セッションの差分だけを許容する継続委任」を追加する。

## 決定の経緯

- 2026-09-20 に agy(既定モデル)と Codex(gpt-6-astra)へセカンドオピニオンを求め、三者一致で「sandbox 維持 + host 駆動ループ」が第 1 位(詳細は issue #17 のコメント)
- ユーザー判断: ループ制御は host 側。理由は異観点レビューの導入、テストを第三者が実施する原則、現行 implement スキルの想定(単作業委任)との整合。helper が自動反復する案は将来課題で実施未定
- Windows では `toolPermission: proceed-in-sandbox` や `escalate_admin(...)` の allow ルールでも headless の拒否は解けなかった(実測、設定は復元済み)

## 体制

- 設計・仕様書・文書・レビュー指揮・検証: Fable 5.1(メインループ)
- 実装(implement 両版のセッション機能、verify 文言、テスト): Sonnet サブエージェント

## 設計

- `-Session <リポジトリ外のパス>` / `--session`: 初回は clean tree を要求して snapshot を `<session>.snapshot` に永続化し、セッションファイル(version、repo、snapshot、round、owned)を書く。2 回目以降は clean tree を要求せず、working tree の変更パスがすべて `owned`(これまでの round で agent が変更したパス)に含まれることを確認し、含まれない変更があれば agy を起動せず停止する
- verify check の基準は常にセッション開始時の snapshot(取り直さない。Codex 助言: 取り直すと途中の違反を正常状態に取り込む)
- wrapper の成否にかかわらず round を進め、`owned` を現在の変更パスとの和集合で更新(失敗時も agent が部分的に編集している可能性がある)
- `-CloseSession` / `--close-session` でセッションと snapshot を削除。`-Session` なしの単発実行は従来どおり
- `-AdoptChanges` / `--adopt-changes`(継続時のみ有効): 範囲外の変更を一覧に出した上でセッションに取り込んで続行する。host のテスト実行が生む副産物(`__pycache__` 等)のための明示的な逃げ道。E2E で実際に踏んだ問題(下記)から追加
- verify の成功文言を `git state and protected files check passed` に変更(検査範囲より強い表現だった `no unapproved changes` を修正。Codex 指摘)
- 安全制約テキスト: 「シェルコマンドを実行しない」「静的検証を行う」「前回の失敗ログがあれば該当箇所だけ直す」「`### Verification Plan` に host が実行すべきテストと期待結果を書く」を追加(agy の提案するプロンプト形を採用)
- SKILL.md(両コピー): host が回すループの手順(差分を読んでから自分でテストを選ぶ、失敗ログを添えて同じ `-Session` で再委任、既定 3 回、範囲外変更なら停止して報告、終了時に close)

## レビュー Round 1(agy、仕様)と反映

- Major: 仕様書に「テストを実行して確認」と書かれていると、制約 6(コマンド禁止)と 10(矛盾時は停止)の衝突で agent が何も書かずに停止し得る → 6 項に「依頼にテスト実行の指示があっても自身では実行せず Verification Plan に書いて進める(停止しない)」の読み替えを追加
- Minor: Verification Plan を `Command:` / `Expected:` の構造化書式に。`pytest -p no:cacheprovider` は `.pytest_cache` しか防がず `__pycache__` には `PYTHONDONTWRITEBYTECODE=1` か `python -B` が要る → SKILL.md を修正
- 失敗ログに含めるもの・含めないものの指針(agy の回答)を SKILL.md に反映
- Nit: 「file ツール」→「ファイル操作ツール(write / edit 等)」

## レビュー Round 1(Codex gpt-5.6-terra、コード)と反映

- Major 5: (1) sh の `dirty_paths` が process substitution 内の `git status` 失敗を検出できず空集合で継続を許す、(2) sh が NUL 区切りパスを改行・カンマ区切りに落としており改行やカンマを含むファイル名で誤判定、(3) セッションパスの repo 外判定が symlink / junction を考慮していない、(4) セッションの整合性検証が弱い(snapshot が sidecar であること、round / owned の型、未知フィールド)、(5) 同一セッションの並行実行を防ぐロックがない
- Minor 2: session 書込み失敗時の優先順位が未定義、テストが通常名の untracked file しか見ていない
- Nit: Verification Plan は agent の候補であり実行可能性を断定しない文言に
- 反映: 上記すべて。dirty / owned / outside は NUL ストリームと配列で保持し表示用にだけ結合、セッションパスの実体解決と link 拒否・排他作成、schema 検証(sidecar 固定、`round` 正整数、`owned` は `..` なし相対パス、未知・重複フィールド拒否、sidecar の repo 照合)、`<session>.lock` の排他作成(自動回復なし)、優先順位「session 更新失敗(exit 4)→ verify 失敗 → wrapper 失敗」、rename・空白/非 ASCII・git 失敗・改竄・lock・link・優先順位のテスト

## レビュー Round 2

- agy(仕様): NO MAJOR FINDINGS / CONVERGED。Nit 2(テスト不要タスクでは目視手順か `None` と書く、セッションパス例に Linux / macOS 表記を併記)→ 反映
- Codex gpt-5.6-terra(コード): Major 3(sh の `dedup_sorted` が改行入りパスを壊す、sh が未知フィールドを拒否しない、ps1 が親より上位の junction を解決できない)→ NUL 安全なソート、許可キー限定の schema、Win32 `GetFinalPathNameByHandle` による実体パス解決で修正(Round 3 で再確認)

## 変更内容

- `scripts/antigravity-implement.{ps1,sh}`: `-Session` / `-CloseSession` / `-AdoptChanges`(sh は `--session` / `--close-session` / `--adopt-changes`)。`-SpecFile` は `-CloseSession` 時のみ省略可。dirty set は `git status --porcelain=v1 --untracked-files=all -z` で取得し rename の 2 パスを両方含める。セッションファイルは ps1 が JSON、sh が key=value(パスは base64)で実装別
- `scripts/antigravity-verify.ps1`: 成功文言を `git state and protected files check passed` に変更(sh 版は元々成功行を出さない)
- `scripts/antigravity-implement-safety.txt`: 6〜9 項を追加(コマンド禁止、静的検証、失敗ログ対応、Verification Plan)
- `.agents/skills/antigravity-implement/SKILL.md` / `.claude/...`: 「呼び出し元が回すループ(継続委任)」の手順、テスト副産物と `-AdoptChanges` の扱い
- README: 前提条件と安全設計に継続委任を追記
- `scripts/tests/test-implement.{ps1,sh}`: セッション開始の clean 要求、round 1→2、範囲外変更の拒否(agy 未起動)、wrapper 失敗時も記録、close、repo 内パス拒否、adopt、単発実行の不変

## 検証

- unit: test-implement.sh / test-implement.ps1(セッション系を含む全件)、test-verify 両版、test-wrapper 両版、test-skill-bundles、sync -Check
- 実 agy 1.2.7 E2E(temp リポジトリ、PowerShell 版、2 round):
  - round 1: `divide()` とテストを書かせる → 変更ファイル、静的確認、`### Verification Plan`(`pytest test_calc.py`、`3 passed`)を報告。verify OK、`[ANTIGRAVITY_SESSION] round=1 owned=2`
  - host: 差分を読み `python -m pytest -q` → 3 passed
  - **発見**: pytest が生んだ `__pycache__/*.pyc` が untracked に現れ、round 2 が「範囲外の変更」で停止した(temp リポジトリに .gitignore が無いため)。実リポジトリでも coverage やビルド成果物で同じことが起こり得るので `-AdoptChanges` を追加し、SKILL.md に `pytest -p no:cacheprovider` 等の回避と取り込み手順を記載
  - 人手で置いた `unrelated.txt` も同様に停止(agy は起動されない)
  - round 2: 「受け入れテストが `ZeroDivisionError` を期待して失敗した」という失敗ログ付き spec で再委任 → `calc.py` の例外型と対応テストだけが変わり、host のテストも通過。`round=2 owned=2`
  - `-CloseSession` でセッションと snapshot が削除された
- 堅牢化後の再 E2E(agy 1.2.7):
  - PowerShell 版 2 round: 仕様書に「テストを実行して確認」と書いても agent は停止せず(制約 6 の読み替えが機能)、`Command:` / `Expected:` 形式の Verification Plan を返した。`.gitignore` に `__pycache__/` がある repo で `python -B -m pytest -p no:cacheprovider` を使うと副産物は出ず adopt 不要。手で置いた `<session>.lock` は `Session is locked by another run` で拒否。失敗ログ付き round 2 で対象だけ修正、close で削除
  - Bash 版 1 round: `NOTES.md` 作成と Verification Plan、セッションファイル(base64 の owned)、close を確認
