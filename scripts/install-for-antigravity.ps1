[CmdletBinding()]
param([string]$DestinationRoot = (Join-Path $env:USERPROFILE ".gemini\antigravity-cli"))
$ErrorActionPreference = "Stop"
$Source = Join-Path (Split-Path $PSScriptRoot -Parent) ".agents\skills"
$Names = @("ask-antigravity", "ask-antigravity-with-context", "antigravity-implement", "list-antigravity-models", "set-antigravity-model")
foreach ($name in $Names) {$skill=Join-Path $Source $name;if(-not(Test-Path -LiteralPath $skill -PathType Container)-or -not(Test-Path -LiteralPath (Join-Path $skill "SKILL.md") -PathType Leaf)){throw "Missing source skill: $name"}}
New-Item -ItemType Directory -Path $DestinationRoot -Force|Out-Null;$Stage=Join-Path $DestinationRoot (".add-antigravitycli-stage-"+[guid]::NewGuid().ToString("N"))
try {
 New-Item -ItemType Directory -Path (Join-Path $Stage "skills") -Force|Out-Null;$SkillsRoot=Join-Path $DestinationRoot "skills";New-Item -ItemType Directory -Path $SkillsRoot -Force|Out-Null
 foreach($name in $Names){Copy-Item -LiteralPath (Join-Path $Source $name) -Destination (Join-Path $Stage "skills\$name") -Recurse -Force}
 foreach($name in $Names){$final=Join-Path $SkillsRoot $name;$new="$final.new";$old="$final.old";Remove-Item -LiteralPath $new -Recurse -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue;Move-Item -LiteralPath (Join-Path $Stage "skills\$name") -Destination $new -ErrorAction Stop;if(Test-Path -LiteralPath $final){Move-Item -LiteralPath $final -Destination $old -ErrorAction Stop};try{Move-Item -LiteralPath $new -Destination $final -ErrorAction Stop}catch{if(Test-Path -LiteralPath $old){try{Move-Item -LiteralPath $old -Destination $final -ErrorAction Stop}catch{[Console]::Error.WriteLine("Rollback also failed for ${name} (leftover: $old): $_")}};throw "Failed to promote new skill: $name"};Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue}
 Write-Output "Antigravity CLI用Skillをインストールしました。"
} finally {Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue}
