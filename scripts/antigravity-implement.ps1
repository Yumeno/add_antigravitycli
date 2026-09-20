param(
    [string]$SpecFile = "",
    [Parameter(Mandatory=$true)][string]$Repo,
    [string]$Attachment = "",
    [string]$AttachmentList = "",
    [string]$Model = "",
    [int]$Timeout = 600,
    [string]$Session = "",
    [switch]$CloseSession,
    [switch]$AdoptChanges
)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
function Fail([int]$Code,[string]$Message) {
    Write-Output "[ANTIGRAVITY_IMPLEMENT_ERROR] $Message"; [Console]::Error.WriteLine("Error: $Message"); exit $Code
}
if ($CloseSession -and -not $Session) { Fail 1 "-CloseSession requires -Session." }
if ($CloseSession -and $SpecFile) { Fail 1 "-CloseSession cannot be combined with -SpecFile." }
if ($AdoptChanges -and (-not $Session -or $CloseSession)) { Fail 1 "-AdoptChanges is only valid when continuing a session." }
if (-not $CloseSession -and -not $SpecFile) { Fail 1 "-SpecFile is required unless -CloseSession is given." }
if ($SpecFile -and -not (Test-Path -LiteralPath $SpecFile -PathType Leaf)) { Fail 1 "Spec file not found: $SpecFile" }
if (-not (Test-Path -LiteralPath $Repo -PathType Container)) { Fail 1 "Repository not found: $Repo" }
if ($Timeout -le 0) { Fail 1 "Timeout must be greater than zero." }
$requestedRoot = (Resolve-Path -LiteralPath $Repo).Path
$root = & git -C $requestedRoot -c core.excludesFile= rev-parse --show-toplevel
if ($LASTEXITCODE -ne 0 -or -not $root) { Fail 1 "Target is not a Git working tree" }
$root = (Resolve-Path -LiteralPath ($root | Select-Object -First 1)).Path
$verify = Join-Path $PSScriptRoot "antigravity-verify.ps1"
$wrapper = Join-Path $PSScriptRoot "antigravity-wrapper.ps1"

