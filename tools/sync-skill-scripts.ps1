param(
    [switch]$Check
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$SourceDir = Join-Path $RepoRoot "scripts"
$ReferenceSourceDir = Join-Path $RepoRoot "docs\references"
$SkillRoots = @(
    (Join-Path $RepoRoot ".agents\skills"),
    (Join-Path $RepoRoot ".claude\skills")
)

$CommonScripts = @(
    "antigravity-wrapper.ps1",
    "antigravity-wrapper.sh"
)
$ImplementScripts = @(
    "antigravity-wrapper.ps1",
    "antigravity-wrapper.sh",
    "antigravity-implement.ps1",
    "antigravity-implement.sh",
    "antigravity-verify.ps1",
    "antigravity-verify.sh",
    "antigravity-implement-safety.txt"
)

function Get-ExpectedScripts([string]$SkillName) {
    if ($SkillName -eq "antigravity-implement") { return $ImplementScripts }
    return $CommonScripts
}

function Get-ExpectedReferences([string]$SkillName) {
    if ($SkillName -eq "antigravity-implement") { return @("image-generation.md") }
    return @()
}

function Compare-FileBytes([string]$Left, [string]$Right) {
    if (-not (Test-Path -LiteralPath $Right -PathType Leaf)) { return $false }
    $leftBytes = [IO.File]::ReadAllBytes($Left)
    $rightBytes = [IO.File]::ReadAllBytes($Right)
    if ($leftBytes.Length -ne $rightBytes.Length) { return $false }
    for ($i = 0; $i -lt $leftBytes.Length; $i++) {
        if ($leftBytes[$i] -ne $rightBytes[$i]) { return $false }
    }
    return $true
}

$mismatches = New-Object Collections.Generic.List[string]
foreach ($skillRoot in $SkillRoots) {
    if (-not (Test-Path -LiteralPath $skillRoot -PathType Container)) { continue }
    foreach ($skill in Get-ChildItem -LiteralPath $skillRoot -Directory) {
        $targetDir = Join-Path $skill.FullName "scripts"
        $expected = Get-ExpectedScripts $skill.Name
        $referenceTargetDir = Join-Path $skill.FullName "references"
        $expectedReferences = Get-ExpectedReferences $skill.Name
        if ($Check) {
            foreach ($name in $expected) {
                $src = Join-Path $SourceDir $name
                $dst = Join-Path $targetDir $name
                if (-not (Compare-FileBytes $src $dst)) {
                    $mismatches.Add("$($skill.FullName): $name")
                }
            }
            if (Test-Path -LiteralPath $targetDir -PathType Container) {
                foreach ($extra in Get-ChildItem -LiteralPath $targetDir -File) {
                    if ($expected -notcontains $extra.Name) {
                        $mismatches.Add("$($skill.FullName): unexpected $($extra.Name)")
                    }
                }
            } else {
                $mismatches.Add("$($skill.FullName): scripts directory missing")
            }

            if ($expectedReferences.Count -eq 0) {
                if (Test-Path -LiteralPath $referenceTargetDir -PathType Container) {
                    $mismatches.Add("$($skill.FullName): unexpected references directory")
                }
            } elseif (-not (Test-Path -LiteralPath $referenceTargetDir -PathType Container)) {
                $mismatches.Add("$($skill.FullName): references directory missing")
            } else {
                foreach ($name in $expectedReferences) {
                    $src = Join-Path $ReferenceSourceDir $name
                    $dst = Join-Path $referenceTargetDir $name
                    if (-not (Compare-FileBytes $src $dst)) {
                        $mismatches.Add("$($skill.FullName): reference out of sync $name")
                    }
                }
                foreach ($extra in Get-ChildItem -LiteralPath $referenceTargetDir -Force) {
                    if ($expectedReferences -notcontains $extra.Name) {
                        $mismatches.Add("$($skill.FullName): unexpected reference $($extra.Name)")
                    }
                }
            }
        } else {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            foreach ($existing in Get-ChildItem -LiteralPath $targetDir -File -ErrorAction SilentlyContinue) {
                if ($expected -notcontains $existing.Name) {
                    Remove-Item -LiteralPath $existing.FullName -Force
                }
            }
            foreach ($name in $expected) {
                Copy-Item -LiteralPath (Join-Path $SourceDir $name) -Destination (Join-Path $targetDir $name) -Force
            }

            if ($expectedReferences.Count -eq 0) {
                if (Test-Path -LiteralPath $referenceTargetDir -PathType Container) {
                    Remove-Item -LiteralPath $referenceTargetDir -Recurse -Force
                }
            } else {
                if (Test-Path -LiteralPath $referenceTargetDir -PathType Container) {
                    Remove-Item -LiteralPath $referenceTargetDir -Recurse -Force
                }
                New-Item -ItemType Directory -Path $referenceTargetDir -Force | Out-Null
                foreach ($name in $expectedReferences) {
                    Copy-Item -LiteralPath (Join-Path $ReferenceSourceDir $name) -Destination (Join-Path $referenceTargetDir $name) -Force
                }
            }
        }
    }
}

if ($Check) {
    if ($mismatches.Count) {
        foreach ($mismatch in $mismatches) { Write-Error $mismatch -ErrorAction Continue }
        exit 1
    }
    Write-Output "skill bundled scripts are in sync"
}
