$ErrorActionPreference = "Stop"
$Artifact = Join-Path (Split-Path $PSScriptRoot -Parent) "antigravity-artifact.ps1"
$Root = Join-Path $env:TEMP ("antigravity_artifact_test_" + [guid]::NewGuid().ToString("N"))
$Brain = Join-Path $Root "brain"
$Conv = Join-Path $Brain "conv1"
$Repo = Join-Path $Root "repo"

# Fixtures: a 1x1 PNG (fixed real-world bytes) and a minimal JPEG (3x2, SOF0 only).
$PngHex = "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d494441547801636000000002000173d24b5a0000000049454e44ae426082"
$JpegHex = "ffd8ffc0001108000200030301220002110103110 1ffd9".Replace(" ","")
# Additional malformed/edge-case fixtures for structural validation tests.
$JpegProgressiveHex = "ffd8ffc20011080002000303011100011100011100ffd9"
$JpegAppnHex = "ffd8ffe000104a46494600010100000100010000ffc00011080002000303011100011100011100ffd9"
$JpegBadLenHex = "ffd8ffc00002ffd9"
$JpegTruncatedHex = "ffd8ffc000110800"
$JpegSosBeforeSofHex = "ffd8ffda0002ffd9"
$PngWrongIhdrLenHex = "89504e470d0a1a0a0000000c49484452000000010000000108060000001f15c489"
$PngHugeHex = "89504e470d0a1a0a0000000d4948445200004000000040000806000000a9c81084"
$PngZeroHex = "89504e470d0a1a0a0000000d4948445200000000000000010806000000f0d7afb7"

function Hex-ToBytes([string]$Hex) {
    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($Hex.Substring($i*2,2),16) }
    return $bytes
}

$passed = 0; $total = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    $script:total++
    try {
        & $Body
        $script:passed++
        Write-Host "PASS: $Name"
    } catch {
        Write-Host "FAIL: $Name -- $_"
    }
}

function Invoke-Artifact([string[]]$RestArgs) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Artifact @RestArgs 2>&1
    return @{ Output = ($out | Out-String); Code = $LASTEXITCODE }
}

function Reset-Fixtures {
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $Conv -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Brain "conv2") -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $Conv "img.png"), (Hex-ToBytes $PngHex))
    [IO.File]::WriteAllBytes((Join-Path $Conv "img.jpg"), (Hex-ToBytes $JpegHex))
    [IO.File]::WriteAllText((Join-Path $Conv "notes.txt"), "not an image")
    New-Item -ItemType Directory -Path $Repo -Force | Out-Null
    & git -C $Repo init -q
    & git -C $Repo config user.email test@example.invalid
    & git -C $Repo config user.name Test
    Set-Content (Join-Path $Repo "base.txt") "base"
    & git -C $Repo add base.txt
    & git -C $Repo commit -qm base
    $env:ANTIGRAVITY_BRAIN_DIR = $Brain
}

