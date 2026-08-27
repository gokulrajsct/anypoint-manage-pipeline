<#
.SYNOPSIS
  Declarative Anypoint API Manager deployment driver (Anypoint CLI v4).

.DESCRIPTION
  reconcile    Make an environment match config/<env>/<api>.yaml. Creates the API
               instance from scratch (initial env) or by PROMOTING from the previous
               env, then applies only the policy differences. Empty diff => no changes.
  extract      Read the policies applied on the instance and write them back into the
               config files. Allowed only for the initial environment.
  validate     Offline schema/shape check of the config files.
  login-check  Verify the connected-app credentials and list environments.

.EXAMPLE
  ./Invoke-ApimSync.ps1 -Action reconcile -Environment dev -ConfigDir ./config/dev -DryRun
  ./Invoke-ApimSync.ps1 -Action reconcile -Environment test -ConfigDir ./config/test
  ./Invoke-ApimSync.ps1 -Action extract   -Environment dev -ConfigDir ./config/dev -Commit -Push
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('reconcile', 'extract', 'validate', 'login-check')][string]$Action,
    [string]$Environment,
    [string]$ConfigDir,
    [string]$Api = 'all',
    [switch]$DryRun,
    [ValidateSet('auto', 'scratch', 'promote')][string]$CreateMode = 'auto',
    [ValidateSet('fromconfig', 'true', 'false')][string]$Prune = 'fromconfig',
    [string]$PlanOut,
    [switch]$AllowDrift,
    [switch]$Commit,
    [switch]$Push,
    [string]$RepoDir,
    [string]$Branch = 'main',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/ApimSync/ApimSync.psd1') -Force

$pruneOverride = switch ($Prune) {
    'true' { $true } 'false' { $false } default { $null }
}

function Require-Param([string]$Name, $Value) {
    if (-not $Value) { throw "-$Name is required for -Action $Action" }
}

try {
    switch ($Action) {

        'login-check' {
            $envs = Invoke-AnypointCli -AsJson -ArgumentList @('account', 'environment', 'list', '--output', 'json')
            Write-Host "Connected. Organization: $($env:ANYPOINT_ORG)"
            foreach ($e in @($envs)) { Write-Host ("  {0,-14} {1}" -f $e.name, $e.id) }
            exit 0
        }

        'validate' {
            Require-Param 'ConfigDir' $ConfigDir
            $configs = @(Get-ApimConfigList -ConfigDir $ConfigDir -Api $Api)
            foreach ($c in $configs) {
                Write-Host "OK  $($c.Path)  ($(@($c.Policies).Count) policies, prune=$($c.Prune))"
            }
            Write-Host "$($configs.Count) config file(s) valid."
            exit 0
        }

        'reconcile' {
            Require-Param 'Environment' $Environment
            Require-Param 'ConfigDir' $ConfigDir
            $configs = @(Get-ApimConfigList -ConfigDir $ConfigDir -Api $Api)
            $results = @()
            foreach ($c in $configs) {
                $results += Invoke-ApimReconcile -Config $c -Environment $Environment `
                    -DryRun:$DryRun -CreateMode $CreateMode -PruneOverride $pruneOverride
            }
            if ($PlanOut) {
                $plain = $results | ForEach-Object {
                    [pscustomobject]@{
                        api = $_.Api; env = $_.Environment; instanceLabel = $_.InstanceLabel
                        instanceId = $_.InstanceId; action = $_.Action; changed = $_.Changed
                        dryRun = $_.DryRun
                        add = @($_.Plan.Add | ForEach-Object { "$($_.AssetId)@$($_.Version)" })
                        edit = @($_.Plan.Edit | ForEach-Object { "$($_.Desired.AssetId) [$($_.Changes -join ',')]" })
                        remove = @($_.Plan.Remove | ForEach-Object { "$($_.Policy.AssetId): $($_.Reason)" })
                        toggle = @($_.Plan.Toggle | ForEach-Object { "$($_.AssetId) disabled=$($_.Disabled)" })
                        drift = $_.Plan.Drift
                        orderWarnings = $_.Plan.OrderWarnings
                        messages = $_.Messages
                    }
                }
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PlanOut) | Out-Null
                $plain | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $PlanOut -Encoding utf8
                Write-Host "`nPlan written to $PlanOut"
            }
            $changed = @($results | Where-Object { $_.Changed } | ForEach-Object { $_.Api })
            $hasDrift = @($results | Where-Object { $_.Drift.Count -gt 0 }).Count -gt 0
            Write-Host "`nSummary: $($results.Count) api(s); changed: $(if ($changed) { $changed -join ', ' } else { 'none' }); dryRun=$([bool]$DryRun); drift=$hasDrift"
            if ($hasDrift -and -not $AllowDrift) { exit 3 }
            exit 0
        }

        'extract' {
            Require-Param 'Environment' $Environment
            Require-Param 'ConfigDir' $ConfigDir
            $initial = Get-ApimInitialEnv
            if ($Environment -ne $initial -and -not $Force) {
                Write-Error "Refusing to extract from '$Environment': only the initial environment ('$initial') is allowed. Use -Force to override."
                exit 4
            }
            $configs = @(Get-ApimConfigList -ConfigDir $ConfigDir -Api $Api)
            $changedPaths = @(); $keys = @(); $warn = 0
            foreach ($c in $configs) {
                $r = Export-ApimConfig -Config $c -Environment $Environment
                $r.Warnings | ForEach-Object { Write-Warning $_ ; $warn++ }
                if ($r.Changed) {
                    $changedPaths += $r.Path; $keys += $r.Api
                    Write-Host "updated $($r.Path) ($($r.PolicyCount) policies)"
                }
                else { Write-Host "no change $($r.Path)" }
            }
            if (-not $changedPaths) { Write-Host 'No config changes produced by extract.'; exit 0 }
            Write-Host "`nUpdated: $($keys -join ', ') ($warn warning(s))"
            if ($Commit) {
                $repo = if ($RepoDir) { $RepoDir } else { Split-Path -Parent (Split-Path -Parent $changedPaths[0]) }
                $msg = "chore(apim): extract $Environment policies ($($keys -join ', ')) [skip ci]"
                Invoke-ApimConfigCommit -RepoDir $repo -Path $changedPaths -Message $msg -Push:$Push -Branch $Branch | Out-Null
            }
            exit 0
        }
    }
}
catch {
    Write-Error $_
    exit 4
}
