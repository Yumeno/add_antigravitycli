$ErrorActionPreference = "Stop"
$Tool = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "tools\sync-skill-scripts.ps1"
& powershell -NoProfile -ExecutionPolicy Bypass -File $Tool -Check
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ReferenceCopies = @(
    (Join-Path $RepoRoot ".agents\skills\antigravity-implement\references\image-generation.md"),
    (Join-Path $RepoRoot ".claude\skills\antigravity-implement\references\image-generation.md")
)

foreach ($ReferenceCopy in $ReferenceCopies) {
    if (-not (Test-Path -LiteralPath $ReferenceCopy -PathType Leaf)) {
        throw "expected bundled reference is missing: $ReferenceCopy"
    }
    $originalBytes = [IO.File]::ReadAllBytes($ReferenceCopy)
    try {
        [byte[]]$modifiedBytes = $originalBytes + [byte]0
        [IO.File]::WriteAllBytes($ReferenceCopy, $modifiedBytes)
        & powershell -NoProfile -ExecutionPolicy Bypass -File $Tool -Check
        if ($LASTEXITCODE -eq 0) {
            throw "-Check did not detect modified bundled reference: $ReferenceCopy"
        }
    } finally {
        [IO.File]::WriteAllBytes($ReferenceCopy, $originalBytes)
    }
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $Tool -Check
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "test-skill-bundles.ps1: OK"
