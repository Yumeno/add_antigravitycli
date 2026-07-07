$ErrorActionPreference = "Stop"
$Tool = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "tools\sync-skill-scripts.ps1"
& powershell -NoProfile -ExecutionPolicy Bypass -File $Tool -Check
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "test-skill-bundles.ps1: OK"
