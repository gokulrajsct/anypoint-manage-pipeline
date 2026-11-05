<#
.SYNOPSIS
  Declarative Anypoint API Manager deployment driver (Anypoint CLI v4).

.DESCRIPTION
  Config repo layout: -ConfigDir points at the repo root, which holds one folder per
  API; each has an apimanager/ subfolder with one file per environment
  (<ConfigDir>/<api>/apimanager/<env>.yaml|json, e.g. orders-api/apimanager/test.json).

  reconcile      Make an environment match <api>/apimanager/<env>.yaml for exactly ONE api
                 (-Api must name its folder; "all" is rejected - one run deploys one api).
                 Creates the API instance from scratch (initial env) or by PROMOTING from
                 the previous env, then applies only the policy differences. Empty diff =>
                 no changes. On a real (non-dry-run) change, configVersion is patch-bumped
                 (1.0.0 -> 1.0.1) and written back to the file - see "Versioning" below.
  extract        Read the policies applied on the instance and write them back into the
                 config file, for exactly ONE api (same -Api rule as reconcile). Allowed
                 only for the initial environment.
  validate       Offline schema/shape check of the config files. -Api all (the default) is
                 fine here - it's read-only. Checks every environment file unless
                 -Environment narrows it to one.
  validate-spec  NZ Government API Standard check: downloads the Exchange spec for the one
                 api's apiInstance.assetId/assetVersion and lints it with Spectral, using
                 the ruleset for apiInstance.classification (internal/external/partner/
                 public; unset -> public, the strictest tier). Requires the `spectral` CLI
                 on PATH and network+credentials (same ones used for the REST policy read).
  redeploy       Roll back: restore <api>/apimanager/<env>.yaml to the content it had at
                 -TargetVersion (found via git history of the file under -RepoDir) and
                 reconcile that content. A successful redeploy is itself a new deployment,
                 so configVersion advances again (e.g. redeploying 1.0.1 on top of 1.0.5
                 becomes 1.0.6, not a reset back to 1.0.1) - git history is the full record.
  login-check    Verify the connected-app credentials and list environments.

.NOTES
  Versioning: configVersion (in the config file, independent of apiInstance.assetVersion)
  starts at 1.0.0 and is patch-bumped by every applied reconcile/redeploy. Pair -Commit
  (and -Push) with -RepoDir so the bump lands in git - that history IS the version store;
  there's no separate database. Pass -ArtifactDir to also write a
  <api>-<env>-v<version>.json snapshot of what was applied, for audit/CI-artifact capture.

.EXAMPLE
  ./Invoke-ApimSync.ps1 -Action validate      -ConfigDir ./config
  ./Invoke-ApimSync.ps1 -Action validate-spec -Environment test -ConfigDir ./config -Api orders-api
  ./Invoke-ApimSync.ps1 -Action reconcile     -Environment test -ConfigDir ./config -Api orders-api -DryRun
  ./Invoke-ApimSync.ps1 -Action reconcile     -Environment test -ConfigDir ./config -Api orders-api -Commit -Push -RepoDir ./config-repo
  ./Invoke-ApimSync.ps1 -Action extract       -Environment test -ConfigDir ./config -Api orders-api -Commit -Push
  ./Invoke-ApimSync.ps1 -Action redeploy      -Environment test -ConfigDir ./config -Api orders-api -TargetVersion 1.0.3 -RepoDir ./config-repo -Commit -Push
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('reconcile', 'extract', 'validate', 'validate-spec', 'redeploy', 'login-check')][string]$Action,
    [string]$Environment,
    [string]$ConfigDir,
    [string]$Api = 'all',
    [switch]$DryRun,
    [ValidateSet('auto', 'scratch', 'promote')][string]$CreateMode = 'auto',
    [ValidateSet('fromconfig', 'true', 'false')][string]$Prune = 'fromconfig',
    [string]$PlanOut,
    [string]$ArtifactDir,     # reconcile/redeploy: write <api>-<env>-v<version>.json here on a real change
    [string]$TargetVersion,   # redeploy: the configVersion to restore and reconcile
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

