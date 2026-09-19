---
name: antigravity-implement
description: Antigravity CLIを実装担当として明示的に起動し、必要に応じて複数の画像・音声・動画・PDFを参照させ、cleanなGitリポジトリ内を最小権限で編集させて変更を独立検収する。ユーザーが「antigravity-implement」「Antigravityに実装させて」など実装委任を明示した場合に限って使う。
---

# Antigravity CLIへ実装を委任する

外部エージェントへ書き込み権限を渡す高リスク操作として扱う。ユーザーの明示指定なしに起動しない。

## 実行前チェック

1. 対象がGitリポジトリであることを確認する。
2. `git status --short` でclean treeを確認する。既存変更があれば停止し、勝手にstash、破棄、上書きしない。
3. 現在の `HEAD`、ブランチ、statusを記録する。
4. タスク、変更可能範囲、変更禁止範囲、受け入れ条件、実行すべきテストをUTF-8の一時仕様ファイルへ具体的に記述する。
5. コミット、push、PR作成、Antigravity CLI 経由の委任以外の外部送信、依存追加、破壊的操作を許可しない。dangerous flagや承認回避フラグは既定で禁止する。必要なら個別にユーザー承認を得る。

## 実行

この `SKILL.md` のディレクトリ直下の `scripts/` を絶対パスへ解決し、同梱されたimplement helperを単独コマンドで呼ぶ。現在の作業ディレクトリや共通 `$HOME/scripts` を前提にしない。

```powershell
powershell -ExecutionPolicy Bypass -NoProfile -File "<解決したscripts>/antigravity-implement.ps1" -SpecFile "C:/absolute/spec.txt" -Repo "C:/absolute/repo"
```

複数mediaは絶対pathを1行1件で並べたUTF-8ファイルを作り、`-AttachmentList`で渡す。

```bash
bash "<解決したscripts>/antigravity-implement.sh" --spec-file "/absolute/spec.txt" --repo "/absolute/repo"
```

bashでは`--attachment`を必要な数だけ順序どおり反復する。

wrapperはAntigravity CLIのboolean `--sandbox` を常に有効化する。sandboxへmode値を渡そうとしない。権限拡大や対話承認の自動化を行わない。

## 画像アセットの生成・編集

Antigravity CLIは画像生成を内包しており、このスキルのフロー(仕様書 → wrapper → 検収)のまま画像アセットの生成・編集を委任できる。

画像タスクの仕様書を書く前に、このスキル同梱の `references/image-generation.md`(この `SKILL.md` と同じディレクトリの `references/` 配下)を読むこと。要点のみ抜粋:

- **agy 1.2.7 の headless + sandbox では agent のシェルコマンドが権限拒否される(実測範囲)**。生成物を指定パスへ複製・変換させると空応答になる。仕様書では「複製・変換・コマンド実行をしない」「`ARTIFACT_PATH:` に生成物の絶対パスを報告する」と指示する(1.2.7 で 1 件確認)。**helper の自動検収は生成物を見ない**ので、helper 終了後に host が `ARTIFACT_PATH`(`~/.gemini/antigravity-cli/brain/` 配下であることを確認)からリポジトリ内へ複製(必要なら PNG 変換)し、magic bytes・寸法・目視で別途検収する
- 仕様書にはファイル名・形式・被写体・**アスペクト比**(`1:1` 既定、`16:9`/`9:16`/`4:3`/`3:4`/`3:2`/`2:3`)・スタイル・避けたい要素を書く。UI アセットは「デバイスフレームを含めず UI 画面のみ」を明記。詳細なプロンプト構築はagentが自動で行う
- 編集はリファレンス画像の絶対パスを仕様書に書くだけでよい(`--attachment` 不要。1.1.1 で実測、1.2.7 では未再検証)。**参照画像は最大 3 枚**(4 枚以上はツール呼び出しが失敗)。「変更点の限定列挙 + 維持項目の明示列挙」で指示する
- **生成モデル名は応答にもログにも出ない**。モデル名を報告させない・推測で書かない
- 検収では magic bytes・バイト数・目視を省かない(数十KB未満はplaceholder疑い)

## 独立検収

1. helperの成功申告を根拠に完了扱いしない。
2. 実行前snapshotと比較し、`git status --short`、`git diff --stat`、`git diff` を自分で確認する。
3. 依頼外変更、秘密情報、生成物、依存追加、危険なコマンド、テスト弱体化を検査する。
4. 既存環境で受け入れ条件に対応するテストを実行する。新しいテスト依存を勝手に追加しない。
5. 問題があれば、変更内容を保持したまま具体的に報告する。無断でresetやcheckoutを行わない。
6. 検収結果、変更ファイル、テスト結果、残課題をユーザーへ報告する。
7. 自分が作成した一時仕様ファイルだけを、絶対パスと対象範囲を確認して削除する。
