# 作業記録 2026-09-20 — antigravity-implement.ps1 の出力順序を Bash 版に揃える

## 目的

Issue [#11](https://github.com/Yumeno/add_antigravitycli/issues/11) の対応。PowerShell 版は wrapper の出力を変数に貯めてから verify check を呼んでいたため、ホスト CLI から見ると「検収ログ → モデル回答」の逆順で出力され、さらにタイムアウトまで進捗が見えなかった。

## 修正内容

- `scripts/antigravity-implement.ps1`
  - wrapper の出力をキャプチャせずそのまま流す(stdout/stderr とも host へ直結)。順序は Bash 版と同じ「モデル回答 → verify check の結果」になり、進捗も即時に見える
  - wrapper 失敗時は、出力を再掲する代わりに `[ANTIGRAVITY_IMPLEMENT_ERROR] Antigravity run failed with exit code N. See the wrapper output above.` の 1 行を末尾に出す(wrapper 自身の `[ANTIGRAVITY_WRAPPER_ERROR]` sentinel は既に流れているため重複させない)
  - 事前 snapshot の `[ANTIGRAVITY_VERIFY_OK] snapshot created` を `Out-Null` で抑止(Bash 版は `>/dev/null` 済みで、ここも揃える)
- `scripts/tests/test-implement.ps1`: 「`fake response` が `### git status` より前に出る」「`snapshot created` が出ない」を検査
- `scripts/tests/test-implement.sh`: 「`implemented` が `--- git status --short ---` より前に出る」を検査(Bash 版の既存挙動の回帰防止)
- 全 skill 同梱 bundle を sync tool で再配布

## 検証

- unit: test-implement.ps1 OK、test-implement.sh 3/3、test-verify.ps1 OK、test-skill-bundles.ps1 OK、sync-skill-scripts.ps1 -Check 同期済み
- 実 agy 1.2.7 E2E(temp リポジトリに hello.txt を作らせる委任、1 件): 「モデルの完了報告 → `### git status` → `[ANTIGRAVITY_VERIFY_OK]`」の順で出力、exit 0、ファイル内容も一致
