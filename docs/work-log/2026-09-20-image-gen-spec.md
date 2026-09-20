# 作業記録 2026-09-20 — 画像生成リファレンスを agy 1.2.7 の確定仕様に改訂

## 目的

Issue [#12](https://github.com/Yumeno/add_antigravitycli/issues/12) の対応。`docs/references/image-generation.md` の 2.4 節「未確認の上限値」を、アスペクト比・参照画像上限・UI デバイスフレーム除外の確定仕様に改訂する。数値は issue 起票者の申告を鵜呑みにせず、一次情報(agy のツール定義)と実機試打で裏取りしてから書いた。

## 一次情報の取得

agy 1.2.7 を print mode(tool 不使用を明示)で呼び、内部ツール `generate_image` の定義を自己申告させた:

- パラメータ: `Prompt`(必須)、`ImageName`(必須、snake_case 3 語以内)、`AspectRatio`(任意、既定 `1:1`、選択肢 `1:1` `2:3` `3:2` `3:4` `4:3` `9:16` `16:9`)、`ImagePaths`(任意、最大 3 件)、`toolAction` / `toolSummary`(必須、UI 表示用)
- 説明文に「UI 生成時はユーザーが明示しない限りデバイスフレームを描かない」の既定あり
- サイズ・寸法上限の数値は定義に無し(バックエンド側は不明)

文書では信頼度 `[ツール定義]` として区別(公式ドキュメントではない)。

## 実機試打(agy 1.2.7、各系統 1 件、temp git リポジトリ)

| # | 内容 | 結果 |
|---|---|---|
| B | 参照画像 4 枚を指定した編集 | ツール呼び出しが `invalid tool call error (invalid_signature) cannot provide more than 3 image paths` で失敗。agent は指示どおり黙って落とさず verbatim 報告。**上限 3 枚を確定** |
| A | 16:9 生成 + 指定絶対パスへ PNG 保存 + 寸法報告(wrapper 経由) | **空応答**(`agy returned empty output`)。直接呼びの stderr で「`command` 権限が headless で自動拒否」と判明。会話 DB から、agent は `powershell -Command` + System.Drawing で JPG→PNG 変換して保存しようとしていた |
| A2 | 同上、コマンド禁止・寸法報告なし | 生成成功。保存先は `~/.gemini/antigravity-cli/brain/<conversation-id>/wide_probe_<ms>.jpg`(1376×768 = 16:9)。指定パスには書かれない |
| A3 | 4:3 生成 + `Copy-Item` 1 発だけで JPG 複製 | `Copy-Item` も `command` 権限で自動拒否 → 空応答。settings.json の allow に `command(Copy-Item)` があっても通らない |
| C1 | headless + `--sandbox` で allow 済み `git status` | `escalate_admin` 権限要求で自動拒否 → 空応答 |
| C2 | headless、`--sandbox` なしで同じ | 実行され、出力が返った |
| A4 | wrapper 経由、9:16 生成、「複製・変換・コマンド禁止、`ARTIFACT_PATH:` 等を報告」の推奨指示形 | `ARTIFACT_PATH` / `IMAGE_NAME: forest_waterfall` / `ASPECT_RATIO: 9:16` を報告。768×1376。目視 OK(16:9 の灯台も目視 OK) |

## 判明した仕様変更(1.1.1 → 1.2.7)

- 生成物の置き場が `scratch/` から `brain/<conversation-id>/` に変わり、JPEG で保存される
- **headless + `--sandbox`(wrapper 既定)では、実測した `Copy-Item`、`powershell -Command`、`git status` はすべて自動拒否された**。7 月は同条件で .NET 変換と指定パス保存が通っていたので、headless の権限処理が厳格化した(changelog に直接の記述は見つからず。1.1.27 の denied_actions 通知、1.2.2 の `unsandboxed` ルール廃止が周辺変更)
- 結果として「仕様書にリポジトリ内の絶対パスを書けば agent が保存する」という 7 月の主要知見は headless では成立しない。推奨は「agent は複製せず `ARTIFACT_PATH:` を報告 → host が複製・変換 → 検収」

## 変更内容

- `docs/references/image-generation.md` — 全面改訂。2.1 にアスペクト比・デバイスフレーム除外、2.2 を「保存先と受け取り方」に書き換え(1.2.7 の権限制約と推奨指示形、1.1.1 時点の挙動は参考として残置)、2.3 に参照 3 枚上限、2.4 をツール定義表に、3 節に JPEG の magic bytes と寸法確認、4 節に headless 権限と空応答の症状を追記
- `.agents/skills/antigravity-implement/SKILL.md` / `.claude/skills/antigravity-implement/SKILL.md` — 要点抜粋を同期(保存先の扱い、アスペクト比、3 枚上限)
- bundle の `references/image-generation.md` を sync tool で再配布

## 検証

- `sync-skill-scripts.ps1 -Check` 同期済み、`test-skill-bundles.ps1` OK
- レビュー: agy(仕様)Round 1 で Minor 1・Nit 1(「一切実行できない」の過大表現、`toolAction`/`toolSummary` 注記)、Codex gpt-5.6-terra(文書整合)Round 1 で Major 2・Minor 1(推奨フローが helper の検収順序と矛盾、証拠ラベル不足、7 月の identity preservation 実測の欠落)→ いずれも反映
- 試打生成物(temp リポジトリ、brain 内 JPEG 4 枚)は検証後に削除

## 残課題(別 issue)

- issue #17 として起票。`antigravity-implement` の画像フローは、agent 保存 → Git 検収の前提が 1.2.7 で崩れている。host 側の複製ステップを skill 手順に組み込むか、wrapper に非 sandbox の画像モードを設けるかは設計判断が要る
