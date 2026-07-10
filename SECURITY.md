# セキュリティポリシー / Security Policy

## 脆弱性の報告 / Reporting a Vulnerability

脆弱性を発見した場合は、**公開 issue に書かず**、GitHub の [Private Vulnerability Reporting](https://github.com/Yumeno/add_antigravitycli/security/advisories/new) から報告してください。再現手順・影響範囲・秘密情報(トークン、ローカルパス等)を公開の場に書かないようお願いします。

If you find a vulnerability, please report it via [Private Vulnerability Reporting](https://github.com/Yumeno/add_antigravitycli/security/advisories/new) instead of opening a public issue. Do not include reproduction steps, secrets, or local paths in public issues.

## 対応方針 / Response

個人管理のプロジェクトのため、対応時期は保証できませんが、報告は確認します。修正は main へ merge した時点で有効となり、利用者は installer の再実行(`scripts/install-for-*.{ps1,sh}`)で更新できます。

This is a personally maintained project; response time is not guaranteed, but reports will be reviewed. Fixes take effect when merged to main. Users can update by re-running the installers.

## サポート範囲 / Supported Versions

最新の main ブランチのみをサポートします。Antigravity CLI 1.1.1 以降が前提です。

Only the latest main branch is supported. Antigravity CLI 1.1.1 or later is required.
