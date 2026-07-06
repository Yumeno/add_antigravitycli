param(
    [Parameter(Mandatory=$true)][string]$SpecFile,
    [Parameter(Mandatory=$true)][string]$Repo,
    [string]$Attachment = "",
    [string]$AttachmentList = "",
    [string]$Model = "",
    [int]$Timeout = 600
)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
function Fail([int]$Code,[string]$Message) {
    Write-Output "[ANTIGRAVITY_IMPLEMENT_ERROR] $Message"; [Console]::Error.WriteLine("Error: $Message"); exit $Code
}
if (-not (Test-Path -LiteralPath $SpecFile -PathType Leaf)) { Fail 1 "Spec file not found: $SpecFile" }
if (-not (Test-Path -LiteralPath $Repo -PathType Container)) { Fail 1 "Repository not found: $Repo" }
if ($Timeout -le 0) { Fail 1 "Timeout must be greater than zero." }
$requestedRoot = (Resolve-Path -LiteralPath $Repo).Path
$root = & git -C $requestedRoot -c core.excludesFile= rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0 -or -not $root) { Fail 1 "Target is not a Git working tree" }
$root = (Resolve-Path -LiteralPath ($root | Select-Object -First 1)).Path
$dirty = & git -C $root -c core.excludesFile= status --porcelain=v1 --untracked-files=all
if ($LASTEXITCODE -ne 0) { Fail 1 "Could not read Git status" }
if ($dirty) { Fail 1 "Working tree is not clean. Commit or stash changes before delegation." }
$verify = Join-Path $PSScriptRoot "antigravity-verify.ps1"
$wrapper = Join-Path $PSScriptRoot "antigravity-wrapper.ps1"
$snapshot = Join-Path $env:TEMP ("antigravity-verify-" + [guid]::NewGuid().ToString("N") + ".json")
$promptFile = Join-Path $env:TEMP ("antigravity-prompt-" + [guid]::NewGuid().ToString("N") + ".txt")
& powershell -NoProfile -ExecutionPolicy Bypass -File $verify snapshot -Repo $root -Snapshot $snapshot
if ($LASTEXITCODE -ne 0) { Fail $LASTEXITCODE "Could not create pre-execution snapshot." }
$spec = Get-Content -LiteralPath $SpecFile -Raw -Encoding UTF8
$safety = Get-Content -LiteralPath (Join-Path $PSScriptRoot "antigravity-implement-safety.txt") -Raw -Encoding UTF8
[IO.File]::WriteAllText($promptFile, "$safety`n`n---`n`n$spec", (New-Object Text.UTF8Encoding($false)))
try {
    $args = @("-PromptFile",$promptFile,"-WorkDir",$root,"-Timeout",[string]$Timeout)
    if ($Attachment) { $args += @("-Attachment", $Attachment) }
    if ($AttachmentList) { $args += @("-AttachmentList", $AttachmentList) }
    if ($Model) { $args += @("-Model",$Model) }
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $wrapper @args 2>&1
    $code = $LASTEXITCODE
    & powershell -NoProfile -ExecutionPolicy Bypass -File $verify check -Repo $root -Snapshot $snapshot
    $verifyCode = $LASTEXITCODE
    if ($verifyCode -ne 0) { Fail $verifyCode "Post-execution verification failed. Changes were not rolled back." }
    if ($code -ne 0) { Fail $code (($output | Out-String).Trim()) }
    Write-Output $output
} finally {
    Remove-Item -LiteralPath $snapshot -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $promptFile -Force -ErrorAction SilentlyContinue
}
