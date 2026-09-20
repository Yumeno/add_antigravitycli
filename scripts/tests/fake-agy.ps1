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
for ($i = 0; $i -lt $Arguments.Count - 1; $i++) {
    if ($Arguments[$i] -eq "--output-format" -and $Arguments[$i + 1] -eq "json") { $useJson = $true; break }
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
    if ($env:FAKE_DENIED) {
        $pairs = @($env:FAKE_DENIED -split ',' | ForEach-Object {
            $parts = $_ -split ':', 2
            [ordered]@{ action = $parts[0]; display_name = $parts[1] }
        })
        switch ($env:FAKE_DENIED_SHAPE) {
            "object" { $data.denied_actions = $pairs[0] }
            "number" { $data.denied_actions = 42 }
            default { $data.denied_actions = $pairs }
        }
    }
    $json = $data | ConvertTo-Json -Compress -Depth 5
    [Console]::Out.Write($json)
    [Console]::Out.Write("`n")
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
