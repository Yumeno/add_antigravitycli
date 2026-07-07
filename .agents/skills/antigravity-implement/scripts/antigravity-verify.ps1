param(
    [Parameter(Position=0, Mandatory=$true)][ValidateSet("snapshot","check")][string]$Command,
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string]$Snapshot,
    [string[]]$Allow = @()
)
$ErrorActionPreference = "Stop"
function Fail([string]$Message, [int]$Code = 1) { Write-Output "[ANTIGRAVITY_VERIFY_ERROR] $Message"; exit $Code }
function Invoke-Git([string[]]$Arguments, [switch]$MayFail) {
    $stderrFile = [IO.Path]::GetTempFileName()
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $result = & git -C $script:Root -c core.excludesFile= @Arguments 2> $stderrFile
        $code = $LASTEXITCODE
        $stderr = Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue
    } finally {
        $ErrorActionPreference = $previousErrorAction
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
    if ($code -ne 0) {
        if ($MayFail) { return "" }
        $detail = (@($result) + @($stderr)) -join "`n"
        throw $detail.Trim()
    }
    return ($result -join "`n")
}
function Relative([string]$Path) {
    $prefix = $script:Root.TrimEnd("\","/") + "\"
    if (-not $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "repository path escape" }
    return $Path.Substring($prefix.Length).Replace("\","/")
}
function Protected([string]$Path) {
    $p = $Path.Replace("\","/"); $name = [IO.Path]::GetFileName($p)
    return ($p -ieq ".git/config" -or $p -ieq ".git/HEAD" -or $p -ieq ".git/packed-refs" -or
        $p -ieq ".git/info/exclude" -or $p -ilike ".git/hooks/*" -or $p -ilike ".git/refs/*" -or
        $p -ieq ".gitmodules" -or $name -ieq ".env" -or
        $name -ilike ".env.*" -or $name -imatch '\.(pem|key|p12|pfx)$')
}
function FileState([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    $kind = if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { "reparse" } else { "file" }
    return [ordered]@{ kind=$kind; target=[string]$item.Target; sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
}
function ProtectedState {
    $state = [ordered]@{}
    $rootItems = Get-ChildItem -LiteralPath $script:Root -Force
    foreach ($item in @($rootItems | Where-Object { -not $_.PSIsContainer -and $_.Name -ne ".git" }) +
        @($rootItems | Where-Object { $_.PSIsContainer -and $_.Name -ne ".git" } | ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -Recurse -Force -File
        })) {
        $rel = Relative $item.FullName; if (Protected $rel) { $state[$rel] = FileState $item.FullName }
    }
    $gitDir = Invoke-Git @("rev-parse","--absolute-git-dir")
    foreach ($entry in @(@("config",".git/config"),@("HEAD",".git/HEAD"),@("packed-refs",".git/packed-refs"),@("info/exclude",".git/info/exclude"))) {
        $path = Join-Path $gitDir $entry[0]
        if (Test-Path -LiteralPath $path -PathType Leaf) { $state[$entry[1]] = FileState $path }
    }
    $hooks = Join-Path $gitDir "hooks"
    if (Test-Path -LiteralPath $hooks -PathType Container) {
        foreach ($item in Get-ChildItem -LiteralPath $hooks -Recurse -Force -File) {
            $rel = $item.FullName.Substring($hooks.Length).TrimStart("\","/").Replace("\","/")
            $state[".git/hooks/$rel"] = FileState $item.FullName
        }
    }
    $refs = Join-Path $gitDir "refs"
    if (Test-Path -LiteralPath $refs -PathType Container) {
        foreach ($item in Get-ChildItem -LiteralPath $refs -Recurse -Force -File) {
            $rel = $item.FullName.Substring($refs.Length).TrimStart("\","/").Replace("\","/")
            $state[".git/refs/$rel"] = FileState $item.FullName
        }
    }
    return $state
}
function State {
    return [ordered]@{ version=1; implementation="powershell"; repo=$script:Root;
        head=Invoke-Git @("rev-parse","HEAD"); branch=Invoke-Git @("symbolic-ref","--quiet","--short","HEAD") -MayFail;
        status=Invoke-Git @("-c","core.quotepath=true","status","--porcelain=v1","--untracked-files=all");
        protected=ProtectedState }
}
function Same($A,$B) { return (($A | ConvertTo-Json -Depth 8 -Compress) -ceq ($B | ConvertTo-Json -Depth 8 -Compress)) }
try {
    $script:Root = (Resolve-Path -LiteralPath $Repo).Path.TrimEnd("\","/")
    $top = (Resolve-Path -LiteralPath (Invoke-Git @("rev-parse","--show-toplevel"))).Path.TrimEnd("\","/")
    if ($top -ine $script:Root) { Fail "Repo must be the Git repository root" }
    $snap = [IO.Path]::GetFullPath($Snapshot)
    if ($snap.StartsWith($script:Root + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { Fail "Snapshot must be outside repository" }
    if ($Command -eq "snapshot") {
        if ($Allow.Count) { Fail "Allow is valid only with check" }
        if (-not (Test-Path -LiteralPath (Split-Path -Parent $snap) -PathType Container)) { Fail "Snapshot directory does not exist" }
        $current = State
        if (-not [string]::IsNullOrWhiteSpace($current.status)) { Fail "Working tree must be clean before snapshot" }
        [IO.File]::WriteAllText($snap, ($current | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        Write-Output "[ANTIGRAVITY_VERIFY_OK] snapshot created"; exit 0
    }
    if (-not (Test-Path -LiteralPath $snap -PathType Leaf)) { Fail "Snapshot not found" }
    $before = Get-Content -LiteralPath $snap -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($before.version -ne 1 -or $before.implementation -cne "powershell" -or $before.repo -ine $script:Root) { Fail "Snapshot mismatch" }
    $after = State; $violations = New-Object Collections.Generic.List[string]
    if ($before.head -cne $after.head) { $violations.Add("HEAD changed") }
    if ($before.branch -cne $after.branch) { $violations.Add("branch changed") }
    Write-Output "### git status --porcelain=v1 --untracked-files=all"; Write-Output $after.status
    Write-Output "### git diff HEAD --stat"; Write-Output (Invoke-Git @("diff","HEAD","--stat"))
    $old=@{}; $before.protected.PSObject.Properties | ForEach-Object { $old[$_.Name]=$_.Value }
    $new=$after.protected; $paths=@($old.Keys + $new.Keys | Sort-Object -Unique)
    $changed=@($paths | Where-Object { -not $old.ContainsKey($_) -or -not $new.Contains($_) -or -not (Same $old[$_] $new[$_]) })
    $allowed = New-Object Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
    foreach ($raw in $Allow) {
        $p=$raw.Replace("\","/")
        if ([IO.Path]::IsPathRooted($raw) -or $p -match '(^|/)\.\.(/|$)' -or $p.IndexOfAny([char[]]"*?[]") -ge 0 -or
            $p.EndsWith("/") -or -not (Protected $p) -or -not ($changed -icontains $p)) { Fail "Invalid allow path: $raw" }
        [void]$allowed.Add($p)
    }
    foreach ($p in $changed) {
        if ($allowed.Contains($p)) { Write-Output "[ANTIGRAVITY_VERIFY_ALLOWED] protected change: $p" }
        else { $violations.Add("protected change: $p") }
    }
    if ($violations.Count) { $violations | ForEach-Object { Write-Output "[ANTIGRAVITY_VERIFY_VIOLATION] $_" }; exit 3 }
    Write-Output "[ANTIGRAVITY_VERIFY_OK] no unapproved changes"; exit 0
} catch { Fail $_.Exception.Message 2 }

