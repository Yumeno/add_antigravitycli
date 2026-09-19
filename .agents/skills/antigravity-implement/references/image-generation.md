# Antigravity CLI での画像生成・編集

このファイルが正本(SSoT)。skill 同梱コピー(`.agents/skills/antigravity-implement/references/` と `.claude/skills/antigravity-implement/references/`)は `tools/sync-skill-scripts` が配布する。同梱コピーを直接編集しない。

- 調査日: 2026-07-10(初版、agy 1.1.1)/ 2026-09-20(改訂、agy 1.2.7)。いずれも Windows 11
- 信頼度表記: `[実測]` = 本リポジトリの実テストで確認 / `[ツール定義]` = agy 1.2.7 に print mode で自身の内部ツール定義を出力させて確認(公式ドキュメントではない) / `[公式]` = Google 公式ドキュメントで確認 / `[推定]` = 実測からの推定(裏取りなし)
- 上流 CLI は自動更新され、1.1.1 → 1.2.7 の間に保存先と権限の挙動が変わった(2.2 節・4 節)。バージョン違いの記述はその旨を明記する

## 1. Antigravity CLI での画像生成の仕組み

- 自然文で画像生成を指示すると、agy の内部ツール `generate_image` が自動で発動する [ツール定義]。生成モデル名は応答にもログにも出ない(agent は「画像生成ツール」としか言わない)[実測]。**モデル名を報告させない・推測で書かない**(テキスト回答のモデル名フッター規則と同じ原則)。
- 生成物は **agy 管理下の会話別ディレクトリ** `~/.gemini/antigravity-cli/brain/<conversation-id>/<ImageName>_<unix ms>.jpg` に JPEG で保存される(1.2.7 実測。1.1.1 時点は `scratch/` 配下だった)[実測]。
- 実測寸法: 1:1 = 1024×1024(1.1.1)、16:9 = 1376×768、9:16 = 768×1376(1.2.7)。ファイルサイズは 400KB〜1MB 程度 [実測]。
- プロンプトの構造化(構図・照明・スタイルの詳細化)は agent が自動で行う。仕様書には要件だけ書けばよい [実測]。
- ツール定義の説明文に「**UI デザイン生成時は、ユーザーが明示しない限りデバイスフレーム(ノート PC・スマートフォン・タブレット)を描かず、インターフェースそのものだけを生成する**」と書かれている [ツール定義]。

## 2. 仕様書(タスク指示)の書き方

### 2.1 生成タスクの必須項目

1. **ファイル名と形式**(例: `assets/hero.png`)。内部ツールの `ImageName` は snake_case・3 語以内に正規化される(例: `forest_waterfall`)ので、リポジトリ内の最終ファイル名は host 側で付け直す前提でよい [ツール定義][実測]
2. **保存先**(次節参照。1.2.7 では agent に直接書かせない)
3. **被写体・内容**
4. **アスペクト比**: `1:1`(既定)、`16:9`、`9:16`、`4:3`、`3:4`、`3:2`、`2:3` の 7 種 [ツール定義]。仕様書に「アスペクト比: 16:9」と書けば agent が `AspectRatio` 引数に渡す(16:9 / 9:16 / 4:3 で実測)[実測]。未指定は 1:1 になる [ツール定義: 既定値]
5. **スタイル**(例: フラットデザイン、水彩、写真調)
6. **避けたい要素**。UI アセットでは「デバイスフレーム(スマホ・PC の外枠やベゼル)を含めず UI 画面のみ」を明記する。ツール定義にも同趣旨の既定があるが、仕様書で重ねて指定して確実にする [ツール定義]

### 2.2 保存先と受け取り方(最重要)

**agy 1.2.7 + wrapper 既定(headless + `--sandbox`)では、agent のシェルコマンドは実測した範囲ですべて自動拒否された**(生成物のある `brain/` からの複製・変換だけでなく、workspace 内の `git status` も。権限要求を headless では承認できないため。4 節)。`generate_image` 自体は動くが、生成物を指定パスへ複製・変換する段階(agent は `Copy-Item` や `powershell -Command` + System.Drawing を使おうとする)で拒否され、**結果は「stdout 空・exit 0」**になり wrapper は `[ANTIGRAVITY_WRAPPER_ERROR] agy returned empty output.` を返す [実測]。