function Invoke-ApplyAndVersion {
    <# Reconcile one config, then - only on a real, non-dry-run, non-empty-plan change -
       patch-bump configVersion, write the audit artifact, and (if -Commit) commit it.
       Shared by 'reconcile' and 'redeploy' so both version the same way. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Env)

    # Create $ArtifactDir unconditionally (even when nothing ends up written into it) so a
    # pipeline step that publishes it as a build artifact never fails with "path not found"
    # on a no-op or dry-run reconcile.
    if ($ArtifactDir) { New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null }

    $result = Invoke-ApimReconcile -Config $Config -Environment $Env `
        -DryRun:$DryRun -CreateMode $CreateMode -PruneOverride $pruneOverride

    if ($result.Changed -and -not $DryRun) {
        $prevVersion = $Config.ConfigVersion
        $nextVersion = Step-ApimConfigVersion $prevVersion
        $verResult = Set-ApimConfigVersion -Config $Config -Version $nextVersion
        Write-Host "[version] $($Config.Key)/${Env}: configVersion $prevVersion -> $nextVersion"

        if ($ArtifactDir) {
            $artifactPath = Join-Path $ArtifactDir "$($Config.Key)-$Env-v$nextVersion.json"
            [ordered]@{
                api = $Config.Key; environment = $Env
                configVersion = $nextVersion; previousConfigVersion = $prevVersion
                instanceId = $result.InstanceId; action = $result.Action
                appliedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
                apiInstance = $Config.ApiInstance; policies = $Config.Policies
            } | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $artifactPath -Encoding utf8
            Write-Host "[version] artifact written: $artifactPath"
        }

        if ($Commit) {
            $repo = if ($RepoDir) { $RepoDir } else { Split-Path -Parent (Split-Path -Parent $Config.Path) }
            $msg = "chore(apim): $($Config.Key) $Env configVersion -> $nextVersion [skip ci]"
            Invoke-ApimConfigCommit -RepoDir $repo -Path $verResult.Path -Message $msg -Push:$Push -Branch $Branch | Out-Null
        }
        $result | Add-Member -NotePropertyName ConfigVersion -NotePropertyValue $nextVersion -Force
    }
    return $result
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

# -TargetVersion only ever does anything for -Action redeploy (see that case below); flag it
# rather than silently ignore it, in case someone filled it in expecting it to matter for
# deploy/extract/reconcile too.
if ($TargetVersion -and $Action -ne 'redeploy') {
    Write-Host "##vso[task.logissue type=warning]-TargetVersion '$TargetVersion' was provided but -Action is '$Action' - it has no effect except for -Action redeploy."
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
            $configs = @(Get-ApimConfigList -ConfigDir $ConfigDir -Api $Api -Environment $Environment)
            foreach ($c in $configs) {
                Write-Host "OK  $($c.Path)  ($(@($c.Policies).Count) policies, prune=$($c.Prune), configVersion=$($c.ConfigVersion))"
            }
            Write-Host "$($configs.Count) config file(s) valid."
            exit 0
        }

        'validate-spec' {
            Require-Param 'Environment' $Environment
            Require-Param 'ConfigDir' $ConfigDir
            Require-SingleApi $Api
            $c = @(Get-ApimConfigList -ConfigDir $ConfigDir -Api $Api -Environment $Environment)[0]

            if ($c.ApiInstance.skipSpecValidation) {
                Write-Host "##vso[task.logissue type=warning]$($c.Key): apiInstance.skipSpecValidation is true - skipping the NZ Government API Standard spec lint. This is a deliberate per-api opt-out (e.g. a spec-less Exchange 'HTTP API' asset); prefer attaching an OAS spec instead of leaving this set."
                exit 0
            }

            $classification = "$($c.ApiInstance.classification)"
            if (-not $classification) { $classification = 'public' }   # unset -> strictest tier
            $rulesetFile = Join-Path $PSScriptRoot "spec-rules/nz-api-standard.$classification.yaml"
            if (-not (Test-Path -LiteralPath $rulesetFile)) { throw "No ruleset for classification '$classification': $rulesetFile" }

            $groupId = $c.ApiInstance.groupId
            if (-not $groupId) { $groupId = Get-ApimOrgId }
            # .yaml extension even for an OAS file that's actually JSON - Spectral's parser
            # tries YAML first (which also reads valid JSON) regardless of file extension.
            $specFile = Join-Path ([System.IO.Path]::GetTempPath()) "$($c.Key)-$Environment-spec.yaml"
            $spec = Get-ApimExchangeAssetSpec -GroupId $groupId -AssetId $c.ApiInstance.assetId `
                -AssetVersion $c.ApiInstance.assetVersion -OutFile $specFile
            Write-Host "[spec] $($c.Key): classification=$classification ruleset=nz-api-standard.$classification.yaml spec=$($spec.Classifier)"
            try {
                $lintResults = Invoke-ApimSpecLint -SpecFile $spec.Path -RulesetFile $rulesetFile
            }
            finally { Remove-Item -LiteralPath $specFile -ErrorAction SilentlyContinue }

            # A mismatch against the standard is a warning, not a pipeline failure - it's
            # surfaced loudly (console + an ADO warning annotation) but never blocks reconcile.
            $specErrors = @($lintResults | Where-Object { [int]$_.severity -eq 0 })
            if ($specErrors.Count -gt 0) {
                Write-Host "##vso[task.logissue type=warning]$($c.Key): $($specErrors.Count) finding(s) against the NZ Government API Standard ($classification tier) - see [spec] lines above. Not blocking the pipeline."
            }
            else {
                Write-Host "Spec OK against the NZ Government API Standard ($classification tier)."
            }
            exit 0
        }

        'reconcile' {
            Require-Param 'Environment' $Environment
            Require-Param 'ConfigDir' $ConfigDir
            Require-SingleApi $Api
            $configs = @(Get-ApimConfigList -ConfigDir $ConfigDir -Api $Api -Environment $Environment)
            $results = @()
            foreach ($c in $configs) { $results += Invoke-ApplyAndVersion -Config $c -Env $Environment }

            if ($PlanOut) {
                $plain = $results | ForEach-Object {
                    [pscustomobject]@{
                        api = $_.Api; env = $_.Environment; instanceLabel = $_.InstanceLabel
                        instanceId = $_.InstanceId; action = $_.Action; changed = $_.Changed
                        dryRun = $_.DryRun
                        configVersion = $_.PSObject.Properties['ConfigVersion'] | ForEach-Object { $_.Value }
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

        'redeploy' {
            Require-Param 'Environment' $Environment
            Require-Param 'ConfigDir' $ConfigDir
            Require-SingleApi $Api
            Require-Param 'TargetVersion' $TargetVersion
            Require-Param 'RepoDir' $RepoDir
            $c = @(Get-ApimConfigList -ConfigDir $ConfigDir -Api $Api -Environment $Environment)[0]

            $hist = Get-ApimConfigAtVersion -RepoDir $RepoDir -Path $c.Path -Version $TargetVersion
            $shortSha = $hist.Commit.Substring(0, [Math]::Min(8, $hist.Commit.Length))
            Write-Host "[redeploy] $($c.Key)/${Environment}: restoring configVersion $TargetVersion from commit $shortSha"
            Set-Content -LiteralPath $c.Path -Value $hist.Content -Encoding utf8
            $restored = Read-ApimConfig -Path $c.Path -ApiKey $c.Key

            $result = Invoke-ApplyAndVersion -Config $restored -Env $Environment
            $hasDrift = $result.Drift.Count -gt 0
            Write-Host "`nSummary: redeploy of $($restored.Key)/$Environment to $TargetVersion (from $shortSha); changed=$($result.Changed); dryRun=$([bool]$DryRun); drift=$hasDrift"
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
