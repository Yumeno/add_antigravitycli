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
    $text=($o|Out-String);$iResp=$text.IndexOf('fake response');$iVerify=$text.IndexOf('### git status')
    if($iVerify-lt 0-or$iResp-gt$iVerify){throw "output order: model response must precede verify log`n$text"}
    if($text-match'snapshot created'){throw "snapshot output must be suppressed`n$text"}
    $argsSeen=Get-Content $env:FAKE_ARGS;if($argsSeen-notcontains"--sandbox"){throw "missing --sandbox"}
    if($argsSeen-contains"--dangerously-skip-permissions"){throw "unsafe flag present"}
    # wrapper failure (stderr + exit 7): verify still runs after the wrapper output, exit code is preserved
    $env:FAKE_MODE="fail"
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo 2>&1
    $text=($o|Out-String);$iWrap=$text.IndexOf('[ANTIGRAVITY_WRAPPER_ERROR]');$iVerify=$text.IndexOf('### git status');$iImpl=$text.IndexOf('[ANTIGRAVITY_IMPLEMENT_ERROR]')
    if($LASTEXITCODE-ne 7){throw "wrapper failure exit code: $LASTEXITCODE`n$text"}
    if($iWrap-lt 0-or$iVerify-lt 0-or$iImpl-lt 0-or$iWrap-gt$iVerify-or$iVerify-gt$iImpl){throw "wrapper failure output order`n$text"}
    # wrapper failure + protected file change: verify violation wins (exit 3)
    $env:FAKE_WRITE_FILE=Join-Path $Repo ".env"
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo 2>&1
    if($LASTEXITCODE-ne 3-or($o|Out-String)-notmatch'\[ANTIGRAVITY_VERIFY_VIOLATION\]'){throw "protected violation: $LASTEXITCODE`n$($o|Out-String)"}
    Remove-Item Env:FAKE_WRITE_FILE;Remove-Item -LiteralPath (Join-Path $Repo ".env") -Force;$env:FAKE_MODE="success"
    Set-Content (Join-Path $Repo dirty.txt) dirty
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo 2>&1
    if($LASTEXITCODE-eq 0-or($o|Out-String)-notmatch'not clean'){throw "dirty tree accepted"}
    Remove-Item (Join-Path $Repo dirty.txt) -Force

    # --- session tests ---
    $env:FAKE_MODE="success"
    $Session=Join-Path $Root "session.json"
    $SnapSidecar="$Session.snapshot"

    # session_start_requires_clean
    Set-Content (Join-Path $Repo dirty2.txt) dirty
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session 2>&1
    if($LASTEXITCODE-eq 0-or($o|Out-String)-notmatch'not clean'){throw "session_start_requires_clean failed`n$($o|Out-String)"}
    if(Test-Path $Session){throw "session file must not be created on failed start"}
    Remove-Item (Join-Path $Repo dirty2.txt) -Force

    # session_round1_and_round2
    $env:FAKE_WRITE_FILE=Join-Path $Repo "new.txt"
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session 2>&1
    $text=($o|Out-String)
    if($LASTEXITCODE-ne 0-or$text-notmatch'\[ANTIGRAVITY_SESSION\] round=1 owned=1'){throw "session_round1 failed`n$text"}
    if($text-notmatch'### git status'){throw "session_round1 missing verify output`n$text"}
    if(-not(Test-Path $Session)){throw "session file not created"}
    if(-not(Test-Path $SnapSidecar)){throw "session snapshot not persisted"}
    $env:FAKE_WRITE_FILE=Join-Path $Repo "second.txt"
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session 2>&1
    $text=($o|Out-String)
    if($LASTEXITCODE-ne 0-or$text-notmatch'\[ANTIGRAVITY_SESSION\] round=2 owned=2'){throw "session_round2 failed`n$text"}
    if($text-notmatch'### git status'){throw "session_round2 missing verify output`n$text"}
    Remove-Item Env:FAKE_WRITE_FILE

    # session_rejects_unrelated_change
    Set-Content (Join-Path $Repo unrelated.txt) unrelated
    Remove-Item -LiteralPath $env:FAKE_ARGS -Force -ErrorAction SilentlyContinue
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session 2>&1
    $text=($o|Out-String)
    if($LASTEXITCODE-ne 1-or$text-notmatch'outside this delegation session'-or$text-notmatch'unrelated\.txt'){throw "session_rejects_unrelated_change failed`n$text"}
    if(Test-Path -LiteralPath $env:FAKE_ARGS){throw "fake agy must not have been invoked"}
    Remove-Item (Join-Path $Repo unrelated.txt) -Force

    # session_wrapper_failure_still_records
    $env:FAKE_MODE="fail"
    $env:FAKE_WRITE_FILE=Join-Path $Repo "failedround.txt"
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session 2>&1
    $text=($o|Out-String)
    if($LASTEXITCODE-ne 7-or$text-notmatch'\[ANTIGRAVITY_SESSION\] round=3 owned=3'){throw "session_wrapper_failure_still_records failed`n$text"}
    Remove-Item Env:FAKE_WRITE_FILE
    $env:FAKE_MODE="success"
    Remove-Item (Join-Path $Repo failedround.txt) -Force

    # session_adopt_changes
    Set-Content (Join-Path $Repo artifact.txt) artifact
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session 2>&1
    $text=($o|Out-String)
    if($LASTEXITCODE-ne 1-or$text-notmatch'outside this delegation session'){throw "session_adopt_changes: expected failure without flag`n$text"}
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session -AdoptChanges 2>&1
    $text=($o|Out-String)
    if($LASTEXITCODE-ne 0-or$text-notmatch'\[ANTIGRAVITY_SESSION\] adopted=1 paths=artifact\.txt'){throw "session_adopt_changes: adopt failed`n$text"}
    if($text-notmatch'\[ANTIGRAVITY_SESSION\] round=4 owned=4'){throw "session_adopt_changes: final owned count wrong`n$text"}
    $sessionText=Get-Content $Session -Raw
    if($sessionText-notmatch'artifact\.txt'){throw "session_adopt_changes: session file missing artifact.txt`n$sessionText"}

    # adopt_requires_continuation
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -AdoptChanges 2>&1
    if($LASTEXITCODE-eq 0){throw "adopt_requires_continuation: expected failure without -Session"}
    $NewSession=Join-Path $Root "session2.json"
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $NewSession -AdoptChanges 2>&1
    $text=($o|Out-String)
    if($LASTEXITCODE-eq 0-or$text-notmatch'only valid when continuing a session'){throw "adopt_requires_continuation: expected failure on session start`n$text"}
    if(Test-Path $NewSession){throw "adopt_requires_continuation: session file must not be created"}

    # session_close
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -Repo $Repo -Session $Session -CloseSession 2>&1
    if($LASTEXITCODE-ne 0-or($o|Out-String)-notmatch'\[ANTIGRAVITY_SESSION\] closed'){throw "session_close failed`n$($o|Out-String)"}
    if((Test-Path $Session)-or(Test-Path $SnapSidecar)){throw "session_close did not remove files"}
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -Repo $Repo -Session $Session -CloseSession 2>&1
    if($LASTEXITCODE-eq 0){throw "session_close on missing session should fail"}

    # session_path_inside_repo_rejected
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session (Join-Path $Repo "s.json") 2>&1
    if($LASTEXITCODE-eq 0){throw "session_path_inside_repo_rejected failed`n$($o|Out-String)"}

    # no_session_unchanged: rerun single-shot success and confirm no session line leaks
    Remove-Item (Join-Path $Repo new.txt),(Join-Path $Repo second.txt),(Join-Path $Repo artifact.txt) -Force -ErrorAction SilentlyContinue
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo 2>&1
    if($LASTEXITCODE-ne 0-or($o|Out-String)-match'\[ANTIGRAVITY_SESSION\]'){throw "no_session_unchanged failed`n$($o|Out-String)"}

    Write-Host "test-implement.ps1: OK"
} finally {$env:PATH=$oldPath;Remove-Item Env:ANTIGRAVITY_WRAPPER_CONFIG -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue}