推奨する指示形(agy 1.2.7、wrapper 経由 1 件で確認 [実測]):

```
Do NOT copy, move or convert the generated file and do NOT run any shell commands.
When done, report on separate lines:
ARTIFACT_PATH: <absolute path of the generated file>
IMAGE_NAME: <the ImageName value you passed to the image tool>
ASPECT_RATIO: <the AspectRatio value you passed>
```

- 上記 1 件では agent は `ARTIFACT_PATH: C:\Users\<user>\.gemini\antigravity-cli\brain\<conversation-id>\<ImageName>_<ms>.jpg` の形で報告した [実測: 1.2.7、1 件]。複数枚や編集タスクでも同じ形で返るかは未検証 [推定]
- **`antigravity-implement` の helper は wrapper 終了直後に antigravity-verify の check を走らせる**。agent はリポジトリ内に何も書かないので、この自動検収は「変更なし」で通り、生成物の検収にはならない。生成物の受け取りと実体確認は **helper 終了後に host が別途行う**(helper 側の対応は issue 化、5 節):
  1. wrapper 出力から `ARTIFACT_PATH:` 行を取り出す。パスが `~/.gemini/antigravity-cli/brain/` 配下であることを確認してから扱う(それ以外のパスは agent の報告を信用せず停止)
  2. host の通常のファイル操作でリポジトリ内へ複製し、必要なら PNG へ変換する(agy の権限とは無関係なので拒否されない [推定: host 側の通常操作。複製自体は本リポジトリでは未試験、Read での読み取りは実測済み])
  3. 3 節の実体確認(magic bytes・寸法・バイト数・目視)を複製後のファイルに対して行う
  4. `git status` で複製したファイルだけが untracked に現れることを確認する(agent 由来の変更が無いことは helper の自動検収で確認済み)
- 1.1.1 時点の挙動(参考): 仕様書にリポジトリ内の絶対パスを書けば agent が sandbox + `--add-dir` 下で直接書き込めた [実測: 2026-07-10]。相対・曖昧な指定は scratch に落ちた。1.2.7 ではこの経路は headless では使えない

### 2.3 編集タスクの指示形

- リファレンス画像は**絶対パスをプロンプトに書くだけでよい**。wrapper の `-Attachment` / `--attachment` は不要(それらは VLM に「見せる」ための staging 経路。編集の入力参照はパス直書きで機能する)[実測: 1.1.1]。
- **参照画像は最大 3 枚**。内部ツールの `ImagePaths` の上限で、4 枚渡すとツール呼び出し自体が `invalid tool call error (invalid_signature) cannot provide more than 3 image paths` で失敗する [ツール定義][実測: 1.2.7]。ベース画像・スタイル参照・被写体参照など 3 点以内に絞る。agent が黙って 1 枚落とすことがないよう、仕様書に「4 枚以上は指定しない」を書く側で守る
- **Change + Preserve の定式**が有効:
  - Change: 変更点を限定列挙する(「次の3点だけを変更」)
  - Preserve: 維持する項目を具体的に列挙する(「シルエットの形・ポーズ・位置、構図、スタイルは維持」)
  - agy 1.1.1 の 1 件では、3 点変更 + 維持列挙の指示で被写体の形状・構図・スタイルを保ったまま指定箇所だけが変わった(identity preservation 良好)[実測: 1.1.1]。1.2.7 での再検証は未実施
- 反復編集する場合、Preserve リストは**毎回再掲する**(前ターンの制約の自動継承を期待しない)[推定: 姉妹リポジトリ add_codexcli の公式裏付け知見からの横展開]。
- 編集結果の受け取りも 2.2 と同じ(ARTIFACT_PATH を報告させて host が複製)。

### 2.4 ツール定義から確認できた仕様と制約 [ツール定義]

| 項目 | 値 |
|---|---|
| ツール名 | `generate_image` |
| `Prompt` | 必須。生成内容または編集指示 |
| `ImageName` | 必須。snake_case、3 語以内 |
| `AspectRatio` | 任意。`1:1`(既定)、`2:3`、`3:2`、`3:4`、`4:3`、`9:16`、`16:9` |
| `ImagePaths` | 任意。参照画像の絶対パス配列、**最大 3 件** |
| 出力形式 | JPEG [実測: 1.2.7、生成 4 件すべて]。PNG が必要なら host 側で変換 |

