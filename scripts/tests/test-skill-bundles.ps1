$ErrorActionPreference = "Stop"
$Tool = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "tools\sync-skill-scripts.ps1"
& powershell -NoProfile -ExecutionPolicy Bypass -File $Tool -Check
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("test-skill-bundles-" + [guid]::NewGuid())

try {
    New-Item -ItemType Directory -Path $TestRoot | Out-Null
    foreach ($path in @("scripts", "docs", ".agents", ".claude")) {
        $source = Join-Path $RepoRoot $path
        if (Test-Path -LiteralPath $source -PathType Container) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $TestRoot $path) -Recurse
        }
    }
    New-Item -ItemType Directory -Path (Join-Path $TestRoot "tools") | Out-Null
    $FixtureTool = Join-Path $TestRoot "tools\sync-skill-scripts.ps1"
    Copy-Item -LiteralPath $Tool -Destination $FixtureTool

    & powershell -NoProfile -ExecutionPolicy Bypass -File $FixtureTool -Check
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $ReferenceCopies = @(
        (Join-Path $TestRoot ".agents\skills\antigravity-implement\references\image-generation.md"),
        (Join-Path $TestRoot ".claude\skills\antigravity-implement\references\image-generation.md")
    )

    foreach ($ReferenceCopy in $ReferenceCopies) {
        if (-not (Test-Path -LiteralPath $ReferenceCopy -PathType Leaf)) {
            throw "expected bundled reference is missing: $ReferenceCopy"
        }
        $originalBytes = [IO.File]::ReadAllBytes($ReferenceCopy)
        try {
            [byte[]]$modifiedBytes = $originalBytes + [byte]0
            [IO.File]::WriteAllBytes($ReferenceCopy, $modifiedBytes)
            & powershell -NoProfile -ExecutionPolicy Bypass -File $FixtureTool -Check
            if ($LASTEXITCODE -eq 0) {
                throw "-Check did not detect modified bundled reference: $ReferenceCopy"
            }
        } finally {
            [IO.File]::WriteAllBytes($ReferenceCopy, $originalBytes)
        }
    }

    foreach ($ReferenceCopy in $ReferenceCopies) {
        $UnexpectedDir = Join-Path (Split-Path $ReferenceCopy -Parent) "unexpected-dir"
        $UnexpectedFile = Join-Path $UnexpectedDir "foo.md"
        New-Item -ItemType Directory -Path $UnexpectedDir -Force | Out-Null
        [IO.File]::WriteAllText($UnexpectedFile, "unexpected reference residue")

        & powershell -NoProfile -ExecutionPolicy Bypass -File $FixtureTool -Check
        if ($LASTEXITCODE -eq 0) {
            throw "-Check did not detect unexpected bundled reference directory: $UnexpectedDir"
        }

        & powershell -NoProfile -ExecutionPolicy Bypass -File $FixtureTool
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        if (Test-Path -LiteralPath $UnexpectedDir) {
            throw "sync did not remove unexpected bundled reference directory: $UnexpectedDir"
        }
    }

    & powershell -NoProfile -ExecutionPolicy Bypass -File $FixtureTool -Check
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    if (Test-Path -LiteralPath $TestRoot) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    }
}
Write-Host "test-skill-bundles.ps1: OK"
