param(
    [Parameter(Position=0, Mandatory=$true)][ValidateSet("import")][string]$Command,
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Source,
    [Parameter(Mandatory=$true)][string]$Destination,
    [Parameter(Mandatory=$true)][string]$ConversationId,
    [switch]$Overwrite
)
$ErrorActionPreference = "Stop"
function Fail([string]$Message) { Write-Output "[ANTIGRAVITY_ARTIFACT_ERROR] $Message"; exit 1 }

# Image size limits. Normal workload is agy-generated images in the 1024-1376px range;
# these caps just keep this helper from processing pathological/hostile input.
$MaxImageDimension = 8192
$MaxImagePixels = 64000000

# Threat model: validation and the copy are separate filesystem operations, so this helper
# is NOT safe against a concurrent writer with access to the same directories (same-user
# TOCTOU races). It defends against wrong/hostile paths reported by the agent, links, and
# unsupported/malformed content -- not against a racing process swapping files mid-import.
# Output-line contract: source=/destination= are printed raw and are the last two fields
# specifically because paths may contain '=' or spaces; both are validated to contain no
# CR/LF so no line can be forged by an embedded newline.

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
    if ($Source -match "[\r\n]" -or $Destination -match "[\r\n]") { Fail "path contains a line break" }
    # NTFS alternate data streams (".git:x.png") would bypass the protected-path and extension
    # checks; reject any ':' after the optional drive prefix before the path is resolved.
    if (($Destination -replace '^[A-Za-z]:', '') -match ':') { Fail "Destination name must not contain ':' (alternate data stream): $Destination" }
    if ([string]::IsNullOrEmpty($ConversationId) -or $ConversationId -notmatch '^[A-Za-z0-9-]+$' -or $ConversationId.Contains("..")) {
        Fail "Invalid conversation id: $ConversationId"
    }
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
    $convDir = Get-Win32RealPath (Join-Path $brainRoot $ConversationId)
    $convPrefix = $convDir.TrimEnd("\","/") + [IO.Path]::DirectorySeparatorChar
    $sourceParent = Split-Path -Parent $sourceReal
    $sourceParentWithSep = $sourceParent.TrimEnd("\","/") + [IO.Path]::DirectorySeparatorChar
    if (-not $sourceParentWithSep.Equals($convPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "Source is not inside the conversation directory: $($brainRoot.TrimEnd('\','/'))/$ConversationId"
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
    $isPng = ($sourceBytes.Length -ge 8) -and (-not (Compare-Object $sourceBytes[0..7] $pngSig))
    $isJpeg = ($sourceBytes.Length -ge 3) -and $sourceBytes[0] -eq 0xFF -and $sourceBytes[1] -eq 0xD8 -and $sourceBytes[2] -eq 0xFF
    if ($isPng) {
        $type = "png"
        # First chunk must be IHDR with length exactly 13, and the file must contain the
        # whole chunk plus its 4-byte CRC (>= 8 sig + 4 len + 4 tag + 13 data + 4 crc = 33 bytes).
        if ($sourceBytes.Length -lt 33) { Fail "could not read image dimensions" }
        $ihdrLen = Get-Png16BE $sourceBytes 8
        $ihdrTag = [Text.Encoding]::ASCII.GetString($sourceBytes[12..15])
        if ($ihdrTag -ne "IHDR" -or $ihdrLen -ne 13) { Fail "could not read image dimensions" }
        $width = Get-Png16BE $sourceBytes 16
        $height = Get-Png16BE $sourceBytes 20
    } elseif ($isJpeg) {
        $type = "jpeg"
        $pos = 2
        $found = $false
        while ($pos + 2 -le $sourceBytes.Length) {
            if ($sourceBytes[$pos] -ne 0xFF) { $pos++; continue }
            $marker = $sourceBytes[$pos+1]
            if ($marker -eq 0xFF) { $pos++; continue }
            # Standalone markers (no length field): RST0-7, TEM, SOI, EOI.
            if (($marker -ge 0xD0 -and $marker -le 0xD7) -or $marker -eq 0x01 -or $marker -eq 0xD8) { $pos += 2; continue }
            if ($marker -eq 0xD9) { break }  # EOI before a SOF: fail below.
            if ($marker -eq 0xDA) { break }  # SOS before a SOF: fail below.
            if ($pos + 4 -gt $sourceBytes.Length) { Fail "could not read image dimensions" }
            $segLen = ([int]$sourceBytes[$pos+2] -shl 8) -bor [int]$sourceBytes[$pos+3]
            if ($segLen -lt 2 -or ($pos + 2 + $segLen) -gt $sourceBytes.Length) { Fail "could not read image dimensions" }
            $isSof = ($marker -ge 0xC0 -and $marker -le 0xCF) -and $marker -ne 0xC4 -and $marker -ne 0xC8 -and $marker -ne 0xCC
            if ($isSof) {
                if ($segLen -lt 8) { Fail "could not read image dimensions" }
                $nf = [int]$sourceBytes[$pos+9]
                if ($segLen -ne (8 + 3 * $nf)) { Fail "could not read image dimensions" }
                $height = ([int]$sourceBytes[$pos+5] -shl 8) -bor [int]$sourceBytes[$pos+6]
                $width = ([int]$sourceBytes[$pos+7] -shl 8) -bor [int]$sourceBytes[$pos+8]
                $found = $true
                break
            }
            $pos += 2 + $segLen
        }
        if (-not $found) { Fail "could not read image dimensions" }
    } else {
        Fail "unsupported or unrecognized image content"
    }
    if ($width -le 0 -or $height -le 0) { Fail "could not read image dimensions" }
    if ($width -gt $MaxImageDimension -or $height -gt $MaxImageDimension -or ([int64]$width * [int64]$height) -gt $MaxImagePixels) {
        Fail "image dimensions out of range: ${width}x${height}"
    }

    # --- validate destination ---
    $destInput = $Destination
    $destFull = if ([IO.Path]::IsPathRooted($destInput)) { [IO.Path]::GetFullPath($destInput) } else { [IO.Path]::GetFullPath((Join-Path $root $destInput)) }
    $destParent = Split-Path -Parent $destFull
    if (-not $destParent -or -not (Test-Path -LiteralPath $destParent -PathType Container)) { Fail "Destination parent directory does not exist: $destParent" }
    if (Test-AnyComponentIsLink $destParent) { Fail "Destination parent must not contain a link" }
    $destParentReal = Get-Win32RealPath $destParent
    $destName = Split-Path -Leaf $destFull
    # NTFS alternate data streams (".git:x.png") and reserved device names would bypass the
    # protected-path and extension checks below and are never a valid regular-file destination.
    # Windows treats the part before the FIRST dot as the device name (NUL.foo.png is NUL); trailing dots/spaces are stripped by Win32.
    if (($destName -split '\.',2)[0] -match '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$' -or $destName -match '[. ]$') { Fail "Destination name is a reserved device name or ends with a dot/space: $destName" }
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

    # Hash the bytes we already have in memory: this is the expected hash. Never re-open the
    # source path again after this point (it was read once, above, before any validation of
    # the destination could have raced with a concurrent writer at the source).
    $sourceHasher = [Security.Cryptography.SHA256]::Create()
    try { $sourceHash = ([BitConverter]::ToString($sourceHasher.ComputeHash($sourceBytes))).Replace("-","").ToLowerInvariant() }
    finally { $sourceHasher.Dispose() }

    # --- copy: write to a temp file in the destination directory, then move into place ---
    # Note: Fail() calls exit, which is not caught by a try/catch here, so any failure path
    # below must remove $tempPath itself before calling Fail (never leave a partial temp file).
    $tempPath = Join-Path $destParentReal (".antigravity-artifact-" + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [IO.File]::WriteAllBytes($tempPath, $sourceBytes)
        $destHash = (Get-FileHash -LiteralPath $tempPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sourceHash -ne $destHash) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            Fail "Copied file hash does not match source"
        }
        # Final link re-check happens as close as possible to the rename that replaces $Overwrite's
        # target, so the destination is never lost except by this one atomic move.
        if (Test-IsLink $destResolved) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            Fail "Destination must not be a link"
        }
        Move-Item -LiteralPath $tempPath -Destination $destResolved -Force:$Overwrite
    } catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw
    }

    Write-Output "[ANTIGRAVITY_ARTIFACT_OK] type=$type width=$width height=$height bytes=$($sourceBytes.Length) sha256=$sourceHash source=$sourceReal destination=$destRel"
    exit 0
} catch { Fail $_.Exception.Message }
