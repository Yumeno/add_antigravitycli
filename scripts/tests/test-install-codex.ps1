$ErrorActionPreference = "Continue"
$Installer = Join-Path (Split-Path $PSScriptRoot -Parent) "install-for-codex.ps1"
$Root = Join-Path ([IO.Path]::GetTempPath()) ("add_antigravitycli_インストール検証_" + [guid]::NewGuid().ToString("N"))
$Dest = Join-Path $Root "install root"
$Names = @("ask-antigravity", "ask-antigravity-with-context", "antigravity-implement", "list-antigravity-models", "set-antigravity-model")
$passed = 0; $failed = 0; $skipped = 0
function Test-Case($Name, [scriptblock]$Body) {
    try { $result = & $Body; if ($result -eq "SKIP") { $script:skipped++; Write-Host "SKIP $Name" } else { $script:passed++; Write-Host "PASS $Name" } }
    catch { $script:failed++; Write-Host "FAIL $Name -- $_" }
}
function Install { param($D = $Dest) & powershell -NoProfile -ExecutionPolicy Bypass -File $Installer -DestinationRoot $D; if ($LASTEXITCODE -ne 0) { throw "installer failed" } }
try {
    Test-Case "installs exactly five managed skills" { Install; foreach ($n in $Names) { if (-not (Test-Path (Join-Path $Dest "skills\$n\SKILL.md"))) { throw $n } } }
    Test-Case "installs bundled helper directories" { foreach ($n in $Names) { foreach ($f in @("antigravity-wrapper.ps1", "antigravity-wrapper.sh")) { if (-not (Test-Path (Join-Path $Dest "skills\$n\scripts\$f"))) { throw $f } } }; foreach ($f in @("antigravity-implement.ps1", "antigravity-implement.sh", "antigravity-verify.ps1", "antigravity-verify.sh", "antigravity-implement-safety.txt", "antigravity-artifact.ps1", "antigravity-artifact.sh")) { if (-not (Test-Path (Join-Path $Dest "skills\antigravity-implement\scripts\$f"))) { throw $f } } }
    Test-Case "does not leave legacy placeholders" { if (Select-String -Path (Join-Path $Dest "skills\*\SKILL.md") -SimpleMatch '{{SCRIPTS_ROOT}}' -ErrorAction SilentlyContinue) { throw "placeholder" } }
    Test-Case "preserves unrelated skills and replaces managed skill" { New-Item -ItemType Directory -Force -Path (Join-Path $Dest "skills\unrelated") | Out-Null; Set-Content (Join-Path $Dest "skills\unrelated\keep.txt") x; Set-Content (Join-Path $Dest "skills\ask-antigravity\stale.txt") x; Install; if (-not (Test-Path (Join-Path $Dest "skills\unrelated\keep.txt")) -or (Test-Path (Join-Path $Dest "skills\ask-antigravity\stale.txt"))) { throw "preservation" } }
    Test-Case "is idempotent" { Install; Install }
    Test-Case "absorbs stale new artifacts" { New-Item -ItemType Directory -Force -Path (Join-Path $Dest "skills\ask-antigravity.new") | Out-Null; Install; if (Test-Path (Join-Path $Dest "skills\ask-antigravity.new")) { throw "new" } }
    Test-Case "absorbs stale old artifacts (crash recovery)" { Move-Item -LiteralPath (Join-Path $Dest "skills\ask-antigravity") -Destination (Join-Path $Dest "skills\ask-antigravity.old"); Install; if (-not (Test-Path (Join-Path $Dest "skills\ask-antigravity\SKILL.md")) -or (Test-Path (Join-Path $Dest "skills\ask-antigravity.old")) -or (Test-Path (Join-Path $Dest "skills\ask-antigravity.new"))) { throw "crash recovery" } }
    Test-Case "preserves old recovery copy when staging fails" {
        Install; $skills = Join-Path $Dest "skills"; $final = Join-Path $skills "ask-antigravity"; $old = "$final.old"; Move-Item -LiteralPath $final -Destination $old; Set-Content (Join-Path $old "recovery-sentinel.txt") x
        $originalSddl = (Get-Acl -LiteralPath $skills).Sddl; $acl = Get-Acl -LiteralPath $skills; $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, [Security.AccessControl.FileSystemRights]::Write, "ContainerInherit,ObjectInherit", "None", "Deny")
        try { $acl.AddAccessRule($rule); Set-Acl -LiteralPath $skills -AclObject $acl; try { Set-Content (Join-Path $skills ".permission-probe.txt") x -ErrorAction Stop; Remove-Item (Join-Path $skills ".permission-probe.txt") -Force; return "SKIP" } catch {}; $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Installer -DestinationRoot $Dest 2>&1; $code = $LASTEXITCODE; if ($code -eq 0 -or -not (Test-Path $old) -or "$out" -notmatch "Failed to stage new skill:") { throw "staging failure did not preserve old recovery copy: $out" } }
        finally { $aclRestore = Get-Acl -LiteralPath $skills; $aclRestore.SetSecurityDescriptorSddlForm($originalSddl); Set-Acl -LiteralPath $skills -AclObject $aclRestore -ErrorAction Stop; if (Test-Path $old) { Move-Item -LiteralPath $old -Destination $final } }
    }
    Test-Case "read-only skills directory preserves prior content on failure" {
        Install; $skills = Join-Path $Dest "skills"; $sentinel = Join-Path $skills "ask-antigravity\previous.txt"; Set-Content $sentinel x
        $originalSddl = (Get-Acl -LiteralPath $skills).Sddl; $acl = Get-Acl -LiteralPath $skills; $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, [Security.AccessControl.FileSystemRights]::Write, "ContainerInherit,ObjectInherit", "None", "Deny")
        try { $acl.AddAccessRule($rule); Set-Acl -LiteralPath $skills -AclObject $acl; try { Set-Content (Join-Path $skills ".permission-probe.txt") x -ErrorAction Stop; Remove-Item (Join-Path $skills ".permission-probe.txt") -Force; return "SKIP" } catch {}; $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Installer -DestinationRoot $Dest 2>&1; $code = $LASTEXITCODE; if ($code -eq 0 -or -not (Test-Path $sentinel)) { throw "read-only failure did not preserve prior content: $out" } }
        finally { $aclRestore = Get-Acl -LiteralPath $skills; $aclRestore.SetSecurityDescriptorSddlForm($originalSddl); Set-Acl -LiteralPath $skills -AclObject $aclRestore -ErrorAction Stop }
    }
    Test-Case "cleans new and old promotion artifacts" { if (Get-ChildItem (Join-Path $Dest skills) -Force | Where-Object { $_.Name -match '\.(new|old)$' }) { throw "artifact" } }
    Test-Case "cleans staging directories" { if (Get-ChildItem $Dest -Force | Where-Object { $_.Name -like '.add-antigravitycli-stage-*' }) { throw "stage" } }
    Test-Case "PowerShell sources use UTF-8 BOM" { foreach ($f in @($Installer, $PSCommandPath)) { [byte[]]$b = [IO.File]::ReadAllBytes($f); if ($b.Length -lt 3 -or $b[0] -ne 239 -or $b[1] -ne 187 -or $b[2] -ne 191) { throw "BOM $f" } } }
} finally { Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "Passed: $passed; Failed: $failed; Skipped: $skipped"
if ($failed) { exit 1 }
