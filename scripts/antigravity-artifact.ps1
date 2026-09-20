param(
    [Parameter(Position=0, Mandatory=$true)][ValidateSet("import")][string]$Command,
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$Destination,
    [switch]$Overwrite
)
$ErrorActionPreference = "Stop"
function Fail([string]$Message) { Write-Output "[ANTIGRAVITY_ARTIFACT_ERROR] $Message"; exit 1 }

# Win32 real-path resolver (same approach as antigravity-implement.ps1): follows
# every reparse-point hop (symlink/junction) in one call, unlike Resolve-Path.
Add-Type -Namespace AntigravityWin32 -Name ArtifactNativeMethods -MemberDefinition @'
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

function Get-Win32RealPath([string]$Path) {
    $INVALID_HANDLE = [IntPtr]::new(-1)
    $FILE_SHARE_READ = 0x00000001
    $FILE_SHARE_WRITE = 0x00000002
    $FILE_SHARE_DELETE = 0x00000004
    $OPEN_EXISTING = 3
    $FILE_FLAG_BACKUP_SEMANTICS = 0x02000000
    $handle = [AntigravityWin32.ArtifactNativeMethods]::CreateFileW(
        $Path, 0, ($FILE_SHARE_READ -bor $FILE_SHARE_WRITE -bor $FILE_SHARE_DELETE),
        [IntPtr]::Zero, $OPEN_EXISTING, $FILE_FLAG_BACKUP_SEMANTICS, [IntPtr]::Zero)
    if ($handle -eq $INVALID_HANDLE) { Fail "Could not open path to resolve its real location: $Path" }
    try {
        $sb = New-Object Text.StringBuilder 32768
        $len = [AntigravityWin32.ArtifactNativeMethods]::GetFinalPathNameByHandleW($handle, $sb, $sb.Capacity, 0)
        if ($len -eq 0 -or $len -ge $sb.Capacity) { Fail "Could not resolve the real path of: $Path" }
        $resolved = $sb.ToString(0, [int]$len)
    } finally {
        [void][AntigravityWin32.ArtifactNativeMethods]::CloseHandle($handle)
    }
    if ($resolved.StartsWith('\\?\UNC\')) { $resolved = '\\' + $resolved.Substring(8) }
    elseif ($resolved.StartsWith('\\?\')) { $resolved = $resolved.Substring(4) }
    return $resolved
}

function Test-IsLink([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

# Rejects the path itself and every ancestor directory component that is a link.
function Test-AnyComponentIsLink([string]$Path) {
    $current = $Path
    while ($true) {
        if (Test-IsLink $current) { return $true }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    return $false
}

function Protected([string]$RelPath) {
    $p = $RelPath.Replace("\","/"); $name = [IO.Path]::GetFileName($p)
    return ($p -ieq ".git" -or $p -ilike ".git/*" -or $name -ieq ".env" -or
        $name -ilike ".env.*" -or $name -imatch '\.(pem|key|p12|pfx)$')
}

try {
    if (-not (Test-Path -LiteralPath $Repo -PathType Container)) { Fail "Repository not found: $Repo" }
    $requestedRoot = (Resolve-Path -LiteralPath $Repo).Path
    $top = & git -C $requestedRoot -c core.excludesFile= rev-parse --show-toplevel
    if ($LASTEXITCODE -ne 0 -or -not $top) { Fail "Not a Git repository: $requestedRoot" }
    $top = (Resolve-Path -LiteralPath ($top | Select-Object -First 1)).Path
    $root = Get-Win32RealPath $top

    $brainRoot = $env:ANTIGRAVITY_BRAIN_DIR
    if (-not $brainRoot) { $brainRoot = Join-Path $env:USERPROFILE ".gemini\antigravity-cli\brain" }
    if (-not (Test-Path -LiteralPath $brainRoot -PathType Container)) { Fail "Brain directory not found: $brainRoot" }
    $brainRoot = Get-Win32RealPath $brainRoot

    # --- validate source ---
    if (-not (Test-Path -LiteralPath $Source)) { Fail "Source not found: $Source" }
    if (Test-AnyComponentIsLink $Source) { Fail "Source path must not contain a link" }
    $sourceItem = Get-Item -LiteralPath $Source -Force
    if ($sourceItem.PSIsContainer) { Fail "Source is not a regular file: $Source" }
    $sourceReal = Get-Win32RealPath $Source
    $brainPrefix = $brainRoot.TrimEnd("\","/") + [IO.Path]::DirectorySeparatorChar
    if (-not $sourceReal.StartsWith($brainPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "Source must be inside the Antigravity brain directory: $Source"
    }
    $sourceBytes = [IO.File]::ReadAllBytes($sourceReal)
    if ($sourceBytes.Length -eq 0) { Fail "Source file is empty: $Source" }

    # --- detect type and dimensions from magic bytes ---
    function Get-Png16BE([byte[]]$Bytes,[int]$Offset) {
        return (([uint32]$Bytes[$Offset] -shl 24) -bor ([uint32]$Bytes[$Offset+1] -shl 16) -bor
            ([uint32]$Bytes[$Offset+2] -shl 8) -bor [uint32]$Bytes[$Offset+3])
    }
    $type = $null; $width = 0; $height = 0
    $pngSig = [byte[]](0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A)
    $jpegSig = [byte[]](0xFF,0xD8,0xFF)
    $isPng = ($sourceBytes.Length -ge 8) -and (-not (Compare-Object $sourceBytes[0..7] $pngSig))
    $isJpeg = ($sourceBytes.Length -ge 3) -and $sourceBytes[0] -eq 0xFF -and $sourceBytes[1] -eq 0xD8 -and $sourceBytes[2] -eq 0xFF
    if ($isPng) {
        $type = "png"
        # IHDR chunk: length(4) type(4)="IHDR" width(4) height(4) at offset 8.
        if ($sourceBytes.Length -lt 24) { Fail "could not read image dimensions" }
        $ihdrTag = [Text.Encoding]::ASCII.GetString($sourceBytes[12..15])
        if ($ihdrTag -ne "IHDR") { Fail "could not read image dimensions" }
        $width = Get-Png16BE $sourceBytes 16
        $height = Get-Png16BE $sourceBytes 20
    } elseif ($isJpeg) {
        $type = "jpeg"
        $pos = 2
        $found = $false
        while ($pos + 4 -le $sourceBytes.Length) {
            if ($sourceBytes[$pos] -ne 0xFF) { $pos++; continue }
            $marker = $sourceBytes[$pos+1]
            if ($marker -eq 0xFF) { $pos++; continue }
            if ($marker -eq 0xD8 -or $marker -eq 0xD9) { $pos += 2; continue }
            if ($marker -ge 0xD0 -and $marker -le 0xD7) { $pos += 2; continue }
            if ($pos + 4 -gt $sourceBytes.Length) { break }
            $segLen = ([int]$sourceBytes[$pos+2] -shl 8) -bor [int]$sourceBytes[$pos+3]
            $isSof = ($marker -ge 0xC0 -and $marker -le 0xCF) -and $marker -ne 0xC4 -and $marker -ne 0xC8 -and $marker -ne 0xCC
            if ($isSof) {
                if ($pos + 9 -gt $sourceBytes.Length) { Fail "could not read image dimensions" }
                $height = ([int]$sourceBytes[$pos+5] -shl 8) -bor [int]$sourceBytes[$pos+6]
                $width = ([int]$sourceBytes[$pos+7] -shl 8) -bor [int]$sourceBytes[$pos+8]
                $found = $true
                break
            }
            if ($segLen -lt 2) { Fail "could not read image dimensions" }
            $pos += 2 + $segLen
        }
        if (-not $found) { Fail "could not read image dimensions" }
    } else {
        Fail "unsupported or unrecognized image content"
    }
    if ($width -le 0 -or $height -le 0) { Fail "could not read image dimensions" }

    # --- validate destination ---
    $destInput = $Destination
    $destFull = if ([IO.Path]::IsPathRooted($destInput)) { [IO.Path]::GetFullPath($destInput) } else { [IO.Path]::GetFullPath((Join-Path $root $destInput)) }
    $destParent = Split-Path -Parent $destFull
    if (-not $destParent -or -not (Test-Path -LiteralPath $destParent -PathType Container)) { Fail "Destination parent directory does not exist: $destParent" }
    if (Test-AnyComponentIsLink $destParent) { Fail "Destination parent must not contain a link" }
    $destParentReal = Get-Win32RealPath $destParent
    $destName = Split-Path -Leaf $destFull
    $destResolved = Join-Path $destParentReal $destName
    $rootPrefix = $root.TrimEnd("\","/") + [IO.Path]::DirectorySeparatorChar
    if (-not $destResolved.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "Destination must be inside the repository: $Destination"
    }
    $destRel = $destResolved.Substring($rootPrefix.Length).Replace("\","/")
    if (Protected $destRel) { Fail "Destination is a protected path: $destRel" }

    $ext = [IO.Path]::GetExtension($destName).ToLowerInvariant()
    $extOk = if ($type -eq "png") { $ext -eq ".png" } else { $ext -eq ".jpg" -or $ext -eq ".jpeg" }
    if (-not $extOk) { Fail "destination extension does not match image type $type" }

    if (Test-IsLink $destResolved) { Fail "Destination must not be a link" }
    if (Test-Path -LiteralPath $destResolved) {
        if (-not $Overwrite) { Fail "Destination already exists: $destRel" }
    }

    # --- copy: write to a temp file in the destination directory, then move into place ---
    $tempPath = Join-Path $destParentReal (".antigravity-artifact-" + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [IO.File]::WriteAllBytes($tempPath, $sourceBytes)
        if (Test-IsLink $destResolved) { Fail "Destination must not be a link" }
        Move-Item -LiteralPath $tempPath -Destination $destResolved -Force:$Overwrite
    } catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw
    }

    $sourceHash = (Get-FileHash -LiteralPath $sourceReal -Algorithm SHA256).Hash.ToLowerInvariant()
    $destHash = (Get-FileHash -LiteralPath $destResolved -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceHash -ne $destHash) { Fail "Copied file hash does not match source" }

    Write-Output "[ANTIGRAVITY_ARTIFACT_OK] type=$type width=$width height=$height bytes=$($sourceBytes.Length) sha256=$sourceHash source=$sourceReal destination=$destRel"
    exit 0
} catch { Fail $_.Exception.Message }
