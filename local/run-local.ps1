<#
.SYNOPSIS
  Run apim-sync locally against a real Anypoint environment (thin wrapper around
  ../Invoke-ApimSync.ps1 that loads local/.env first).

.EXAMPLE
  ./local/run-local.ps1 -Action login-check
  ./local/run-local.ps1 -Action validate                              # -Api all is fine here (read-only)
  ./local/run-local.ps1 -Env dev  -Api orders-api -Action validate-spec   # NZ API Standard spec lint
  ./local/run-local.ps1 -Env dev  -Api orders-api                     # dry-run reconcile - one api, required
  ./local/run-local.ps1 -Env dev  -Api orders-api -Apply              # apply
  ./local/run-local.ps1 -Env dev  -Api orders-api -Action extract     # live -> config file
  ./local/run-local.ps1 -Env dev  -Api orders-api -Action redeploy -TargetVersion 1.0.3 -RepoRoot ../config-repo
#>
[CmdletBinding()]
param(
  [ValidateSet('test', 'uat', 'preprod', 'prod')] [string]$Env = 'test',
  [ValidateSet('reconcile', 'extract', 'validate', 'validate-spec', 'redeploy', 'login-check')] [string]$Action = 'reconcile',
  [string]$Api = 'all',
  [string]$ConfigRoot,
  [string]$TargetVersion,               # redeploy only
  [string]$RepoRoot,                    # redeploy/commit: the git repo ConfigRoot lives in (defaults to ConfigRoot)
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
  $common.ConfigDir = $ConfigRoot          # repo root: <api>/apimanager/<env>.yaml|json
  $common.Api = $Api
}
if ($Action -in @('reconcile', 'extract', 'validate', 'validate-spec', 'redeploy')) { $common.Environment = $Env }
if (-not $RepoRoot) { $RepoRoot = $ConfigRoot }

switch ($Action) {
  'reconcile' {
    & (Join-Path $repo 'Invoke-ApimSync.ps1') @common -Prune $Prune -DryRun:(-not $Apply) `
      -PlanOut (Join-Path $repo 'plan.json') -RepoDir $RepoRoot -Commit:$Commit -Push:$Push
  }
  'extract' {
    & (Join-Path $repo 'Invoke-ApimSync.ps1') @common -Commit:$Commit -Push:$Push -RepoDir $RepoRoot
  }
  'redeploy' {
    & (Join-Path $repo 'Invoke-ApimSync.ps1') @common -TargetVersion $TargetVersion -Prune $Prune `
      -DryRun:(-not $Apply) -RepoDir $RepoRoot -Commit:$Commit -Push:$Push
  }
  default {
    & (Join-Path $repo 'Invoke-ApimSync.ps1') @common
  }
}
exit $LASTEXITCODE
