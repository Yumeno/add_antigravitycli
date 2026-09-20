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

# Win32 real-path resolver: Resolve-Path/GetFullPath never resolve reparse
# points (symlinks/junctions), and .Target on Get-Item only shows the
# *immediate* link target, not a chain through further ancestor junctions.
# CreateFileW + GetFinalPathNameByHandleW ask the filesystem for the true
# underlying path, resolving every hop in one call -- this is the only
# reliable way to defeat an ancestor junction planted anywhere above a path.
Add-Type -Namespace AntigravityWin32 -Name NativeMethods -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr CreateFileW(
    string lpFileName, uint dwDesiredAccess, uint dwShareMode,
    IntPtr lpSecurityAttributes, uint dwCreationDisposition,
    uint dwFlagsAndAttributes, IntPtr hTemplateFile);

[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern uint GetFinalPathNameByHandleW(
    IntPtr hFile, System.Text.StringBuilder lpszFilePath, uint cchFilePath, uint dwFlags);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(IntPtr hObject);
'@

# Resolves $Path (which must exist as a directory) to its canonical, fully
# reparse-point-resolved absolute path. Throws (via Fail) if the OS cannot
# open or resolve it.
function Get-Win32RealPath([string]$Path) {
    $INVALID_HANDLE = [IntPtr]::new(-1)
    $FILE_SHARE_READ = 0x00000001
    $FILE_SHARE_WRITE = 0x00000002
    $FILE_SHARE_DELETE = 0x00000004
    $OPEN_EXISTING = 3
    $FILE_FLAG_BACKUP_SEMANTICS = 0x02000000
    $handle = [AntigravityWin32.NativeMethods]::CreateFileW(
        $Path, 0, ($FILE_SHARE_READ -bor $FILE_SHARE_WRITE -bor $FILE_SHARE_DELETE),
        [IntPtr]::Zero, $OPEN_EXISTING, $FILE_FLAG_BACKUP_SEMANTICS, [IntPtr]::Zero)
    if ($handle -eq $INVALID_HANDLE) { Fail 1 "Could not open path to resolve its real location: $Path" }
    try {
        $sb = New-Object Text.StringBuilder 32768
        $len = [AntigravityWin32.NativeMethods]::GetFinalPathNameByHandleW($handle, $sb, $sb.Capacity, 0)
        if ($len -eq 0 -or $len -ge $sb.Capacity) { Fail 1 "Could not resolve the real path of: $Path" }
        $resolved = $sb.ToString(0, [int]$len)
    } finally {
        [void][AntigravityWin32.NativeMethods]::CloseHandle($handle)
    }
    if ($resolved.StartsWith('\\?\UNC\')) { $resolved = '\\' + $resolved.Substring(8) }
    elseif ($resolved.StartsWith('\\?\')) { $resolved = $resolved.Substring(4) }
    return $resolved
}

$root = Get-Win32RealPath $root

# Display-only: join a list with commas, replacing embedded newlines with the
# literal text "\n" so a single log line cannot be split by a crafted filename.
# Never feed this back into comparison logic -- arrays/sets are the source of truth.
function Join-Display([string[]]$Items) {
    return (($Items | ForEach-Object { $_ -replace "`r?`n", '\n' }) -join ',')
}

function Get-SessionPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { Fail 1 "Session directory not found: $parent" }
    # Resolve the parent through the real Win32 API: this follows every
    # reparse-point hop in the chain (not just the immediate parent), so an
    # ancestor junction anywhere above the session path cannot smuggle it
    # inside the repository.
    $realParent = Get-Win32RealPath $parent
    $full = Join-Path $realParent (Split-Path -Leaf $full)
    if ($full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or ($full -ieq $root)) {
        Fail 1 "Session file must be outside the repository: $Path"
    }
    return $full
}
function Test-IsLink([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}
function New-FileExclusive([string]$Path) {
    # CreateNew fails if the file already exists, so a pre-existing link at
    # this path can never be followed when we first materialize it.
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
        $fs.Close()
    } catch {
        Fail 1 "Could not create session file exclusively: $Path"
    }
}

function Get-DirtyPaths {
    # Use -z output so filenames with spaces/unicode are unambiguous. For rename
    # entries ("R  old\0new\0") the old path is a separate NUL field that follows.
    # Fails closed: any non-zero git exit means the caller must not proceed.
    $raw = & git -C $root -c core.excludesFile= status --porcelain=v1 --untracked-files=all -z 2>$null
    if ($LASTEXITCODE -ne 0) { Fail 1 "Could not read Git status." }
    # PowerShell's native-output capture splits on newlines, not NUL, so a
    # multi-line $raw must be rejoined with actual newlines before splitting on
    # NUL -- otherwise a NUL-adjacent newline would be silently dropped.
    $joined = ($raw -join "`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($joined)
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

function Test-OwnedPathValid([string]$Path) {
    # Non-empty, relative, forward-slash, no ".." segment, not absolute.
    if ([string]::IsNullOrEmpty($Path)) { Fail 1 "Session file is invalid: empty owned entry." }
    if ($Path.StartsWith("/") -or [IO.Path]::IsPathRooted($Path)) { Fail 1 "Session file is invalid: owned entry is absolute: $Path" }
    if ($Path -match '^[A-Za-z]:') { Fail 1 "Session file is invalid: owned entry is absolute: $Path" }
    if ($Path.Contains("\")) { Fail 1 "Session file is invalid: owned entry must use forward slashes: $Path" }
    foreach ($seg in $Path -split '/') { if ($seg -eq '..') { Fail 1 "Session file is invalid: owned entry contains '..': $Path" } }
}

function Read-SessionStrict([string]$Path, [string]$ExpectedSnapshot) {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    try { $obj = $raw | ConvertFrom-Json } catch { Fail 1 "Session file is invalid: not valid JSON." }
    $props = @($obj.PSObject.Properties | ForEach-Object { $_.Name })
    $dupes = @($props | Group-Object | Where-Object { $_.Count -gt 1 })
    if ($dupes.Count) { Fail 1 "Session file is invalid: duplicated field '$($dupes[0].Name)'." }
    $known = @("version","repo","snapshot","round","owned")
    $unknown = @($props | Where-Object { $known -notcontains $_ })
    if ($unknown.Count) { Fail 1 "Session file is invalid: unknown field '$($unknown[0])'." }
    foreach ($req in @("version","repo","snapshot","round")) {
        if (-not ($props -contains $req)) { Fail 1 "Session file is invalid: missing field '$req'." }
    }
    if ($obj.version -ne 1) { Fail 1 "Session file is invalid: unsupported version." }
    if ($obj.repo -isnot [string] -or $obj.repo -ine $root) { Fail 1 "Session belongs to a different repository: $($obj.repo)" }
    if ($obj.snapshot -isnot [string] -or $obj.snapshot -ine $ExpectedSnapshot) { Fail 1 "Session file is invalid: unexpected snapshot path: $($obj.snapshot)" }
    $roundOk = $false
    if ($obj.round -is [int] -or $obj.round -is [long]) { if ([int64]$obj.round -ge 1) { $roundOk = $true } }
    if (-not $roundOk) { Fail 1 "Session file is invalid: round is not a positive integer: $($obj.round)" }
    $ownedList = @()
    if ($props -contains "owned") {
        if ($null -ne $obj.owned) { $ownedList = @($obj.owned) }
    }
    foreach ($p in $ownedList) { Test-OwnedPathValid ([string]$p) }
    return [ordered]@{ round = [int]$obj.round; owned = @($ownedList | ForEach-Object { [string]$_ }) }
}

function Write-Session([string]$Path, [string]$Snap, [int]$Round, [string[]]$Owned) {
    $obj = [ordered]@{ version=1; repo=$root; snapshot=$Snap; round=$Round; owned=@($Owned) }
    [IO.File]::WriteAllText($Path, ($obj | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}

$lockPath = $null
$lockHeld = $false
function Enter-SessionLock([string]$Path) {
    $script:lockPath = "$Path.lock"
    try {
        $fs = [IO.File]::Open($script:lockPath, [IO.FileMode]::CreateNew)
        $writer = New-Object IO.StreamWriter($fs, (New-Object Text.UTF8Encoding($false)))
        $iso = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $writer.Write("pid=$PID time=$iso`n")
        $writer.Flush(); $writer.Close(); $fs.Close()
        $script:lockHeld = $true
    } catch {
        $info = ""
        if (Test-Path -LiteralPath $script:lockPath -PathType Leaf) {
            $info = (Get-Content -LiteralPath $script:lockPath -Raw -ErrorAction SilentlyContinue)
        }
        Fail 1 "Session is locked by another run (lock: $($script:lockPath), $info). Remove the lock file manually if that run is no longer active."
    }
}
function Exit-SessionLock {
    if ($script:lockHeld) {
        Remove-Item -LiteralPath $script:lockPath -Force -ErrorAction SilentlyContinue
        $script:lockHeld = $false
    }
}

if ($Session) {
    $sessionPath = Get-SessionPath $Session
    $snapshotSidecar = "$sessionPath.snapshot"
    # Refuse if either path already exists as a link: following it could write
    # session data through an attacker-controlled link.
    if (Test-IsLink $sessionPath) { Fail 1 "Session file must not be a link." }
    if (Test-IsLink $snapshotSidecar) { Fail 1 "Session file must not be a link." }
}

if ($CloseSession) {
    Enter-SessionLock $sessionPath
    try {
        if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) { Fail 1 "Session file not found: $Session" }
        Remove-Item -LiteralPath $sessionPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $snapshotSidecar -Force -ErrorAction SilentlyContinue
        Write-Output "[ANTIGRAVITY_SESSION] closed path=$sessionPath"
        exit 0
    } finally { Exit-SessionLock }
}

if ($Session) { Enter-SessionLock $sessionPath }

$isContinuation = $false
$owned = @()
$round = 1

try {
    if ($Session -and (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
        $isContinuation = $true
        $parsed = Read-SessionStrict $sessionPath $snapshotSidecar
        $snapshot = $snapshotSidecar
        if (-not (Test-Path -LiteralPath $snapshot -PathType Leaf)) { Fail 1 "Session snapshot not found: $snapshot" }
        # Verify the sidecar snapshot's own repo field matches before using it.
        $snapObj = Get-Content -LiteralPath $snapshot -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($snapObj.repo -and ($snapObj.repo -ine $root)) { Fail 1 "Session snapshot belongs to a different repository: $($snapObj.repo)" }
        $owned = @($parsed.owned)
        $round = [int]$parsed.round + 1
        $dirtyNow = Get-DirtyPaths
        $ownedSet = New-Object Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
        foreach ($p in $owned) { [void]$ownedSet.Add($p) }
        $outside = @($dirtyNow | Where-Object { -not $ownedSet.Contains($_) })
        if ($outside.Count) {
            if (-not $AdoptChanges) {
                Fail 1 "Working tree has changes outside this delegation session: $(Join-Display $outside)"
            }
            $owned = @($owned + $outside | Sort-Object -Unique)
            Write-Output "[ANTIGRAVITY_SESSION] adopted=$($outside.Count) paths=$(Join-Display $outside)"
            [Console]::Error.WriteLine("ANTIGRAVITY: adopted=$(Join-Display $outside)")
        }
    } else {
        if ($AdoptChanges) { Fail 1 "-AdoptChanges is only valid when continuing a session." }
        $dirty = & git -C $root -c core.excludesFile= status --porcelain=v1 --untracked-files=all
        if ($LASTEXITCODE -ne 0) { Fail 1 "Could not read Git status" }
        if ($dirty) { Fail 1 "Working tree is not clean. Commit or stash changes before delegation." }
        if ($Session) {
            $snapshot = $snapshotSidecar
            # antigravity-verify.ps1 would silently overwrite an existing file
            # (including a pre-existing link) at -Snapshot, so refuse here first.
            if (Test-Path -LiteralPath $snapshot) { Fail 1 "Session snapshot already exists: $snapshot" }
        } else {
            $snapshot = Join-Path $env:TEMP ("antigravity-verify-" + [guid]::NewGuid().ToString("N") + ".json")
        }
        & powershell -NoProfile -ExecutionPolicy Bypass -File $verify snapshot -Repo $root -Snapshot $snapshot | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail $LASTEXITCODE "Could not create pre-execution snapshot." }
        if ($Session) {
            New-FileExclusive $sessionPath
            Write-Session $sessionPath $snapshot 1 @()
        }
    }

    $promptFile = Join-Path $env:TEMP ("antigravity-prompt-" + [guid]::NewGuid().ToString("N") + ".txt")
    $spec = Get-Content -LiteralPath $SpecFile -Raw -Encoding UTF8
    $safety = Get-Content -LiteralPath (Join-Path $PSScriptRoot "antigravity-implement-safety.txt") -Raw -Encoding UTF8
    [IO.File]::WriteAllText($promptFile, "$safety`n`n---`n`n$spec", (New-Object Text.UTF8Encoding($false)))
    try {
        $procArgs = @("-PromptFile",$promptFile,"-WorkDir",$root,"-Timeout",[string]$Timeout)
        if ($Attachment) { $procArgs += @("-Attachment", $Attachment) }
        if ($AttachmentList) { $procArgs += @("-AttachmentList", $AttachmentList) }
        if ($Model) { $procArgs += @("-Model",$Model) }
        # Do not capture the wrapper output: it is emitted as soon as the wrapper
        # finishes, so the agent's report precedes the verification log (same
        # order as antigravity-implement.sh).
        & powershell -NoProfile -ExecutionPolicy Bypass -File $wrapper @procArgs
        $code = $LASTEXITCODE
        & powershell -NoProfile -ExecutionPolicy Bypass -File $verify check -Repo $root -Snapshot $snapshot
        $verifyCode = $LASTEXITCODE

        # Failure ordering precedence (most severe first):
        #   1. session write failure -> exit 4, reporting the wrapper/verify codes too
        #   2. verify (check) failure -> its own exit code
        #   3. wrapper failure -> its own exit code
        #   4. success -> exit 0
        $sessionWriteFailed = $false
        if ($Session) {
            $finalDirty = Get-DirtyPaths
            $ownedSet = New-Object Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
            foreach ($p in $owned) { [void]$ownedSet.Add($p) }
            foreach ($p in $finalDirty) { [void]$ownedSet.Add($p) }
            $newOwned = @($ownedSet | Sort-Object)
            try {
                Write-Session $sessionPath $snapshot $round $newOwned
                Write-Output "[ANTIGRAVITY_SESSION] round=$round owned=$($newOwned.Count) path=$sessionPath"
                [Console]::Error.WriteLine("ANTIGRAVITY: owned=$(Join-Display $newOwned)")
            } catch { $sessionWriteFailed = $true }
        }

        if ($sessionWriteFailed) {
            [Console]::Error.WriteLine("[ANTIGRAVITY_IMPLEMENT_ERROR] Could not update session file $sessionPath (wrapper_exit=$code verify_exit=$verifyCode)")
            exit 4
        }
        if ($verifyCode -ne 0) { Fail $verifyCode "Post-execution verification failed. Changes were not rolled back." }
        if ($code -ne 0) { Fail $code "Antigravity run failed with exit code $code. See the wrapper output above." }
    } finally {
        if (-not $Session) {
            Remove-Item -LiteralPath $snapshot -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $promptFile -Force -ErrorAction SilentlyContinue
    }
} finally {
    Exit-SessionLock
}
