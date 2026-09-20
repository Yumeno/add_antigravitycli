# 作業記録 2026-09-20 — 画像生成物の取り込み helper(antigravity-artifact)

## 目的

Issue [#17](https://github.com/Yumeno/add_antigravitycli/issues/17) PR-B。agy 1.2.7 の headless では agent が生成画像をリポジトリへ複製できず、host が `ARTIFACT_PATH:` の報告を受けて自分で複製する必要がある(PR #18 で文書化)。agent の報告パスを信用せずに検証してから取り込む処理を helper に固定し、host の注意力頼みをやめる(Codex gpt-6-astra の助言: brain 配下の文字列一致だけでなく実体パスと link を検査、destination は host が決める、repo 外で検査してから配置、取り込み記録を残す)。

## 体制

- 設計・仕様書・文書・レビュー指揮・検証: Fable 5.1(メインループ)
- 実装(helper 両版、テスト、sync tool の対応表): Sonnet サブエージェント

## 設計

- `antigravity-artifact.{ps1,sh} import -Repo/-Source/-Destination [-Overwrite]`
- source: 実体パス(PowerShell は Win32 `GetFinalPathNameByHandle`、bash は `pwd -P`)が `~/.gemini/antigravity-cli/brain/` 配下(`ANTIGRAVITY_BRAIN_DIR` で上書き可、テスト用)の通常ファイル。link・空ファイル・範囲外は拒否
- 内容: magic bytes で PNG / JPEG のみ受理。寸法は PNG の IHDR、JPEG の SOF から読む(読めなければ拒否)。変換はしない(依存を増やさない)
- destination: repo 内(実体パス検査、親ディレクトリ必須・link 不可)、拡張子は内容と一致、既存は `-Overwrite` なしで拒否、`.git/` と保護対象(`.env`、鍵)は拒否
- 複製は同一ディレクトリの一時名に書いてから move、SHA-256 を照合
- 出力: `[ANTIGRAVITY_ARTIFACT_OK] type= width= height= bytes= sha256= source= destination=`
- sync tool の antigravity-implement 配布リストに追加

## レビュー Round 1(agy、仕様)と反映

- Major: (1) host が `.png` を指定して拡張子不一致で拒否されスタックする罠 → 文書と SKILL.md に「destination は `ARTIFACT_PATH` の実体拡張子に合わせ、PNG 化は取り込み後」を明記。(2) source が brain 配下なら別会話の画像でも通る → wrapper が agy の JSON から得る `conversation_id` を stderr に出し、helper の `-ConversationId`(必須)で `brain/<id>/` 直下に限定。agent の自己申告ではなく CLI 出力由来の ID を使う
- Minor: 親ディレクトリは host が事前作成(helper は作らない)と明記、SKILL.md の helper パス表記を同梱パスに、複数枚は 1 行 1 パスと規定
- Nit: JPEG の SOS(`FF DA`)到達で走査を打ち切るガード
- 事実確認(agy の回答): 生成物は常に `brain/<conversation-id>/` 直下の通常ファイルで JPEG か PNG。WebP 等は現行では出ない(UNSURE 付き)。link は作らない

## レビュー Round 1(Codex gpt-5.6-terra、コード・セキュリティ)と反映

- Major 6: (1) Bash の一時ファイル名 `$$-$RANDOM` が予測可能で symlink 先回りに弱い → `mktemp` + umask 077 で排他作成した通常ファイルへ書く、(2) 実体パス検証と read/copy/move が別操作で TOCTOU を防げない → 完全解決はハンドル保持のネイティブ helper が要るため、window を狭め(source は 1 回だけ読む、temp を hash して rename 直前に link 再検査)、脅威モデル「agent の誤った/敵対的なパス・link・非対応内容には防御するが、同一ユーザーの並行改変は非対応」をヘッダに明記、(3) 複製後に source を再ハッシュしており複製データを検証していない・失敗時に destination が残る → 読み込んだバイト列の hash を期待値にし temp の hash を照合してから rename、失敗時は temp を必ず削除、`-Overwrite` は rename でのみ置換、(4) PNG の IHDR 長・JPEG のセグメント長を検証せず壊れた画像を受理 → IHDR 長 13、全セグメント `len >= 2` かつファイル内、SOF `len == 8 + 3*Nf`、SOS/EOI 到達で打ち切り、SOF2 受理をテストで固定、(5) Bash の保護パス判定が大文字小文字を無視(`.GIT/` で迂回) → 小文字正規化して判定、(6) 巨大寸法を無制限受理 → 幅・高さ 8192 以下、総画素 6,400 万以下(正常ワークロード 1024〜1376px を根拠)
- Minor 2: 成功行のパスに改行があると 1 行形式が崩れる → CR/LF を含むパスは拒否し、`source=` / `destination=` を末尾固定。テストが安全境界を pin していない → SOF2・APPn・不正長・切り詰め・IHDR 長・巨大寸法・`.GIT`・temp 残留・CR 拒否のケースを追加
- Nit: 未使用の `$jpegSig` を削除

## 変更内容

- `scripts/antigravity-artifact.{ps1,sh}`: 新規(上記設計 + Round 1 反映: `-ConversationId` 必須、mktemp 排他作成、複製データの hash 照合、構造長検証、寸法上限、大文字小文字正規化、改行パス拒否、脅威モデル明記)
- `scripts/antigravity-wrapper.{ps1,sh}`: JSON の `conversation_id` を stderr に `ANTIGRAVITY: conversation_id=<id>` として出力(agent の申告ではなく CLI 出力由来の ID を host に渡す)
- `scripts/tests/test-artifact.{ps1,sh}`: 28 ケース(PNG / JPEG の取り込み、brain 外・別会話・不正 ID・入れ子・link・非画像・拡張子不一致・repo 外・既存(上書きなし/あり)・保護対象・`.git/` と `.GIT/`・親なし・寸法不能・SOF2 受理・APPn 越え受理・不正セグメント長・切り詰め・SOS 先行・IHDR 長不正・巨大/ゼロ寸法・temp 残留なし・改行パス拒否)。test-wrapper 両版に `conversation_id` の stderr 出力ケースを追加
- `tools/sync-skill-scripts.{ps1,sh}` と `scripts/tests/test-install-*.{ps1,sh}`: antigravity-implement の配布リストに 2 ファイルを追加
- `docs/references/image-generation.md` 2.2 / 3 / 5 節、SKILL.md 両版、README: host の受け取り手順を helper 前提に書き換え
- 全 skill 同梱 bundle を sync tool で再配布

## 検証

- unit: test-artifact.ps1 28/28、test-artifact.sh 28/28、test-wrapper.ps1 28/28、test-wrapper.sh 25/25、test-install 3 種(ps1 各 12/12、sh 各 7 PASS + 2 SKIP)、test-implement 両版、test-skill-bundles OK、sync -Check 同期済み。symlink 拒否の分岐は Windows で link を作れず PASS-skip(ロジックのみ)
- 実 agy 1.2.7 E2E: 紙飛行機アイコン(1:1)を生成させ `ARTIFACT_PATH:` を取得 → PowerShell 版 import で `type=jpeg width=1024 height=1024 bytes=329028` と SHA-256 付きの OK、`.png` 指定は拡張子不一致で拒否、既存への再取り込みは `-Overwrite` なしで拒否 → Bash 版 import も同じ SHA-256 で OK、brain 外の source は拒否。3 ファイル(source と両複製)の SHA-256 一致、目視 OK
- Round 1 反映後の再 E2E: 灯台アイコンを生成 → wrapper の stderr `ANTIGRAVITY: conversation_id=...` を host が控える → その ID で PowerShell / Bash 両 helper の import が OK(同じ SHA-256)、別の ID を渡すと拒否
