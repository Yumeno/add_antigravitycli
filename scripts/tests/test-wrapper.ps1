$ErrorActionPreference = "Continue"
$Wrapper = Join-Path (Split-Path $PSScriptRoot -Parent) "antigravity-wrapper.ps1"
$Root = Join-Path $env:TEMP ("antigravity_wrapper_test_" + [guid]::NewGuid().ToString("N"))
$Work = Join-Path $Root "work dir"
New-Item -ItemType Directory -Path $Work -Force | Out-Null
$oldPath=$env:PATH; $env:PATH="$PSScriptRoot;$oldPath"
$env:FAKE_ARGS=Join-Path $Root args.txt; $env:FAKE_STDIN=Join-Path $Root stdin.txt; $env:FAKE_CWD=Join-Path $Root cwd.txt
$passed=0; $failed=0
function Run([string[]]$Arguments) {
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Wrapper @Arguments 2>&1
    return @{Code=$LASTEXITCODE; Text=($o|Out-String)}
}
function Case([string]$Name,[scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "PASS $Name" } catch { $script:failed++; Write-Host "FAIL $Name -- $_" }
}
try {
    Case "missing prompt sentinel" { $r=Run @(); if($r.Code-eq 0-or$r.Text-notmatch'\[ANTIGRAVITY_WRAPPER_ERROR\]'){throw $r.Text} }
    Case "model priority" {
        $env:ANTIGRAVITY_WRAPPER_MODEL="env-model"; $r=Run @("-ShowModel","-Model","cli-model")
        Remove-Item Env:ANTIGRAVITY_WRAPPER_MODEL -ErrorAction SilentlyContinue
        if($r.Code-ne 0-or$r.Text-notmatch'model=cli-model \(source: cli\)'){throw $r.Text}
    }
    Case "stdin argv cwd" {
        $env:FAKE_MODE="success"; $context=Join-Path $Root context.txt
        [IO.File]::WriteAllText($context,"日本語 context",(New-Object Text.UTF8Encoding($false)))
        $r=Run @("-Prompt","request","-ContextFile",$context,"-WorkDir",$Work,"-Model","test-model")
        if($r.Code-ne 0-or$r.Text-notmatch'fake response'){throw $r.Text}
        $stdin=Get-Content $env:FAKE_STDIN -Raw -Encoding UTF8
        if($stdin-ne"## Context`n`n日本語 context`n`n---`n`n## Request`n`nrequest"){throw "stdin mismatch: $stdin"}
        $argv=Get-Content $env:FAKE_ARGS -Encoding UTF8
        foreach($v in @("--print","--print-timeout","180s","--sandbox","--new-project","--add-dir","--model","test-model")){if($argv-notcontains$v){throw "argv missing $v"}}
        if((Get-Content $env:FAKE_CWD -Raw)-ne$Work){throw "cwd mismatch"}
    }
    Case "exit code preserved" { $env:FAKE_MODE="fail";$r=Run @("-Prompt","x");if($r.Code-ne 7-or$r.Text-notmatch'fake failure'){throw $r.Text} }
    Case "empty rejected" { $env:FAKE_MODE="empty";$r=Run @("-Prompt","x");if($r.Code-eq 0-or$r.Text-notmatch'empty output'){throw $r.Text} }
    Case "timeout" { $env:FAKE_MODE="sleep";$r=Run @("-Prompt","x","-Timeout","1");if($r.Code-ne 2-or$r.Text-notmatch'timed out'){throw $r.Text} }
    Case "UTF-8 BOM" {
        foreach($f in @($Wrapper,(Join-Path (Split-Path $PSScriptRoot -Parent) "antigravity-verify.ps1"),(Join-Path (Split-Path $PSScriptRoot -Parent) "antigravity-implement.ps1"))){
            $b=[IO.File]::ReadAllBytes($f);if($b[0]-ne 0xEF-or$b[1]-ne 0xBB-or$b[2]-ne 0xBF){throw "BOM missing: $f"}
        }
    }
} finally {
    $env:PATH=$oldPath; Remove-Item Env:ANTIGRAVITY_WRAPPER_MODEL -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Passed: $passed; Failed: $failed"; if($failed){exit 1}
