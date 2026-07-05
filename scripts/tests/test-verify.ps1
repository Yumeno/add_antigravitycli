$ErrorActionPreference="Stop"
$Verify=Join-Path (Split-Path $PSScriptRoot -Parent) "antigravity-verify.ps1"
$Root=Join-Path $env:TEMP ("antigravity_verify_test_"+[guid]::NewGuid().ToString("N"))
$Repo=Join-Path $Root repo; $Snap=Join-Path $Root snap.json
try {
    New-Item -ItemType Directory -Path $Repo -Force|Out-Null
    & git -C $Repo init -q; & git -C $Repo config user.email test@example.invalid; & git -C $Repo config user.name Test
    Set-Content (Join-Path $Repo base.txt) base; & git -C $Repo add base.txt; & git -C $Repo commit -qm base
    & powershell -NoProfile -ExecutionPolicy Bypass -File $Verify snapshot -Repo $Repo -Snapshot $Snap
    if($LASTEXITCODE-ne 0){throw "snapshot failed"}
    Set-Content (Join-Path $Repo normal.txt) changed
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Verify check -Repo $Repo -Snapshot $Snap
    if($LASTEXITCODE-ne 0-or($o|Out-String)-notmatch'VERIFY_OK'){throw ($o|Out-String)}
    Set-Content (Join-Path $Repo .env) secret
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Verify check -Repo $Repo -Snapshot $Snap
    if($LASTEXITCODE-ne 1-or($o|Out-String)-notmatch'VERIFY_VIOLATION'){throw ($o|Out-String)}
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Verify check -Repo $Repo -Snapshot $Snap -Allow .env
    if($LASTEXITCODE-ne 0-or($o|Out-String)-notmatch'VERIFY_ALLOWED'){throw ($o|Out-String)}
    Write-Host "test-verify.ps1: OK"
} finally { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