ツールスキーマ上の必須項目には他に UI 表示用メタデータ(`toolAction`、`toolSummary`)があるが、agent が自動生成するため仕様書での指示は不要。

未確認のもの: 1 枚あたりの参照画像サイズ上限、プロンプト長上限、透明背景(アルファチャンネル)。ツール定義にはこれらの数値がなく、バックエンド側の上限は不明。姉妹リポジトリ add_codexcli の数値(16枚 / 50MB / 32,000 文字 / 透明非対応)は **GPT-Image-2 固有であり流用しない**こと。JPEG 出力である以上、透明背景は少なくとも生成物としては得られない [実測からの推定]。

## 3. 検収(antigravity-verify との関係)

- 1.2.7 の推奨経路(2.2)では生成物は agent がリポジトリ外に置き、host が複製する。**Git 検収は host の複製後に行う**。検収は「期待値照合型」ではなく「差分検出型(snapshot 比較)」なので、枚数・ファイル名が事前不明でも機能する [実測]。
- 実体確認は **magic bytes**(PNG は先頭 8 バイト `89 50 4E 47 0D 0A 1A 0A`、JPEG は `FF D8 FF`)+ **寸法**(JPEG は SOF セグメント、PNG は IHDR から読む)+ **バイト数** + **目視**。
  - 実測の正常生成は 1024〜1376px 級で約 400KB〜1MB。**数十 KB 未満なら placeholder を疑う**。
  - 寸法比がアスペクト比指定と一致することを確認する(16:9 指定 → 1376×768 など)。
  - 目視を省かない。応答の「生成しました」報告と画像の実内容は別物として扱う。

## 4. 既知の注意点

- **headless の権限(1.2.7)**: wrapper 既定の headless + `--sandbox` では、agent のシェルコマンドは権限要求(`command` / `escalate_admin`)が自動拒否される(実測: `brain/` からの `Copy-Item`、`powershell -Command` による変換、workspace 内の `git status` の 3 種。すべてのコマンドを網羅した検証ではない)。agy 自身のレビューによれば、sandbox は本来 workspace 内の安全なコマンドを承認なしで実行するためのもので、`brain/` は workspace 外なので境界違反になる。ただし workspace 内の `git status` も拒否された理由はこの説明では足りず、未解明。`~/.gemini/antigravity-cli/settings.json` の `permissions.allow` に該当ルールがあっても sandbox 下では通らなかった。`--sandbox` を外すと allow 済みコマンド(`git status`)は実行できたが、wrapper.ps1 は `--sandbox` 固定であり、安全上も外さない [実測]。
- **空応答の症状**: 権限拒否で agent が本文を出さずに終わると stdout 空・exit 0 になり、wrapper は `agy returned empty output` としか報告しない(原因は agy の stderr に出る。issue #14)[実測: 1.2.7、画像タスク 3 件 + `git status` 1 件]。画像タスクでこの症状が出たら、まず「複製・変換をさせていないか」を疑う。
- **agy のバージョン差**: 1.1.1 で `--print` の仕様が変わり旧 wrapper が誤動作した(issue #7、修正済み)。1.1.1 → 1.2.7 で保存先(scratch → brain)と headless の権限挙動も変わった。off-task な応答や空応答が出たら上流の仕様変更を疑い、`agy changelog` を確認する。
- **失敗の形**: 生成失敗時に本文だけ返り、ファイルが作られないことがある [実測: 1.1.1]。応答の報告パスと実ファイルの存在・バイト数を必ず突き合わせる。
- **時間**: 生成 1 枚あたり実測 30〜90 秒程度。`-Timeout` は 300 秒以上を推奨 [実測]。

## 5. 主要出典

- 実測記録: `docs/work-log/2026-07-10-image-gen.md`(1.1.1)、`docs/work-log/2026-09-20-image-gen-spec.md`(1.2.7)(本リポジトリ)
- helper への host 複製ステップ組み込みの検討: issue #17(本リポジトリ)
- 姉妹リポジトリの同種文書: [add_codexcli `docs/references/image-generation.md`](https://github.com/Yumeno/add_codexcli/blob/main/docs/references/image-generation.md)(GPT-Image-2 向け。数値は流用不可)
- Antigravity CLI 公式: https://antigravity.google/docs/cli/overview(画像生成の公式仕様ページは調査時点で未発見)
