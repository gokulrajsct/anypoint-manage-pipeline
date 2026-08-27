<#
.SYNOPSIS
  Run apim-sync locally against a real Anypoint environment (thin wrapper around
  ../Invoke-ApimSync.ps1 that loads local/.env first).

.EXAMPLE
  ./local/run-local.ps1 -Action login-check
  ./local/run-local.ps1 -Env dev  -Api orders-api                 # dry-run reconcile
  ./local/run-local.ps1 -Env dev  -Api orders-api -Apply          # apply
  ./local/run-local.ps1 -Env test -Apply
  ./local/run-local.ps1 -Env dev  -Api orders-api -Action extract # live -> config file
#>
[CmdletBinding()]
param(
  [ValidateSet('test', 'uat', 'preprod', 'prod')] [string]$Env = 'test',
  [ValidateSet('reconcile', 'extract', 'validate', 'login-check')] [string]$Action = 'reconcile',
  [string]$Api = 'all',
  [string]$ConfigRoot,
  [switch]$Apply,                       # omit => -DryRun
  [ValidateSet('fromconfig', 'true', 'false')] [string]$Prune = 'fromconfig',
  [switch]$Commit,
  [switch]$Push
)

$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
if (-not $ConfigRoot) { $ConfigRoot = Join-Path $repo 'config' }

$envFile = Join-Path $PSScriptRoot '.env'
if (Test-Path $envFile) {
  Get-Content $envFile | Where-Object { $_ -match '^\s*[^#].*=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2
    [Environment]::SetEnvironmentVariable($k.Trim(), $v.Trim())
  }
  Write-Host "Loaded $envFile" -ForegroundColor DarkGray
}

$common = @{ Action = $Action }
if ($Action -ne 'login-check') {
  $common.ConfigDir = Join-Path $ConfigRoot $Env
  $common.Api = $Api
}
if ($Action -in @('reconcile', 'extract')) { $common.Environment = $Env }

switch ($Action) {
  'reconcile' {
    & (Join-Path $repo 'Invoke-ApimSync.ps1') @common -Prune $Prune -DryRun:(-not $Apply) `
      -PlanOut (Join-Path $repo 'plan.json')
  }
  'extract' {
    & (Join-Path $repo 'Invoke-ApimSync.ps1') @common -Commit:$Commit -Push:$Push
  }
  default {
    & (Join-Path $repo 'Invoke-ApimSync.ps1') @common
  }
}
exit $LASTEXITCODE
