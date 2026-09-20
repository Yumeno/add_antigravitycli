param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
[IO.File]::WriteAllLines($env:FAKE_ARGS, $Arguments, (New-Object Text.UTF8Encoding($false)))
$reader = New-Object IO.StreamReader([Console]::OpenStandardInput(), (New-Object Text.UTF8Encoding($false)))
$inputText = $reader.ReadToEnd()
[IO.File]::WriteAllText($env:FAKE_STDIN, $inputText, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($env:FAKE_CWD, (Get-Location).Path, (New-Object Text.UTF8Encoding($false)))
if ($env:FAKE_WRITE_FILE) { [IO.File]::WriteAllText($env:FAKE_WRITE_FILE, "fake change", (New-Object Text.UTF8Encoding($false))) }

$useJson = $false
for ($i = 0; $i -lt $Arguments.Count - 1; $i++) {
    if ($Arguments[$i] -eq "--output-format" -and $Arguments[$i + 1] -eq "json") { $useJson = $true; break }
}

function Write-JsonEnvelope([string]$Response) {
    $status = if ($env:FAKE_STATUS) { $env:FAKE_STATUS } else { "SUCCESS" }
    $escaped = $Response -replace '\\','\\\\' -replace '"','\"' -replace "`r",'\r' -replace "`n",'\n' -replace "`t",'\t'
    $json = "{`"conversation_id`":`"fake`",`"status`":`"$status`",`"response`":`"$escaped`",`"num_turns`":1"
    if ($env:FAKE_DENIED) {
        $pairs = $env:FAKE_DENIED -split ',' | ForEach-Object {
            $parts = $_ -split ':', 2
            "{`"action`":`"$($parts[0])`",`"display_name`":`"$($parts[1])`"}"
        }
        $json += ",`"denied_actions`":[" + ($pairs -join ",") + "]"
    }
    $json += "}"
    Write-Output $json
}

if ($env:FAKE_RAW) { Write-Output $env:FAKE_RAW; exit 0 }

switch ($env:FAKE_MODE) {
    "fail" { [Console]::Error.Write("fake failure"); exit 7 }
    "empty" {
        if ($env:FAKE_RAW_EMPTY -eq "1") { exit 0 }
        if ($useJson) { Write-JsonEnvelope ""; exit 0 }
        exit 0
    }
    "sleep" { Start-Sleep -Seconds 10; Write-Output "late" }
    default {
        if ($useJson) { Write-JsonEnvelope "fake response" } else { Write-Output "fake response" }
    }
}
