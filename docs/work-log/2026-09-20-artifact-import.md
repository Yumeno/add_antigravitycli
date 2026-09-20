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

## 変更内容

- `scripts/antigravity-artifact.{ps1,sh}`: 新規(上記設計)
- `scripts/tests/test-artifact.{ps1,sh}`: 13 ケース(PNG / JPEG の取り込み、brain 外・link・非画像・拡張子不一致・repo 外・既存(上書きなし/あり)・保護対象・`.git/` 配下・親なし・寸法不能の拒否)
- `tools/sync-skill-scripts.{ps1,sh}` と `scripts/tests/test-install-*.{ps1,sh}`: antigravity-implement の配布リストに 2 ファイルを追加
- `docs/references/image-generation.md` 2.2 / 3 / 5 節、SKILL.md 両版、README: host の受け取り手順を helper 前提に書き換え
- 全 skill 同梱 bundle を sync tool で再配布

## 検証

- unit: test-artifact.ps1 13/13、test-artifact.sh 13/13、test-install 3 種(ps1 各 12/12、sh 各 7 PASS + 2 SKIP)、test-implement 両版、test-skill-bundles OK、sync -Check 同期済み。symlink 拒否の分岐は Windows で link を作れず PASS-skip(ロジックのみ)
- 実 agy 1.2.7 E2E: 紙飛行機アイコン(1:1)を生成させ `ARTIFACT_PATH:` を取得 → PowerShell 版 import で `type=jpeg width=1024 height=1024 bytes=329028` と SHA-256 付きの OK、`.png` 指定は拡張子不一致で拒否、既存への再取り込みは `-Overwrite` なしで拒否 → Bash 版 import も同じ SHA-256 で OK、brain 外の source は拒否。3 ファイル(source と両複製)の SHA-256 一致、目視 OK
