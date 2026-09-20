param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
[IO.File]::WriteAllLines($env:FAKE_ARGS, $Arguments, (New-Object Text.UTF8Encoding($false)))
$reader = New-Object IO.StreamReader([Console]::OpenStandardInput(), (New-Object Text.UTF8Encoding($false)))
$inputText = $reader.ReadToEnd()
[IO.File]::WriteAllText($env:FAKE_STDIN, $inputText, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($env:FAKE_CWD, (Get-Location).Path, (New-Object Text.UTF8Encoding($false)))
if ($env:FAKE_WRITE_FILE) { [IO.File]::WriteAllText($env:FAKE_WRITE_FILE, "fake change", (New-Object Text.UTF8Encoding($false))) }
if ($env:FAKE_STDERR) { [Console]::Error.WriteLine($env:FAKE_STDERR) }

$useJson = $false
$useStream = $false
for ($i = 0; $i -lt $Arguments.Count - 1; $i++) {
    if ($Arguments[$i] -eq "--output-format" -and $Arguments[$i + 1] -eq "json") { $useJson = $true; break }
    if ($Arguments[$i] -eq "--output-format" -and $Arguments[$i + 1] -eq "stream-json") { $useStream = $true; break }
}

function Get-DeniedActions {
    if (-not $env:FAKE_DENIED) { return $null }
    $pairs = @($env:FAKE_DENIED -split ',' | ForEach-Object {
        $parts = $_ -split ':', 2
        [ordered]@{ action = $parts[0]; display_name = $parts[1] }
    })
    switch ($env:FAKE_DENIED_SHAPE) {
        "object" { return $pairs[0] }
        "number" { return 42 }
        default { return $pairs }
    }
}

function Write-JsonEnvelope([string]$Response) {
    $status = if ($env:FAKE_STATUS) { $env:FAKE_STATUS } else { "SUCCESS" }
    if ($env:FAKE_RESPONSE_FILE) { $Response = [IO.File]::ReadAllText($env:FAKE_RESPONSE_FILE, [Text.Encoding]::UTF8) }
    $data = [ordered]@{
        conversation_id = "fake"
        status = $status
        response = $Response
        num_turns = 1
    }
    $denied = Get-DeniedActions
    if ($null -ne $denied) { $data.denied_actions = $denied }
    $json = $data | ConvertTo-Json -Compress -Depth 5
    [Console]::Out.Write($json)
    [Console]::Out.Write("`n")
}

function Write-Line([hashtable]$Obj) {
    $json = $Obj | ConvertTo-Json -Compress -Depth 8
    [Console]::Out.Write($json)
    [Console]::Out.Write("`n")
    [Console]::Out.Flush()
}

function Write-StreamEnvelope([string]$Response) {
    $status = if ($env:FAKE_STATUS) { $env:FAKE_STATUS } else { "SUCCESS" }
    if ($env:FAKE_RESPONSE_FILE) { $Response = [IO.File]::ReadAllText($env:FAKE_RESPONSE_FILE, [Text.Encoding]::UTF8) }

    Write-Line @{ event = "init"; conversation_id = "fake"; init = @{} }
    Write-Line @{ event = "step_update"; step_update = @{ conversation_id = "fake"; step_index = 0; state = "DONE"; step_type = "user_input" } }

    $garbage = ($env:FAKE_GARBAGE_LINE -eq "1") -or ($env:FAKE_AGY_GARBAGE_LINE -eq "1")
    if ($garbage) { [Console]::Out.Write("not json and no event field`n"); [Console]::Out.Flush() }

    $thoughtStep = ($env:FAKE_THOUGHT_STEP -eq "1") -or ($env:FAKE_AGY_THOUGHT_STEP -eq "1")
    if ($thoughtStep) {
        Write-Line @{ event = "step_update"; step_update = @{ conversation_id = "fake"; step_index = 1; state = "ACTIVE"; step_type = "thought" } }
    }

    if ($Response.Length -gt 0) {
        $half = [Math]::Ceiling($Response.Length / 2.0)
        $first = $Response.Substring(0, $half)
        $rest = $Response.Substring($half)
        Write-Line @{ event = "step_update"; step_update = @{ conversation_id = "fake"; step_index = 1; state = "ACTIVE"; step_type = "agent_response"; text_delta = $first } }
        $delay = $env:FAKE_STREAM_DELAY
        if (-not $delay) { $delay = $env:FAKE_AGY_STREAM_DELAY }
        if ($delay) { Start-Sleep -Seconds ([double]$delay) }
        Write-Line @{ event = "step_update"; step_update = @{ conversation_id = "fake"; step_index = 1; state = "DONE"; step_type = "agent_response"; text_delta = $rest } }
    }

    $toolEvent = ($env:FAKE_TOOL_EVENT -eq "1") -or ($env:FAKE_AGY_TOOL_EVENT -eq "1")
    if ($toolEvent) {
        Write-Line @{ event = "step_update"; step_update = @{ conversation_id = "fake"; step_index = 2; state = "ACTIVE"; step_type = "tool"; tool_name = "run_command"; tool_info = @{ parameters = @{ command = "echo hi" } } } }
        Write-Line @{ event = "step_update"; step_update = @{ conversation_id = "fake"; step_index = 2; state = "DONE"; step_type = "tool"; tool_name = "run_command"; tool_info = @{ parameters = @{ command = "echo hi" }; error = @{ type = "TOOL_ERROR"; message = "context canceled" } } } }
    }

    $errorEvent = ($env:FAKE_ERROR_EVENT -eq "1") -or ($env:FAKE_AGY_ERROR_EVENT -eq "1")
    if ($errorEvent) {
        Write-Line @{ event = "error"; error = @{ type = "FATAL"; message = "fake fatal error" } }
        return
    }

    $noResult = ($env:FAKE_NO_RESULT -eq "1") -or ($env:FAKE_AGY_NO_RESULT -eq "1")
    if ($noResult) { return }

    $result = [ordered]@{
        conversation_id = "fake"
        status = $status
        response = $Response
        duration_seconds = 0
        num_turns = 1
        usage = @{}
    }
    $denied = Get-DeniedActions
    if ($null -ne $denied) { $result.denied_actions = $denied }
    Write-Line @{ event = "result"; result = $result }
}

if ($env:FAKE_RAW) { Write-Output $env:FAKE_RAW; exit 0 }

switch ($env:FAKE_MODE) {
    "fail" { [Console]::Error.Write("fake failure"); exit 7 }
    "empty" {
        if ($env:FAKE_RAW_EMPTY -eq "1") { exit 0 }
        if ($useJson) { Write-JsonEnvelope ""; exit 0 }
        if ($useStream) { Write-StreamEnvelope ""; exit 0 }
        exit 0
    }
    "sleep" { Start-Sleep -Seconds 10; Write-Output "late" }
    default {
        if ($useJson) { Write-JsonEnvelope "fake response" }
        elseif ($useStream) { Write-StreamEnvelope "fake response" }
        else { Write-Output "fake response" }
    }
}
