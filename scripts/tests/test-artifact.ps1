$ErrorActionPreference = "Stop"
$Artifact = Join-Path (Split-Path $PSScriptRoot -Parent) "antigravity-artifact.ps1"
$Root = Join-Path $env:TEMP ("antigravity_artifact_test_" + [guid]::NewGuid().ToString("N"))
$Brain = Join-Path $Root "brain"
$Conv = Join-Path $Brain "conv1"
$Repo = Join-Path $Root "repo"

# Fixtures: a 1x1 PNG (fixed real-world bytes) and a minimal JPEG (3x2, SOF0 only).
$PngHex = "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d494441547801636000000002000173d24b5a0000000049454e44ae426082"
$JpegHex = "ffd8ffc0001108000200030301220002110103110 1ffd9".Replace(" ","")

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
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-Source",(Join-Path $Conv "img.png"),"-Destination",$dest)
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
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-Source",(Join-Path $Conv "img.jpg"),"-Destination",$dest)
        if ($r.Code -ne 0 -or $r.Output -notmatch "\[ANTIGRAVITY_ARTIFACT_OK\]") { throw $r.Output }
        if ($r.Output -notmatch "type=jpeg") { throw "missing type=jpeg: $($r.Output)" }
        if ($r.Output -notmatch "width=3 height=2") { throw "unexpected dims: $($r.Output)" }
    }

    Test-Case "source_outside_brain_rejected" {
        $outside = Join-Path $Root "outside.png"
        [IO.File]::WriteAllBytes($outside, (Hex-ToBytes $PngHex))
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-Source",$outside,"-Destination",(Join-Path $Repo "x.png"))
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
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-Source",$linkPath,"-Destination",(Join-Path $Repo "y.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "\[ANTIGRAVITY_ARTIFACT_ERROR\]") { throw $r.Output }
    }

    Test-Case "unrecognized_content_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-Source",(Join-Path $Conv "notes.txt"),"-Destination",(Join-Path $Repo "notes.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "unsupported or unrecognized image content") { throw $r.Output }
    }

    Test-Case "extension_mismatch_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-Source",(Join-Path $Conv "img.jpg"),"-Destination",(Join-Path $Repo "mismatch.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "destination extension does not match image type jpeg") { throw $r.Output }
    }

    Test-Case "destination_outside_repo_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-Source",(Join-Path $Conv "img.png"),"-Destination",(Join-Path $Root "outside2.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "\[ANTIGRAVITY_ARTIFACT_ERROR\]") { throw $r.Output }
    }

    Test-Case "destination_exists_without_overwrite_rejected" {
        $dest = Join-Path $Repo "exists.png"
        [IO.File]::WriteAllBytes($dest, (Hex-ToBytes $PngHex))
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-Source",(Join-Path $Conv "img.png"),"-Destination",$dest)
        if ($r.Code -eq 0 -or $r.Output -notmatch "already exists") { throw $r.Output }
    }

    Test-Case "destination_exists_with_overwrite_ok" {
        $dest = Join-Path $Repo "exists.png"
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-Source",(Join-Path $Conv "img.png"),"-Destination",$dest,"-Overwrite")
        if ($r.Code -ne 0 -or $r.Output -notmatch "\[ANTIGRAVITY_ARTIFACT_OK\]") { throw $r.Output }
    }

    Test-Case "destination_protected_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-Source",(Join-Path $Conv "img.png"),"-Destination",(Join-Path $Repo ".env.png"))
        if ($r.Code -eq 0) { throw $r.Output }
    }

    Test-Case "destination_under_git_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-Source",(Join-Path $Conv "img.png"),"-Destination",(Join-Path $Repo ".git\evil.png"))
        if ($r.Code -eq 0) { throw $r.Output }
    }

    Test-Case "missing_parent_rejected" {
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-Source",(Join-Path $Conv "img.png"),"-Destination",(Join-Path $Repo "nope\x.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "parent directory does not exist") { throw $r.Output }
    }

    Test-Case "truncated_png_dimensions_rejected" {
        $full = Hex-ToBytes $PngHex
        $truncated = $full[0..19]
        $truncPath = Join-Path $Conv "trunc.png"
        [IO.File]::WriteAllBytes($truncPath, $truncated)
        $r = Invoke-Artifact @("import","-Repo",$Repo,"-Source",$truncPath,"-Destination",(Join-Path $Repo "trunc.png"))
        if ($r.Code -eq 0 -or $r.Output -notmatch "could not read image dimensions") { throw $r.Output }
    }

    Write-Host "Passed: $passed / $total"
    if ($passed -ne $total) { exit 1 }
} finally {
    Remove-Item Env:\ANTIGRAVITY_BRAIN_DIR -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}
