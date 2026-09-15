<#
.SYNOPSIS
  Regenerate the `apiKey` dropdown (the `values:` list) in azure-pipelines.yml from the
  actual <api>/apimanager/ folders in a config repo checkout.

.DESCRIPTION
  Azure DevOps YAML parameters can't be populated dynamically at queue time - the `values:`
  list is baked into the pipeline YAML. Run this whenever an API folder is added to or
  removed from the config repo, then commit the updated azure-pipelines.yml.

  Rewrites only the lines between the APIKEY_VALUES_START / APIKEY_VALUES_END markers;
  everything else in the file (including the SELECT_ONE placeholder, which is always kept
  first) is left untouched.

.EXAMPLE
  ./pipelines/Update-ApiKeyList.ps1 -ConfigRepoDir ../mule-config
  ./pipelines/Update-ApiKeyList.ps1 -ConfigRepoDir ../mule-config -WhatIf
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigRepoDir,
    [string]$PipelineFile = (Join-Path $PSScriptRoot '..\azure-pipelines.yml'),
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ConfigRepoDir)) { throw "Config repo dir not found: $ConfigRepoDir" }
if (-not (Test-Path -LiteralPath $PipelineFile)) { throw "Pipeline file not found: $PipelineFile" }

$apis = @(Get-ChildItem -LiteralPath $ConfigRepoDir -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'apimanager') } |
    Select-Object -ExpandProperty Name | Sort-Object)
if (-not $apis) { throw "No <api>/apimanager/ folders found under $ConfigRepoDir" }

$lines = @(Get-Content -LiteralPath $PipelineFile)
# Anchor on the marker as an actual comment line (# ... APIKEY_VALUES_START), not just the
# token anywhere - it's also mentioned in prose comments elsewhere in this file.
$startMatches = @($lines | Select-String -Pattern '^\s*#.*APIKEY_VALUES_START\b')
$endMatches = @($lines | Select-String -Pattern '^\s*#.*APIKEY_VALUES_END\b')
if ($startMatches.Count -ne 1 -or $endMatches.Count -ne 1) {
    throw "Expected exactly one '# ... APIKEY_VALUES_START' and one '# ... APIKEY_VALUES_END' comment line in $PipelineFile (found $($startMatches.Count) / $($endMatches.Count))"
}
$startLine = $startMatches[0].LineNumber
$endLine = $endMatches[0].LineNumber
if ($endLine -le $startLine) { throw "APIKEY_VALUES_END must come after APIKEY_VALUES_START in $PipelineFile" }

$indent = ($lines[$startLine] -replace '^(\s*)-.*', '$1')   # indentation of the first "- value" line
if (-not $indent) { $indent = '      ' }
$newBlock = @("${indent}- SELECT_ONE") + ($apis | ForEach-Object { "${indent}- $_" })

$before = $lines[0..($startLine - 1)]     # up to and including the START marker line
$after = $lines[($endLine - 1)..($lines.Count - 1)]   # the END marker line onward
$updated = $before + $newBlock + $after

Write-Host "apiKey values -> SELECT_ONE, $($apis -join ', ')"
if ($WhatIf) { Write-Host "-WhatIf: $PipelineFile not written."; exit 0 }

Set-Content -LiteralPath $PipelineFile -Value $updated -Encoding utf8
Write-Host "Updated $PipelineFile"
