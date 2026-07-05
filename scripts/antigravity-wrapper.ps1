param(
    [string]$Prompt = "",
    [string]$ContextFile = "",
    [string]$Model = "",
    [string]$WorkDir = "",
    [int]$Timeout = 180,
    [string]$SetModel = "",
    [switch]$ShowModel
)

[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
$ErrorSentinel = "[ANTIGRAVITY_WRAPPER_ERROR]"
$ConfigFile = Join-Path $PSScriptRoot "antigravity-wrapper.conf"
$ModelRegex = '^[A-Za-z0-9._:/-]+$'
$OwnedWorkDir = ""

function Fail([int]$Code, [string]$Message) {
    if ($script:OwnedWorkDir) {
        Remove-Item -LiteralPath $script:OwnedWorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Output "$ErrorSentinel $Message"
    [Console]::Error.WriteLine("Error: $Message")
    exit $Code
}
function Validate-Model([string]$Value, [string]$Source) {
    if ($Value -notmatch $ModelRegex) { Fail 1 "model name from $Source contains unsafe characters" }
}
function Read-ConfiguredModel {
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) { return "" }
    foreach ($line in Get-Content -LiteralPath $ConfigFile -Encoding UTF8) {
        if ($line.Trim() -match '^model\s*=\s*(.*?)\s*$') { return $matches[1] }
    }
    return ""
}
function Quote-Arg([string]$Value) {
    if ($Value -notmatch '[\s"]' -and $Value) { return $Value }
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

if ($SetModel) {
    Validate-Model $SetModel "-SetModel"
    $text = "# antigravity-wrapper.conf`r`n# Priority: CLI > ANTIGRAVITY_WRAPPER_MODEL > this file > agy default`r`nmodel=$SetModel`r`n"
    [IO.File]::WriteAllText($ConfigFile, $text, (New-Object Text.UTF8Encoding($false)))
    Write-Output "Saved model='$SetModel' to $ConfigFile"
    exit 0
}

$modelSource = ""
if ($Model) { Validate-Model $Model "-Model"; $modelSource = "cli" }
elseif ($env:ANTIGRAVITY_WRAPPER_MODEL) {
    $Model = $env:ANTIGRAVITY_WRAPPER_MODEL; Validate-Model $Model "environment"; $modelSource = "env"
} else {
    $Model = Read-ConfiguredModel
    if ($Model) { Validate-Model $Model "config"; $modelSource = "config" }
}
if ($ShowModel) {
    if ($Model) { Write-Output "model=$Model (source: $modelSource)" }
    else { Write-Output "model=(unset; agy default will be used)" }
    Write-Output "config_file=$ConfigFile"
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Prompt)) { Fail 1 "-Prompt is required." }
if ($Timeout -le 0) { Fail 1 "-Timeout must be greater than zero." }
if ($ContextFile) {
    if (-not (Test-Path -LiteralPath $ContextFile -PathType Leaf)) { Fail 1 "Context file not found: $ContextFile" }
    $context = Get-Content -LiteralPath $ContextFile -Raw -Encoding UTF8
    $Prompt = "## Context`n`n$context`n`n---`n`n## Request`n`n$Prompt"
}
if (-not $WorkDir) {
    $WorkDir = Join-Path $env:TEMP ("antigravity-wrapper-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $WorkDir -ErrorAction Stop | Out-Null
    $OwnedWorkDir = $WorkDir
}
if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) { Fail 1 "workdir does not exist: $WorkDir" }
try { $agy = (Get-Command agy -ErrorAction Stop).Source } catch { Fail 1 "'agy' CLI not found in PATH." }

$resolvedWorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
$agyArgs = @(
    "--print", "--print-timeout", ("{0}s" -f $Timeout),
    "--sandbox", "--new-project", "--add-dir", $resolvedWorkDir
)
if ($Model) { $agyArgs += @("--model", $Model); [Console]::Error.WriteLine("MODEL: $Model") }
$info = New-Object Diagnostics.ProcessStartInfo
if ([IO.Path]::GetExtension($agy) -ieq ".cmd" -or [IO.Path]::GetExtension($agy) -ieq ".bat") {
    $info.FileName = $env:ComSpec
    $inner = (@($agy) + $agyArgs | ForEach-Object { Quote-Arg $_ }) -join " "
    $info.Arguments = '/d /s /c "' + $inner + '"'
} else {
    $info.FileName = $agy
    $info.Arguments = ($agyArgs | ForEach-Object { Quote-Arg $_ }) -join " "
}
$info.WorkingDirectory = $resolvedWorkDir
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardInput = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true

try {
    $process = [Diagnostics.Process]::Start($info)
    $writer = New-Object IO.StreamWriter($process.StandardInput.BaseStream, (New-Object Text.UTF8Encoding($false)))
    $writer.Write($Prompt); $writer.Close()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($Timeout * 1000)) {
        & taskkill /T /F /PID $process.Id 2>$null | Out-Null
        $process.WaitForExit()
        Fail 2 "agy timed out after ${Timeout}s"
    }
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    if ($process.ExitCode -ne 0) { Fail $process.ExitCode "agy exited with status $($process.ExitCode). $($stderr.Trim())" }
    if ([string]::IsNullOrWhiteSpace($stdout)) { Fail 1 "agy returned empty output." }
    Write-Output $stdout.TrimEnd()
    if ($OwnedWorkDir) { Remove-Item -LiteralPath $OwnedWorkDir -Recurse -Force; $OwnedWorkDir = "" }
} catch { Fail 1 $_.Exception.Message }
