<#
.SYNOPSIS
  Declarative Anypoint API Manager deployment driver (Anypoint CLI v4).

.DESCRIPTION
  Config repo layout: -ConfigDir points at the repo root, which holds one folder per
  API; each has an apimanager/ subfolder with one file per environment
  (<ConfigDir>/<api>/apimanager/<env>.yaml|json, e.g. orders-api/apimanager/test.json).

  reconcile    Make an environment match <api>/apimanager/<env>.yaml for exactly ONE api
               (-Api must name its folder; "all" is rejected - one run deploys one api).
               Creates the API instance from scratch (initial env) or by PROMOTING from
               the previous env, then applies only the policy differences. Empty diff =>
               no changes.
  extract      Read the policies applied on the instance and write them back into the
               config file, for exactly ONE api (same -Api rule as reconcile). Allowed
               only for the initial environment.
  validate     Offline schema/shape check of the config files. -Api all (the default) is
               fine here - it's read-only. Checks every environment file unless
               -Environment narrows it to one.
  login-check  Verify the connected-app credentials and list environments.

.EXAMPLE
  ./Invoke-ApimSync.ps1 -Action validate  -ConfigDir ./config
  ./Invoke-ApimSync.ps1 -Action reconcile -Environment test -ConfigDir ./config -Api orders-api -DryRun
  ./Invoke-ApimSync.ps1 -Action reconcile -Environment test -ConfigDir ./config -Api orders-api
  ./Invoke-ApimSync.ps1 -Action extract   -Environment test -ConfigDir ./config -Api orders-api -Commit -Push
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
    [string]$Branch,   # -Push without -Branch pushes back to whatever branch RepoDir has checked out
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

function Require-SingleApi([string]$Value) {
    # One API per run, by design: -Api all (or unset) is only meaningful for the read-only
    # 'validate' action, never for something that changes an API instance. SELECT_ONE is the
    # pipeline dropdown's inert placeholder (azure-pipelines.yml) - reject it by name so a run
    # queued without changing it gets "you didn't pick one", not a generic "not found".
    if (-not $Value -or $Value -eq 'all') {
        throw "-Api must name exactly one API folder for -Action $Action (deploying/extracting 'all' at once is not supported)"
    }
    if ($Value -eq 'SELECT_ONE') {
        throw "-Api is still 'SELECT_ONE' - pick a real API folder from the apiKey dropdown before queuing -Action $Action"
    }
}

# Troubleshooting banner - parameters plus the non-secret env context every issue in this
# tool has turned out to hinge on (control plane, org, env map, which policy-read path).
Write-Host "=== apim-sync ==="
Write-Host "action=$Action environment=$Environment configDir=$ConfigDir api=$Api dryRun=$([bool]$DryRun) createMode=$CreateMode prune=$Prune"
Write-Host "host=$(try { Get-ApimBaseUri } catch { "n/a ($($_.Exception.Message))" }) org=$($env:ANYPOINT_ORG) policyRead=$(if ($env:APIM_POLICY_READ) { $env:APIM_POLICY_READ } else { 'rest (default)' }) initialEnv=$(Get-ApimInitialEnv)"
Write-Host "envMap=$(if ($env:APIM_ENV_MAP) { $env:APIM_ENV_MAP } else { '(none - logical env names used as-is)' })"
Write-Host "clientId set=$([bool]$env:ANYPOINT_CLIENT_ID) clientSecret set=$([bool]$env:ANYPOINT_CLIENT_SECRET)"
Write-Host "PSVersion=$($PSVersionTable.PSVersion) OS=$($PSVersionTable.OS)"
Write-Host "=================="

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
            $configs = @(Get-ApimConfigList -ConfigDir $ConfigDir -Api $Api -Environment $Environment)
            foreach ($c in $configs) {
                Write-Host "OK  $($c.Path)  ($(@($c.Policies).Count) policies, prune=$($c.Prune))"
            }
            Write-Host "$($configs.Count) config file(s) valid."
            exit 0
        }

        'reconcile' {
            Require-Param 'Environment' $Environment
            Require-Param 'ConfigDir' $ConfigDir
            Require-SingleApi $Api
            $configs = @(Get-ApimConfigList -ConfigDir $ConfigDir -Api $Api -Environment $Environment)
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
            Require-SingleApi $Api
            $initial = Get-ApimInitialEnv
            if ($Environment -ne $initial -and -not $Force) {
                Write-Error "Refusing to extract from '$Environment': only the initial environment ('$initial') is allowed. Use -Force to override."
                exit 4
            }
            $configs = @(Get-ApimConfigList -ConfigDir $ConfigDir -Api $Api -Environment $Environment)
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
    $summary = "apim-sync ($Action, env=$Environment, api=$Api): $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    Write-Host "[error] $summary"
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host "[error] at: $($_.InvocationInfo.PositionMessage.Trim())"
    }
    if ($_.ScriptStackTrace) { Write-Host "[error] call stack:`n$($_.ScriptStackTrace)" }
    # Surface it as a pipeline-level issue (red annotation in the ADO run summary / Issues
    # tab), not just a line buried in the log. Harmless no-op outside Azure DevOps.
    $escaped = $summary -replace '%', '%25' -replace ';', '%3B' -replace "`r", '%0D' -replace "`n", '%0A'
    Write-Host "##vso[task.logissue type=error]$escaped"
    Write-Error $_
    exit 4
}
