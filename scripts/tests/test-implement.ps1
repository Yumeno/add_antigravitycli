$ErrorActionPreference="Continue"
# Remove-Item on a directory junction can hang on PS 5.1 when the junction's
# target contains a .git directory (it appears to traverse into the target
# rather than just unlinking the reparse point); Directory.Delete($p, $false)
# removes only the link itself and is safe regardless of target contents.
function Remove-Junction([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        try { [IO.Directory]::Delete($Path, $false) } catch { }
    }
}
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

    # --- F7: additional coverage ---

    # session_rename_entry: commit a tracked file before the session starts, then
    # rename it mid-session; both old and new names must surface as dirty/outside.
    $Session2=Join-Path $Root "session_rename.json"
    Set-Content (Join-Path $Repo new.txt) "pre-existing" -Encoding UTF8
    & git -C $Repo add new.txt; & git -C $Repo commit -qm add_new
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session2 2>&1
    $text=($o|Out-String)
    if($LASTEXITCODE-ne 0-or$text-notmatch'round=1 owned=0'){throw "session_rename_entry: round1 failed`n$text"}
    & git -C $Repo mv new.txt renamed.txt
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session2 2>&1
    $text=($o|Out-String)
    if($LASTEXITCODE-ne 1-or$text-notmatch'outside this delegation session'-or$text-notmatch'new\.txt'-or$text-notmatch'renamed\.txt'){throw "session_rename_entry: expected outside failure`n$text"}
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session2 -AdoptChanges 2>&1
    if($LASTEXITCODE-ne 0){throw "session_rename_entry: adopt failed`n$($o|Out-String)"}
    $sessionText=Get-Content $Session2 -Raw
    if($sessionText-notmatch'new\.txt'-or$sessionText-notmatch'renamed\.txt'){throw "session_rename_entry: session missing entries`n$sessionText"}
    Remove-Item $Session2,"$Session2.snapshot" -Force -ErrorAction SilentlyContinue
    # Commit the adopted rename so the tree is clean again for later tests.
    & git -C $Repo add -A; & git -C $Repo commit -qm rename_cleanup

    # session_unicode_space_path: a path with a space and non-ASCII characters round-trips through owned.
    $Session3=Join-Path $Root "session_unicode.json"
    New-Item -ItemType Directory -Path (Join-Path $Repo "sub dir") -Force | Out-Null
    $env:FAKE_WRITE_FILE=Join-Path $Repo "sub dir\日本語 file.txt"
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session3 2>&1
    $code=$LASTEXITCODE
    Remove-Item Env:FAKE_WRITE_FILE
    if($code-ne 0-or-not(Test-Path (Join-Path $Repo "sub dir\日本語 file.txt"))){throw "session_unicode_space_path failed`n$($o|Out-String)"}
    $sessionObj=Get-Content $Session3 -Raw -Encoding UTF8 | ConvertFrom-Json
    if(@($sessionObj.owned) -notcontains "sub dir/日本語 file.txt"){throw "session_unicode_space_path: owned entry missing`n$(Get-Content $Session3 -Raw -Encoding UTF8)"}
    Remove-Item $Session3,"$Session3.snapshot" -Force -ErrorAction SilentlyContinue
    & git -C $Repo add -A; & git -C $Repo commit -qm unicode_cleanup

    # session_tampered_snapshot_field: point snapshot at another existing valid snapshot -> invalid.
    $Session4=Join-Path $Root "session_tamper1.json"
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session4 2>&1
    if($LASTEXITCODE-ne 0){throw "session_tampered_snapshot_field: setup failed`n$($o|Out-String)"}
    $otherSnap="$Session4.other.snapshot"
    Copy-Item "$Session4.snapshot" $otherSnap
    $sessionObj=Get-Content $Session4 -Raw | ConvertFrom-Json
    $sessionObj.snapshot=$otherSnap
    [IO.File]::WriteAllText($Session4, ($sessionObj|ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session4 2>&1
    if($LASTEXITCODE-eq 0-or($o|Out-String)-notmatch'Session file is invalid'){throw "session_tampered_snapshot_field: expected invalid`n$($o|Out-String)"}
    Remove-Item $Session4,"$Session4.snapshot",$otherSnap -Force -ErrorAction SilentlyContinue

    # session_tampered_round: round set to a non-integer -> invalid.
    $Session5=Join-Path $Root "session_tamper2.json"
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session5 2>&1
    if($LASTEXITCODE-ne 0){throw "session_tampered_round: setup failed`n$($o|Out-String)"}
    (Get-Content $Session5 -Raw) -replace '"round":\s*\d+','"round": "x"' | Set-Content $Session5 -Encoding UTF8 -NoNewline
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session5 2>&1
    if($LASTEXITCODE-eq 0-or($o|Out-String)-notmatch'Session file is invalid'){throw "session_tampered_round: expected invalid`n$($o|Out-String)"}
    Remove-Item $Session5,"$Session5.snapshot" -Force -ErrorAction SilentlyContinue

    # session_tampered_owned_traversal: owned entry '../x' -> invalid.
    $Session6=Join-Path $Root "session_tamper3.json"
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session6 2>&1
    if($LASTEXITCODE-ne 0){throw "session_tampered_owned_traversal: setup failed`n$($o|Out-String)"}
    $sessionObj=Get-Content $Session6 -Raw | ConvertFrom-Json
    $sessionObj.owned=@("../x")
    [IO.File]::WriteAllText($Session6, ($sessionObj|ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session6 2>&1
    if($LASTEXITCODE-eq 0-or($o|Out-String)-notmatch'Session file is invalid'){throw "session_tampered_owned_traversal: expected invalid`n$($o|Out-String)"}
    Remove-Item $Session6,"$Session6.snapshot" -Force -ErrorAction SilentlyContinue

    # session_git_status_failure: corrupt the index so git status fails while rev-parse still succeeds -> fail closed.
    $Session7=Join-Path $Root "session_gitfail.json"
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session7 2>&1
    if($LASTEXITCODE-ne 0){throw "session_git_status_failure: setup failed`n$($o|Out-String)"}
    $indexPath=Join-Path $Repo ".git\index"
    Copy-Item $indexPath "$indexPath.bak"
    Set-Content $indexPath "garbage not an index" -Encoding UTF8 -NoNewline
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session7 2>&1
    $code=$LASTEXITCODE
    Move-Item "$indexPath.bak" $indexPath -Force
    if($code-eq 0-or($o|Out-String)-notmatch'Could not read Git status'){throw "session_git_status_failure: expected failure`n$($o|Out-String)"}
    Remove-Item $Session7,"$Session7.snapshot" -Force -ErrorAction SilentlyContinue

    # session_lock_present: a stale lock file blocks the run; removing it lets it proceed.
    $Session8=Join-Path $Root "session_lock.json"
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session8 2>&1
    if($LASTEXITCODE-ne 0){throw "session_lock_present: setup failed`n$($o|Out-String)"}
    Set-Content "$Session8.lock" "pid=999999 time=2020-01-01T00:00:00Z" -Encoding UTF8
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session8 2>&1
    if($LASTEXITCODE-eq 0-or($o|Out-String)-notmatch'locked'){throw "session_lock_present: expected lock failure`n$($o|Out-String)"}
    Remove-Item "$Session8.lock" -Force
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session8 2>&1
    if($LASTEXITCODE-ne 0-or(Test-Path "$Session8.lock")){throw "session_lock_present: expected success after unlock`n$($o|Out-String)"}
    Remove-Item $Session8,"$Session8.snapshot" -Force -ErrorAction SilentlyContinue

    # session_symlink_path_rejected: a directory junction whose real target is
    # legitimately outside the repo must now be ACCEPTED (the real-path
    # resolver correctly classifies it as outside-repo), while a junction
    # ancestor resolving INTO the repo is covered separately below.
    $JuncParent=Join-Path $Root "junc_target"
    $JuncLink=Join-Path $Root "junc_link"
    New-Item -ItemType Directory -Path $JuncParent -Force | Out-Null
    $juncOk=$true
    try { New-Item -ItemType Junction -Path $JuncLink -Target $JuncParent -ErrorAction Stop | Out-Null } catch { $juncOk=$false }
    if ($juncOk) {
        $Session9=Join-Path $JuncLink "s.json"
        $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session9 2>&1
        $text=($o|Out-String)
        if($LASTEXITCODE-ne 0){throw "session_symlink_path_rejected: expected acceptance of an outside-repo junction`n$text"}
        Remove-Item $Session9,"$Session9.snapshot" -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "PASS-skip: junction creation not permitted on this platform"
    }
    Remove-Junction $JuncLink
    Remove-Item $JuncParent -Recurse -Force -ErrorAction SilentlyContinue

    # session_ancestor_junction_rejected: a junction ANCESTOR (not the immediate
    # parent) that points INTO the repo must still be caught by the real-path
    # resolver, even though "sub" between the junction and the leaf is itself
    # an ordinary directory (created inside the repo so it exists through the link).
    $AncLink=Join-Path $Root "anc_link"
    New-Item -ItemType Directory -Path (Join-Path $Repo "sub") -Force | Out-Null
    $ancJuncOk=$true
    try { New-Item -ItemType Junction -Path $AncLink -Target $Repo -ErrorAction Stop | Out-Null } catch { $ancJuncOk=$false }
    if ($ancJuncOk) {
        $Session11=Join-Path $AncLink "sub\s.json"
        $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session11 2>&1
        $text=($o|Out-String)
        if($LASTEXITCODE-eq 0-or$text-notmatch'outside the repository'){throw "session_ancestor_junction_rejected: expected rejection`n$text"}
    } else {
        Write-Host "PASS-skip: ancestor junction creation not permitted on this platform"
    }
    Remove-Junction $AncLink
    Remove-Item (Join-Path $Repo "sub") -Recurse -Force -ErrorAction SilentlyContinue

    # session_ancestor_junction_outside_accepted: a junction ancestor pointing
    # OUTSIDE the repo must resolve fine and let the session start normally.
    $OutsideTarget=Join-Path $Root "outside_target"
    $OutsideLink=Join-Path $Root "outside_link"
    New-Item -ItemType Directory -Path $OutsideTarget -Force | Out-Null
    $outJuncOk=$true
    try { New-Item -ItemType Junction -Path $OutsideLink -Target $OutsideTarget -ErrorAction Stop | Out-Null } catch { $outJuncOk=$false }
    if ($outJuncOk) {
        $Session12=Join-Path $OutsideLink "sub\s.json"
        New-Item -ItemType Directory -Path (Join-Path $OutsideTarget "sub") -Force | Out-Null
        $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session12 2>&1
        $text=($o|Out-String)
        if($LASTEXITCODE-ne 0){throw "session_ancestor_junction_outside_accepted: expected success`n$text"}
        Remove-Item (Join-Path $OutsideTarget "sub\s.json"),(Join-Path $OutsideTarget "sub\s.json.snapshot") -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "PASS-skip: outside ancestor junction creation not permitted on this platform"
    }
    Remove-Junction $OutsideLink
    Remove-Item $OutsideTarget -Recurse -Force -ErrorAction SilentlyContinue

    # session_verify_failure_precedence: verify violation (protected file) wins over wrapper failure -> exit 3.
    $Session10=Join-Path $Root "session_precedence.json"
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session10 2>&1
    if($LASTEXITCODE-ne 0){throw "session_verify_failure_precedence: setup failed`n$($o|Out-String)"}
    $env:FAKE_MODE="fail"; $env:FAKE_WRITE_FILE=Join-Path $Repo ".env"
    $o=& powershell -NoProfile -ExecutionPolicy Bypass -File $Script -SpecFile $Spec -Repo $Repo -Session $Session10 2>&1
    $code=$LASTEXITCODE
    Remove-Item Env:FAKE_WRITE_FILE; Remove-Item -LiteralPath (Join-Path $Repo ".env") -Force -ErrorAction SilentlyContinue
    $env:FAKE_MODE="success"
    if($code-ne 3-or($o|Out-String)-notmatch'\[ANTIGRAVITY_VERIFY_VIOLATION\]'){throw "session_verify_failure_precedence: expected exit 3`n$($o|Out-String)"}
    Remove-Item $Session10,"$Session10.snapshot" -Force -ErrorAction SilentlyContinue

    Write-Host "test-implement.ps1: OK"
} finally {$env:PATH=$oldPath;Remove-Item Env:ANTIGRAVITY_WRAPPER_CONFIG -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue}