function Get-SessionPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or ($full -ieq $root)) {
        Fail 1 "Session file must be outside the repository: $Path"
    }
    return $full
}
function Get-DirtyPaths {
    # Use -z output so filenames with spaces/unicode are unambiguous. For rename
    # entries ("R  old\0new\0") the old path is a separate NUL field that follows.
    $raw = & git -C $root -c core.excludesFile= status --porcelain=v1 --untracked-files=all -z
    if ($LASTEXITCODE -ne 0) { Fail 1 "Could not read Git status" }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($raw -join "`0"))
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $fields = New-Object Collections.Generic.List[string]
    foreach ($f in ($text -split "`0")) { if ($f -ne "") { $fields.Add($f) } }
    $paths = New-Object Collections.Generic.List[string]
    $i = 0
    while ($i -lt $fields.Count) {
        $entry = $fields[$i]
        if ($entry.Length -lt 3) { $i++; continue }
        $status = $entry.Substring(0,2)
        $path = $entry.Substring(3)
        $paths.Add($path.Replace("\","/"))
        if ($status[0] -eq 'R' -or $status[1] -eq 'R') {
            $i++
            if ($i -lt $fields.Count) { $paths.Add($fields[$i].Replace("\","/")) }
        }
        $i++
    }
    return @($paths | Sort-Object -Unique)
}
function Read-Session([string]$Path) {
    $obj = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    return $obj
}
function Write-Session([string]$Path, $Obj) {
    [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}

if ($Session) {
    $sessionPath = Get-SessionPath $Session
    $snapshotSidecar = "$sessionPath.snapshot"
}

if ($CloseSession) {
    if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) { Fail 1 "Session file not found: $Session" }
    Remove-Item -LiteralPath $sessionPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $snapshotSidecar -Force -ErrorAction SilentlyContinue
    Write-Output "[ANTIGRAVITY_SESSION] closed path=$sessionPath"
    exit 0
}

$isContinuation = $false
$owned = @()
$round = 1

if ($Session -and (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
    $isContinuation = $true
    $sessionObj = Read-Session $sessionPath
    if ($sessionObj.repo -ine $root) { Fail 1 "Session belongs to a different repository: $($sessionObj.repo)" }
    if (-not (Test-Path -LiteralPath $sessionObj.snapshot -PathType Leaf)) { Fail 1 "Session snapshot not found: $($sessionObj.snapshot)" }
    $snapshot = $sessionObj.snapshot
    $owned = @($sessionObj.owned)
    $round = [int]$sessionObj.round + 1
    $dirtyNow = Get-DirtyPaths
    $ownedSet = New-Object Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $owned) { [void]$ownedSet.Add($p) }
    $outside = @($dirtyNow | Where-Object { -not $ownedSet.Contains($_) })
    if ($outside.Count) {
        if (-not $AdoptChanges) {
            Fail 1 "Working tree has changes outside this delegation session: $($outside -join ',')"
        }
        $owned = @($owned + $outside | Sort-Object -Unique)
        Write-Output "[ANTIGRAVITY_SESSION] adopted=$($outside.Count) paths=$($outside -join ',')"
        [Console]::Error.WriteLine("ANTIGRAVITY: adopted=$($outside -join ',')")
    }
} else {
    if ($AdoptChanges) { Fail 1 "-AdoptChanges is only valid when continuing a session." }
    $dirty = & git -C $root -c core.excludesFile= status --porcelain=v1 --untracked-files=all
    if ($LASTEXITCODE -ne 0) { Fail 1 "Could not read Git status" }
    if ($dirty) { Fail 1 "Working tree is not clean. Commit or stash changes before delegation." }
    if ($Session) {
        $snapshot = $snapshotSidecar
    } else {
        $snapshot = Join-Path $env:TEMP ("antigravity-verify-" + [guid]::NewGuid().ToString("N") + ".json")
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File $verify snapshot -Repo $root -Snapshot $snapshot | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail $LASTEXITCODE "Could not create pre-execution snapshot." }
    if ($Session) {
        $sessionObj = [ordered]@{ version=1; repo=$root; snapshot=$snapshot; round=1; owned=@() }
        Write-Session $sessionPath $sessionObj
    }
}

$promptFile = Join-Path $env:TEMP ("antigravity-prompt-" + [guid]::NewGuid().ToString("N") + ".txt")
$spec = Get-Content -LiteralPath $SpecFile -Raw -Encoding UTF8
$safety = Get-Content -LiteralPath (Join-Path $PSScriptRoot "antigravity-implement-safety.txt") -Raw -Encoding UTF8
[IO.File]::WriteAllText($promptFile, "$safety`n`n---`n`n$spec", (New-Object Text.UTF8Encoding($false)))
try {
    $args = @("-PromptFile",$promptFile,"-WorkDir",$root,"-Timeout",[string]$Timeout)
    if ($Attachment) { $args += @("-Attachment", $Attachment) }
    if ($AttachmentList) { $args += @("-AttachmentList", $AttachmentList) }
    if ($Model) { $args += @("-Model",$Model) }
    # Do not capture the wrapper output: it is emitted as soon as the wrapper
    # finishes, so the agent's report precedes the verification log (same
    # order as antigravity-implement.sh).
    & powershell -NoProfile -ExecutionPolicy Bypass -File $wrapper @args
    $code = $LASTEXITCODE
    & powershell -NoProfile -ExecutionPolicy Bypass -File $verify check -Repo $root -Snapshot $snapshot
    $verifyCode = $LASTEXITCODE

    if ($Session) {
        $finalDirty = Get-DirtyPaths
        $ownedSet = New-Object Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
        foreach ($p in $owned) { [void]$ownedSet.Add($p) }
        foreach ($p in $finalDirty) { [void]$ownedSet.Add($p) }
        $newOwned = @($ownedSet | Sort-Object)
        $sessionObj = [ordered]@{ version=1; repo=$root; snapshot=$snapshot; round=$round; owned=$newOwned }
        Write-Session $sessionPath $sessionObj
        Write-Output "[ANTIGRAVITY_SESSION] round=$round owned=$($newOwned.Count) path=$sessionPath"
        [Console]::Error.WriteLine("ANTIGRAVITY: owned=$($newOwned -join ',')")
    }

    if ($verifyCode -ne 0) { Fail $verifyCode "Post-execution verification failed. Changes were not rolled back." }
    if ($code -ne 0) { Fail $code "Antigravity run failed with exit code $code. See the wrapper output above." }
} finally {
    if (-not $Session) {
        Remove-Item -LiteralPath $snapshot -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $promptFile -Force -ErrorAction SilentlyContinue
}
