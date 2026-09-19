param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
[IO.File]::WriteAllLines($env:FAKE_ARGS, $Arguments, (New-Object Text.UTF8Encoding($false)))
$reader = New-Object IO.StreamReader([Console]::OpenStandardInput(), (New-Object Text.UTF8Encoding($false)))
$inputText = $reader.ReadToEnd()
[IO.File]::WriteAllText($env:FAKE_STDIN, $inputText, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($env:FAKE_CWD, (Get-Location).Path, (New-Object Text.UTF8Encoding($false)))
if ($env:FAKE_WRITE_FILE) { [IO.File]::WriteAllText($env:FAKE_WRITE_FILE, "fake change", (New-Object Text.UTF8Encoding($false))) }
switch ($env:FAKE_MODE) {
    "fail" { [Console]::Error.Write("fake failure"); exit 7 }
    "empty" { exit 0 }
    "sleep" { Start-Sleep -Seconds 10; Write-Output "late" }
    default { Write-Output "fake response" }
}
