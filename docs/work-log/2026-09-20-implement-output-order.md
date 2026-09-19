# 作業記録 2026-09-20 — antigravity-implement.ps1 の出力順序を Bash 版に揃える

## 目的

Issue [#11](https://github.com/Yumeno/add_antigravitycli/issues/11) の対応。PowerShell 版は wrapper の出力を変数に貯めてから verify check を呼んでいたため、ホスト CLI から見ると「検収ログ → モデル回答」の逆順で出力され、さらにタイムアウトまで進捗が見えなかった。

## 修正内容

- `scripts/antigravity-implement.ps1`
  - wrapper の出力をキャプチャせずそのまま流す(stdout/stderr とも host へ直結)。順序は Bash 版と同じ「エージェントの実行ログ・完了報告 → verify check の結果」になる
  - 注意: wrapper.ps1 自体は agy の stdout/stderr を `ReadToEndAsync` で完了まで全量バッファしてから出力する(timeout kill のため)。したがって本修正で直るのは順序と二重出力であり、**実行中の進捗表示は改善しない**。進捗のストリーミングは wrapper 側の別課題として issue 化する
  - wrapper 失敗時は、出力を再掲する代わりに `[ANTIGRAVITY_IMPLEMENT_ERROR] Antigravity run failed with exit code N. See the wrapper output above.` の 1 行を末尾に出す(wrapper 自身の `[ANTIGRAVITY_WRAPPER_ERROR]` sentinel は既に流れているため重複させない)
  - 事前 snapshot の `[ANTIGRAVITY_VERIFY_OK] snapshot created` を `Out-Null` で抑止(Bash 版は `>/dev/null` 済みで、ここも揃える)
- `scripts/antigravity-implement.sh`: wrapper 失敗時にも末尾に `[ANTIGRAVITY_IMPLEMENT_ERROR] Antigravity run failed with exit code N.` を出し、PowerShell 版と失敗報告の契約を統一(agy レビュー指摘)
- `scripts/tests/fake-agy.ps1`: `FAKE_WRITE_FILE` でファイルを書く機能を追加(fake-agy.sh の `FAKE_AGY_WRITE_FILE` と同等)
- `scripts/tests/test-implement.ps1`: 「`fake response` が `### git status` より前」「`snapshot created` が出ない」に加え、wrapper 失敗(stderr + exit 7)でも verify が走り exit 7 が保たれること、wrapper 失敗 + 保護ファイル変更で verify の exit 3 が優先されることを検査(Codex レビュー指摘)
- `scripts/tests/test-implement.sh`: 「`implemented` が `--- git status --short ---` より前」と、wrapper 失敗時の exit 7 と sentinel を検査
- 全 skill 同梱 bundle を sync tool で再配布

## 検証

- unit: test-implement.ps1 OK、test-implement.sh 3/3、test-verify.ps1 OK、test-skill-bundles.ps1 OK、sync-skill-scripts.ps1 -Check 同期済み
- 実 agy 1.2.7 E2E(temp リポジトリに hello.txt を作らせる委任、1 件): 「エージェントの完了報告 → `### git status` → `[ANTIGRAVITY_VERIFY_OK]`」の順で出力、exit 0、ファイル内容も一致
- Codex 指摘の「親の `$ErrorActionPreference = 'Stop'` で子 powershell の stderr が処理を止める」懸念は実測で否定(stderr は素通りし、後続処理と `$LASTEXITCODE` は正常)。本スクリプトは `powershell -File` の独立プロセスで動くため、そもそも呼出元の EAP を継承しない
