$ErrorActionPreference="Continue"
$Script=Join-Path (Split-Path $PSScriptRoot -Parent) "antigravity-implement.ps1"
$Root=Join-Path $env:TEMP ("antigravity_impl_test_"+[guid]::NewGuid().ToString("N"))
$Repo=Join-Path $Root repo; $Spec=Join-Path $Root spec.txt; $oldPath=$env:PATH
try {
    New-Item -ItemType Directory -Path $Repo -Force|Out-Null
    Set-Content $Spec "READMEを作成する" -Encoding UTF8
    & git -C $Repo init -q; & git -C $Repo config user.email test@example.invalid; & git -C $Repo config user.name Test
    Set-Content (Join-Path $Repo base.txt) base; & git -C $Repo add base.txt; & git -C $Repo commit -qm base
    $env:PATH="$PSScriptRoot;$oldPath";$env:FAKE_ARGS=Join-Path $Root args;$env:FAKE_STDIN=Join-Path $Root stdin;$env:FAKE_CWD=Join-Path $Root cwd;$env:FAKE_MODE="success"
    $env:ANTIGRAVITY_WRAPPER_CONFIG=Join-Path $Root "antigravity-wrapper.conf"
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo 2>&1
    if($LASTEXITCODE-ne 0-or($o|Out-String)-notmatch'fake response'){throw ($o|Out-String)}
    $argsSeen=Get-Content $env:FAKE_ARGS;if($argsSeen-notcontains"--sandbox"){throw "missing --sandbox"}
    if($argsSeen-contains"--dangerously-skip-permissions"){throw "unsafe flag present"}
    Set-Content (Join-Path $Repo dirty.txt) dirty
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo 2>&1
    if($LASTEXITCODE-eq 0-or($o|Out-String)-notmatch'not clean'){throw "dirty tree accepted"}
    Write-Host "test-implement.ps1: OK"
} finally {$env:PATH=$oldPath;Remove-Item Env:ANTIGRAVITY_WRAPPER_CONFIG -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue}