try {
    Reset-Fixtures

    Test-Case "png_import_ok" {
        $dest = Join-Path $Repo "out.png"
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "img.png"),"-Destination",$dest)
        if ($r.Code -ne 0 -or $r.Output -notmatch "\[ANTIGRAVITY_ARTIFACT_OK\]") { throw $r.Output }
        if ($r.Output -notmatch "type=png") { throw "missing type=png: $($r.Output)" }
        if ($r.Output -notmatch "width=1 height=1") { throw "unexpected dims: $($r.Output)" }
        if ($r.Output -notmatch "destination=out.png") { throw "unexpected destination: $($r.Output)" }
        if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { throw "file not copied" }
        $srcHash = (Get-FileHash -LiteralPath (Join-Path $Conv "img.png") -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($r.Output -notmatch "sha256=$srcHash") { throw "sha256 mismatch: $($r.Output)" }
        $srcBytes = [IO.File]::ReadAllBytes((Join-Path $Conv "img.png"))
        $dstBytes = [IO.File]::ReadAllBytes($dest)
        if (Compare-Object $srcBytes $dstBytes) { throw "bytes differ" }
    }

    Test-Case "jpeg_import_ok" {
        $dest = Join-Path $Repo "out.jpg"
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "img.jpg"),"-Destination",$dest)
        if ($r.Code -ne 0 -or $r.Output -notmatch "\[ANTIGRAVITY_ARTIFACT_OK\]") { throw $r.Output }
        if ($r.Output -notmatch "type=jpeg") { throw "missing type=jpeg: $($r.Output)" }
        if ($r.Output -notmatch "width=3 height=2") { throw "unexpected dims: $($r.Output)" }
    }

    Test-Case "source_outside_brain_rejected" {
        $outside = Join-Path $Root "outside.png"
        [IO.File]::WriteAllBytes($outside, (Hex-ToBytes $PngHex))
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",$outside,"-Destination",(Join-Path $Repo "x.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "\[ANTIGRAVITY_ARTIFACT_ERROR\]") { throw $r.Output }
    }

    Test-Case "source_link_rejected" {
        $linkPath = Join-Path $Conv "link.png"
        $target = Join-Path $Conv "img.png"
        $created = $false
        try {
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $target -ErrorAction Stop | Out-Null
            $created = $true
        } catch { }
        if (-not $created) { return }  # cannot create a real symlink here; treat as PASS-skip
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",$linkPath,"-Destination",(Join-Path $Repo "y.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "\[ANTIGRAVITY_ARTIFACT_ERROR\]") { throw $r.Output }
    }

    Test-Case "unrecognized_content_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "notes.txt"),"-Destination",(Join-Path $Repo "notes.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "unsupported or unrecognized image content") { throw $r.Output }
    }

    Test-Case "extension_mismatch_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "img.jpg"),"-Destination",(Join-Path $Repo "mismatch.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "destination extension does not match image type jpeg") { throw $r.Output }
    }

    Test-Case "destination_outside_repo_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "img.png"),"-Destination",(Join-Path $Root "outside2.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "\[ANTIGRAVITY_ARTIFACT_ERROR\]") { throw $r.Output }
    }

    Test-Case "destination_exists_without_overwrite_rejected" {
        $dest = Join-Path $Repo "exists.png"
        [IO.File]::WriteAllBytes($dest, (Hex-ToBytes $PngHex))
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "img.png"),"-Destination",$dest)
        if ($r.Code -eq 0 -or $r.Output -notmatch "already exists") { throw $r.Output }
    }

    Test-Case "destination_exists_with_overwrite_ok" {
        $dest = Join-Path $Repo "exists.png"
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "img.png"),"-Destination",$dest,"-Overwrite")
        if ($r.Code -ne 0 -or $r.Output -notmatch "\[ANTIGRAVITY_ARTIFACT_OK\]") { throw $r.Output }
    }

    Test-Case "destination_protected_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "img.png"),"-Destination",(Join-Path $Repo ".env.png"))
        if ($r.Code -eq 0) { throw $r.Output }
    }

    Test-Case "destination_under_git_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "img.png"),"-Destination",(Join-Path $Repo ".git\evil.png"))
        if ($r.Code -eq 0) { throw $r.Output }
    }

    Test-Case "missing_parent_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "img.png"),"-Destination",(Join-Path $Repo "nope\x.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "parent directory does not exist") { throw $r.Output }
    }

    Test-Case "truncated_png_dimensions_rejected" {
        $full = Hex-ToBytes $PngHex
        $truncated = $full[0..19]
        $truncPath = Join-Path $Conv "trunc.png"
        [IO.File]::WriteAllBytes($truncPath, $truncated)
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",$truncPath,"-Destination",(Join-Path $Repo "trunc.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "could not read image dimensions") { throw $r.Output }
    }

    Test-Case "conversation_id_mismatch_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv2","-Source",(Join-Path $Conv "img.png"),"-Destination",(Join-Path $Repo "mismatch1.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "not inside the conversation directory") { throw $r.Output }
    }

    Test-Case "conversation_id_invalid_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","../x","-Source",(Join-Path $Conv "img.png"),"-Destination",(Join-Path $Repo "mismatch2.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "Invalid conversation id") { throw $r.Output }
    }

    Test-Case "source_nested_dir_rejected" {
        $subDir = Join-Path $Conv "sub"
        New-Item -ItemType Directory -Path $subDir -Force | Out-Null
        $nested = Join-Path $subDir "nested.png"
        [IO.File]::WriteAllBytes($nested, (Hex-ToBytes $PngHex))
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",$nested,"-Destination",(Join-Path $Repo "nested.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "not inside the conversation directory") { throw $r.Output }
    }

    Test-Case "sof2_progressive_accepted" {
        $path = Join-Path $Conv "prog.jpg"
        [IO.File]::WriteAllBytes($path, (Hex-ToBytes $JpegProgressiveHex))
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",$path,"-Destination",(Join-Path $Repo "prog.jpg"))
        if ($r.Code -ne 0 -or $r.Output -notmatch "width=3 height=2") { throw $r.Output }
    }

    Test-Case "appn_before_sof_accepted" {
        $path = Join-Path $Conv "appn.jpg"
        [IO.File]::WriteAllBytes($path, (Hex-ToBytes $JpegAppnHex))
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",$path,"-Destination",(Join-Path $Repo "appn.jpg"))
        if ($r.Code -ne 0 -or $r.Output -notmatch "width=3 height=2") { throw $r.Output }
    }

    Test-Case "jpeg_bad_segment_length_rejected" {
        $path = Join-Path $Conv "badlen.jpg"
        [IO.File]::WriteAllBytes($path, (Hex-ToBytes $JpegBadLenHex))
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",$path,"-Destination",(Join-Path $Repo "badlen.jpg"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "could not read image dimensions") { throw $r.Output }
    }

    Test-Case "jpeg_truncated_before_sof_rejected" {
        $path = Join-Path $Conv "jtrunc.jpg"
        [IO.File]::WriteAllBytes($path, (Hex-ToBytes $JpegTruncatedHex))
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",$path,"-Destination",(Join-Path $Repo "jtrunc.jpg"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "could not read image dimensions") { throw $r.Output }
    }

    Test-Case "jpeg_sos_before_sof_rejected" {
        $path = Join-Path $Conv "sos.jpg"
        [IO.File]::WriteAllBytes($path, (Hex-ToBytes $JpegSosBeforeSofHex))
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",$path,"-Destination",(Join-Path $Repo "sos.jpg"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "could not read image dimensions") { throw $r.Output }
    }

    Test-Case "png_ihdr_length_wrong_rejected" {
        $path = Join-Path $Conv "wronglen.png"
        [IO.File]::WriteAllBytes($path, (Hex-ToBytes $PngWrongIhdrLenHex))
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",$path,"-Destination",(Join-Path $Repo "wronglen.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "could not read image dimensions") { throw $r.Output }
    }

    Test-Case "png_huge_dimensions_rejected" {
        $path = Join-Path $Conv "huge.png"
        [IO.File]::WriteAllBytes($path, (Hex-ToBytes $PngHugeHex))
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",$path,"-Destination",(Join-Path $Repo "huge.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "image dimensions out of range") { throw $r.Output }
    }

    Test-Case "png_zero_dimension_rejected" {
        $path = Join-Path $Conv "zero.png"
        [IO.File]::WriteAllBytes($path, (Hex-ToBytes $PngZeroHex))
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",$path,"-Destination",(Join-Path $Repo "zero.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "could not read image dimensions") { throw $r.Output }
    }

    Test-Case "crlf_path_rejected" {
        $badDest = (Join-Path $Repo "evil") + "`r" + ".png"
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "img.png"),"-Destination",$badDest)
        if ($r.Code -eq 0 -or $r.Output -notmatch "path contains a line break") { throw $r.Output }
    }

    Test-Case "ads_destination_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "img.png"),"-Destination",(Join-Path $Repo ".git:artifact.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "alternate data stream") { throw $r.Output }
        if (Test-Path -LiteralPath (Join-Path $Repo ".git") -PathType Leaf) { throw ".git became a file" }
    }

    Test-Case "reserved_device_name_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "img.png"),"-Destination",(Join-Path $Repo "nul.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "reserved device name") { throw $r.Output }
    }

    Test-Case "git_dir_case_variant_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "img.png"),"-Destination",(Join-Path $Repo ".GIT\x.png"))
        if ($r.Code -eq 0) { throw $r.Output }
    }

    Test-Case "temp_cleanup_on_failure" {
        $before = @(Get-ChildItem -LiteralPath $Repo -Filter ".antigravity-artifact-*" -Force -ErrorAction SilentlyContinue)
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "notes.txt"),"-Destination",(Join-Path $Repo "shouldfail.png"))
        if ($r.Code -eq 0) { throw "expected failure: $($r.Output)" }
        $after = @(Get-ChildItem -LiteralPath $Repo -Filter ".antigravity-artifact-*" -Force -ErrorAction SilentlyContinue)
        if ($after.Count -ne $before.Count) { throw "leftover temp file(s): $($after | ForEach-Object { $_.Name })" }
    }

    Test-Case "overwrite_failure_keeps_original" {
        $dest = Join-Path $Repo "overwrite_ok.png"
        [IO.File]::WriteAllBytes($dest, (Hex-ToBytes $PngHex))
        $originalBytes = [IO.File]::ReadAllBytes($dest)
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "img.jpg"),"-Destination",$dest,"-Overwrite")
        if ($r.Code -eq 0) { throw "expected extension-mismatch failure: $($r.Output)" }
        $afterBytes = [IO.File]::ReadAllBytes($dest)
        if (Compare-Object $originalBytes $afterBytes) { throw "original file was modified despite failed import" }
        # A successful overwrite does replace the file.
        $r2 = Invoke-Artifact @("import","-Repo",$Repo,"-ConversationId","conv1","-Source",(Join-Path $Conv "img.png"),"-Destination",$dest,"-Overwrite")
        if ($r2.Code -ne 0 -or $r2.Output -notmatch "\[ANTIGRAVITY_ARTIFACT_OK\]") { throw $r2.Output }
    }

    Write-Host "Passed: $passed / $total"
    if ($passed -ne $total) { exit 1 }
} finally {
    Remove-Item Env:\ANTIGRAVITY_BRAIN_DIR -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}
