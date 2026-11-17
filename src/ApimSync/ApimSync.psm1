#Requires -Version 5.1
Set-StrictMode -Version 2.0

if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    throw "The 'powershell-yaml' module is required. Install it with: " +
          "Install-Module powershell-yaml -Scope CurrentUser -Force"
}
Import-Module 'powershell-yaml' -ErrorAction Stop

$script:MuleSoftGroupId = '68ef9520-24e9-4cf2-b2f5-620025690913'
$script:DeploymentTypeMap = @{
    'CH2' = 'cloudhub2'; 'CH' = 'cloudhub'; 'HY' = 'hybrid'; 'RF' = 'rtf'
    'cloudhub2' = 'cloudhub2'; 'cloudhub' = 'cloudhub'; 'hybrid' = 'hybrid'; 'rtf' = 'rtf'
}

# NZ Government API Standard audience categories (standards.digital.govt.nz). Picks which
# spec-rules/*.yaml Spectral ruleset tier Invoke-ApimSpecLint applies.
$script:ApiClassifications = @('internal', 'external', 'partner', 'public')

# REST read path state (per process). ApimApiContext maps an API instance id to the
# org/env ids seen on the `api list` / `api manage` / `api promote` response, so the
# policies endpoint can be built without an extra lookup.
$script:ApimApiContext = @{}
$script:ApimToken = $null
$script:ApimOrgId = $null

# configurationData keys excluded from the desired-vs-live diff (top level only) so
# reconcile can converge. Two reasons a key lands here:
#   - required on `policy apply` but never echoed by `policy list` (e.g. jwt-validation textKey)
#   - injected by `policy list` but not part of desired config (e.g. assetId/assetVersion)
# Ignored for comparison only; the full configurationData is still sent on apply/edit.
$script:PolicyConfigDiffIgnoreCommon = @('assetId', 'assetVersion', 'policyTemplateId')
$script:PolicyConfigDiffIgnore = @{
    "$($script:MuleSoftGroupId):jwt-validation" = @('textKey')
}

function Get-ApimInitialEnv {
    if ($env:APIM_INITIAL_ENV) { return $env:APIM_INITIAL_ENV }
    return 'dev'
}

# --------------------------------------------------------------------------- #
# Generic helpers
# --------------------------------------------------------------------------- #
function Get-DictValue {
    param($Dictionary, [string]$Key)
    if ($null -eq $Dictionary) { return $null }
    if ($Dictionary -is [System.Collections.IDictionary]) {
        if ($Dictionary.Contains($Key)) { return $Dictionary[$Key] }
        return $null
    }
    if ($Dictionary -is [psobject] -and $Dictionary.PSObject.Properties[$Key]) {
        return $Dictionary.$Key
    }
    return $null
}

function Get-FirstValue {
    param($Dictionary, [string[]]$Keys)
    foreach ($k in $Keys) {
        $v = Get-DictValue $Dictionary $k
        if ($null -ne $v -and "$v" -ne '') { return $v }
    }
    return $null
}

function ConvertTo-Dict {
    param($Object)
    if ($Object -is [System.Collections.IDictionary]) { return $Object }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    }
    return $null
}

function ConvertTo-Arr {
    param($Object)
    if ($Object -is [string]) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $null }
    if ($Object -is [System.Management.Automation.PSCustomObject]) { return $null }
    if ($Object -is [System.Collections.IEnumerable]) { return , [object[]]@($Object) }
    return $null
}

function Test-ApimMaskedValue {
    param($Value)
    return ($Value -is [string]) -and ($Value -match '^\*{3,}$')
}

function ConvertTo-CanonicalObject {
    <# Recursively sort mapping keys; preserve list order (significant in policy configs). #>
    param($InputObject)
    if ($null -eq $InputObject) { return $null }

    $dict = ConvertTo-Dict $InputObject
    if ($null -ne $dict) {
        $out = [ordered]@{}
        foreach ($k in ($dict.Keys | Sort-Object { "$_" })) {
            $out["$k"] = ConvertTo-CanonicalObject $dict[$k]
        }
        return $out
    }
    $arr = ConvertTo-Arr $InputObject
    if ($null -ne $arr) {
        $list = @()
        foreach ($item in $arr) { $list += , (ConvertTo-CanonicalObject $item) }
        return , $list
    }
    return $InputObject
}

function ConvertTo-CanonicalJson {
    param($InputObject)
    $canon = ConvertTo-CanonicalObject $InputObject
    if ($null -eq $canon) { return 'null' }
    return ($canon | ConvertTo-Json -Depth 40 -Compress)
}

function ConvertTo-ApimPointcutArray {
    <# API Manager pointcutData is always a JSON array. Wrap a lone mapping in one. #>
    param($Pointcut)
    if ($null -eq $Pointcut) { return $null }
    $arr = ConvertTo-Arr $Pointcut
    if ($null -ne $arr) { return , [object[]]@($arr) }
    return , [object[]]@($Pointcut)
}

function ConvertTo-ApimPointcutJson {
    <# Canonical JSON *array* text for --pointcut and for comparison. ConvertTo-Json unwraps
       a one-element array, so build the brackets by hand. #>
    param($Pointcut)
    $arr = ConvertTo-ApimPointcutArray $Pointcut
    if ($null -eq $arr) { return 'null' }
    return '[' + (($arr | ForEach-Object { ConvertTo-CanonicalJson $_ }) -join ',') + ']'
}

function Test-ApimConfigTreeEqual {
    <# True when Desired would be a no-op against Live: every key/value in Desired must
       match Live. Keys present only on Live are ignored (the live policy carries defaults
       and metadata the config never sets). Masked Live leaves are ignored. #>
    param($Desired, $Live)

    if (Test-ApimMaskedValue $Live) { return $true }

    $dNull = ($null -eq $Desired); $lNull = ($null -eq $Live)
    if ($dNull -and $lNull) { return $true }
    if ($dNull -or $lNull) { return $false }

    $dDict = ConvertTo-Dict $Desired; $lDict = ConvertTo-Dict $Live
    if (($null -ne $dDict) -and ($null -ne $lDict)) {
        foreach ($k in $dDict.Keys) {
            $ks = "$k"
            if (-not $lDict.Contains($ks)) {
                if (-not (Test-ApimConfigTreeEqual $dDict[$k] $null)) { return $false }
                continue
            }
            if (-not (Test-ApimConfigTreeEqual $dDict[$k] $lDict[$ks])) { return $false }
        }
        return $true
    }
    if (($null -ne $dDict) -or ($null -ne $lDict)) { return $false }

    $dArr = ConvertTo-Arr $Desired; $lArr = ConvertTo-Arr $Live
    if (($null -ne $dArr) -and ($null -ne $lArr)) {
        $dArr = [object[]]@($dArr); $lArr = [object[]]@($lArr)
        if ($dArr.Count -ne $lArr.Count) { return $false }
        for ($i = 0; $i -lt $dArr.Count; $i++) {
            if (-not (Test-ApimConfigTreeEqual $dArr[$i] $lArr[$i])) { return $false }
        }
        return $true
    }
    if (($null -ne $dArr) -or ($null -ne $lArr)) { return $false }

    # bool on either side, or "true"/"false" text on both (policy list stringifies scalars)
    $dBoolish = ($Desired -is [bool]) -or ("$Desired".Trim() -match '^(?i:true|false)$')
    $lBoolish = ($Live -is [bool]) -or ("$Live".Trim() -match '^(?i:true|false)$')
    if ((($Desired -is [bool]) -or ($Live -is [bool])) -or ($dBoolish -and $lBoolish)) {
        return (ConvertTo-ApimBool $Desired) -eq (ConvertTo-ApimBool $Live)
    }
    if (("$Desired" -match '^\s*-?\d+(\.\d+)?\s*$') -and ("$Live" -match '^\s*-?\d+(\.\d+)?\s*$')) {
        return ([double]$Desired) -eq ([double]$Live)
    }
    return "$Desired" -eq "$Live"
}

function ConvertTo-ApimBool {
    <# PowerShell's [bool]"false" is $true; parse the text instead. #>
    param($Value)
    if ($Value -is [bool]) { return $Value }
    return ("$Value".Trim().ToLower() -eq 'true')
}

function Format-ApimDiffValue {
    param($Value)
    if ($null -eq $Value) { return '<null>' }
    if ($null -ne (ConvertTo-Dict $Value)) { return '<object>' }
    if ($null -ne (ConvertTo-Arr $Value)) { return '<array>' }
    $s = "$Value"
    if ($s.Length -gt 80) { $s = $s.Substring(0, 77) + '...' }
    return "'$s' [$($Value.GetType().Name)]"
}

function Get-ApimConfigTreeDiff {
    <# Paths where Desired would change Live. Same equality rules as Test-ApimConfigTreeEqual. #>
    param($Desired, $Live, [string]$Path = '')

    if (Test-ApimMaskedValue $Live) { return @() }

    $dNull = ($null -eq $Desired); $lNull = ($null -eq $Live)
    if ($dNull -and $lNull) { return @() }
    if ($dNull -or $lNull) {
        return @("$Path : desired=$(Format-ApimDiffValue $Desired) live=$(Format-ApimDiffValue $Live)")
    }

    $dDict = ConvertTo-Dict $Desired; $lDict = ConvertTo-Dict $Live
    if (($null -ne $dDict) -and ($null -ne $lDict)) {
        $diffs = @()
        foreach ($k in ($dDict.Keys | ForEach-Object { "$_" })) {
            if (-not $lDict.Contains($k)) {
                $diffs += "$Path/$k : in config but not on the live policy (=$(Format-ApimDiffValue $dDict[$k]))"
            }
            else {
                $diffs += Get-ApimConfigTreeDiff $dDict[$k] $lDict[$k] "$Path/$k"
            }
        }
        return $diffs   # keys only on the live policy are not drift - not reported
    }
    if (($null -ne $dDict) -or ($null -ne $lDict)) {
        return @("$Path : one side is an object, the other is not")
    }

    $dArr = ConvertTo-Arr $Desired; $lArr = ConvertTo-Arr $Live
    if (($null -ne $dArr) -and ($null -ne $lArr)) {
        $dArr = [object[]]@($dArr); $lArr = [object[]]@($lArr)
        if ($dArr.Count -ne $lArr.Count) {
            return @("$Path : array length config=$($dArr.Count) live=$($lArr.Count)")
        }
        $diffs = @()
        for ($i = 0; $i -lt $dArr.Count; $i++) {
            $diffs += Get-ApimConfigTreeDiff $dArr[$i] $lArr[$i] "$Path[$i]"
        }
        return $diffs
    }
    if (($null -ne $dArr) -or ($null -ne $lArr)) {
        return @("$Path : one side is an array, the other is not")
    }

    if (Test-ApimConfigTreeEqual $Desired $Live) { return @() }
    return @("$Path : config=$(Format-ApimDiffValue $Desired) live=$(Format-ApimDiffValue $Live)")
}

function Restore-ApimMaskedValue {
    <# Return a copy of Live where masked leaves are replaced by Existing's value at the same path. #>
    param($Live, $Existing)

    if (Test-ApimMaskedValue $Live) {
        if (($null -ne $Existing) -and -not (Test-ApimMaskedValue $Existing)) { return $Existing }
        return $Live
    }
    $lDict = ConvertTo-Dict $Live
    if ($null -ne $lDict) {
        $eDict = ConvertTo-Dict $Existing
        $out = [ordered]@{}
        foreach ($k in $lDict.Keys) {
            $ev = if ($null -ne $eDict) { Get-DictValue $eDict "$k" } else { $null }
            $out["$k"] = Restore-ApimMaskedValue $lDict[$k] $ev
        }
        return $out
    }
    $lArr = ConvertTo-Arr $Live
    if ($null -ne $lArr) {
        $out = @()
        foreach ($item in $lArr) { $out += , (Restore-ApimMaskedValue $item $null) }
        return , $out
    }
    return $Live
}

# --------------------------------------------------------------------------- #
# Config loading + validation
# --------------------------------------------------------------------------- #
function Read-ApimConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$ApiKey)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    # ConvertFrom-Yaml parses JSON too (JSON is valid YAML); one code path for .yaml/.yml/.json.
    try {
        $raw = ConvertFrom-Yaml (Get-Content -Raw -LiteralPath $Path) -Ordered
    }
    catch { throw "${Path}: could not parse as YAML/JSON - $($_.Exception.Message)" }
    if (($null -eq $raw) -or -not ($raw -is [System.Collections.IDictionary])) {
        throw "$Path must contain a mapping (object) at the top level"
    }

    $inst = Get-DictValue $raw 'apiInstance'
    if ($null -eq $inst) { throw "${Path}: 'apiInstance' is required" }
    foreach ($req in @('assetId', 'assetVersion', 'instanceLabel')) {
        if (-not (Get-DictValue $inst $req)) { throw "${Path}: apiInstance.$req is required" }
    }
    $dt = Get-DictValue $inst 'deploymentType'
    if ($dt -and -not $script:DeploymentTypeMap.ContainsKey("$dt")) {
        throw "${Path}: invalid apiInstance.deploymentType '$dt' (allowed: cloudhub, cloudhub2, hybrid, rtf)"
    }
    $classification = Get-DictValue $inst 'classification'
    if ($classification -and ($script:ApiClassifications -notcontains "$classification")) {
        throw "${Path}: invalid apiInstance.classification '$classification' (allowed: $($script:ApiClassifications -join ', '))"
    }
    $inst['skipSpecValidation'] = ConvertTo-ApimBool (Get-DictValue $inst 'skipSpecValidation')

    $configVersion = Get-DictValue $raw 'configVersion'
    if (-not $configVersion) { $configVersion = '1.0.0' }
    if ("$configVersion" -notmatch '^\d+\.\d+\.\d+$') {
        throw "${Path}: configVersion '$configVersion' must be a plain semver x.y.z"
    }

    $policies = @()
    $rawPolicies = Get-DictValue $raw 'policies'
    if ($rawPolicies) { $policies = @($rawPolicies) }
    $idx = 0
    # The same assetId CAN legitimately appear more than once (one instance per path/role,
    # e.g. jwt-validation applied separately to /admin/* and /public/*) - Resolve-ApimPolicyKeys
    # tracks those as distinct entities by pointcut. But two entries with the SAME assetId
    # AND the exact same pointcut is a real config mistake Anypoint will reject on apply
    # ("the policy defines a pointcut already defined by a policy with the same
    # characteristics") - catch it here with a clear message instead.
    $seenSlots = @{}
    foreach ($p in $policies) {
        $idx++
        foreach ($req in @('assetId', 'version')) {
            if (-not (Get-DictValue $p $req)) { throw "${Path}: policies[$idx].$req is required" }
        }
        if (-not ($p -is [System.Collections.IDictionary]) -or -not $p.Contains('configurationData')) {
            throw "${Path}: policies[$idx].configurationData is required (use {} for none)"
        }
        if ($null -eq (Get-DictValue $p 'order')) { $p['order'] = $idx }

        $gid = Get-DictValue $p 'groupId'; if (-not $gid) { $gid = $script:MuleSoftGroupId }
        $slotKey = '{0}:{1}::{2}' -f $gid, (Get-DictValue $p 'assetId'), (ConvertTo-ApimPointcutJson (Get-DictValue $p 'pointcutData'))
        if ($seenSlots.ContainsKey($slotKey)) {
            throw "${Path}: policies[$($seenSlots[$slotKey])] and policies[$idx] both apply '$(Get-DictValue $p 'assetId')' to the exact same pointcut - give them different pointcutData, or Anypoint will reject the duplicate on apply"
        }
        $seenSlots[$slotKey] = $idx
    }

    $promotion = Get-DictValue $raw 'promotion'
    if ($null -eq $promotion) { $promotion = [ordered]@{} }
    $prune = if ($raw.Contains('prune')) { [bool]$raw['prune'] } else { $true }

    [pscustomobject]@{
        Path          = (Resolve-Path -LiteralPath $Path).Path
        Key           = if ($ApiKey) { $ApiKey } else { [System.IO.Path]::GetFileNameWithoutExtension($Path) }
        Raw           = $raw
        ApiInstance   = $inst
        Promotion     = $promotion
        Prune         = $prune
        Policies      = $policies
        ConfigVersion = "$configVersion"
    }
}

function Get-ApimConfigList {
    <# Config repo layout: <ConfigDir>/<api>/apimanager/<env>.(yaml|yml|json) - one folder per
       API (the folder name is the API key), one file per environment (the file stem is the
       logical env name, e.g. test.json / uat.yaml / prod.yaml).
       -Environment filters to that one file per API folder; omit it to load every environment
       file for every matched API (used by `validate`, which has no single env to check). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigDir, [string]$Api = 'all', [string]$Environment)

    if (-not (Test-Path -LiteralPath $ConfigDir)) { throw "Config directory not found: $ConfigDir" }
    Write-Host "[config] scanning $ConfigDir (api='$Api', environment='$(if ($Environment) { $Environment } else { '(all)' })')"
    $projectDirs = @(Get-ChildItem -LiteralPath $ConfigDir -Directory | Sort-Object Name)
    if ($Api -and $Api -ne 'all') {
        $projectDirs = @($projectDirs | Where-Object { $_.Name -eq $Api })
        if (-not $projectDirs) {
            $seen = @(Get-ChildItem -LiteralPath $ConfigDir -Directory | ForEach-Object { $_.Name })
            throw "No api folder '$Api' under $ConfigDir (api folders seen: $(if ($seen) { $seen -join ', ' } else { 'none' }))"
        }
    }

    $results = @()
    foreach ($proj in $projectDirs) {
        $amDir = Join-Path $proj.FullName 'apimanager'
        if (-not (Test-Path -LiteralPath $amDir)) {
            Write-Host "[config] $($proj.Name): no apimanager/ folder - skipped"
            continue
        }
        $files = @(Get-ChildItem -LiteralPath $amDir -File |
            Where-Object { @('.yaml', '.yml', '.json') -contains $_.Extension } | Sort-Object Name)
        $dupe = $files | Group-Object BaseName | Where-Object Count -gt 1
        if ($dupe) { throw "Ambiguous config: $($dupe.Name -join ', ') defined in more than one file under $amDir" }
        if ($Environment) {
            $matched = @($files | Where-Object { $_.BaseName -eq $Environment })
            if (-not $matched) {
                Write-Host "[config] $($proj.Name): no '$Environment' file (has: $(if ($files) { $files.BaseName -join ', ' } else { 'none' })) - skipped"
            }
            $files = $matched
        }
        foreach ($f in $files) {
            Write-Host "[config] $($proj.Name)/$($f.Name) -> api key '$($proj.Name)'"
            $results += Read-ApimConfig -Path $f.FullName -ApiKey $proj.Name
        }
    }

    if (-not $results) {
        $envPart = if ($Environment) { "'$Environment' " } else { '' }
        if ($Api -and $Api -ne 'all') { throw "No ${envPart}config for api '$Api' under $ConfigDir" }
        throw "No ${envPart}config files found under $ConfigDir (expected <api>/apimanager/<env>.yaml|json)"
    }
    Write-Host "[config] loaded $($results.Count) config file(s): $($results.Key -join ', ')"
    # No leading comma: every call site wraps this in @(...), and a comma-protected return
    # collapses through that wrapping - @(Get-ApimConfigList ...) would come back as a single
    # element holding the whole array instead of one element per config.
    return $results
}

# --------------------------------------------------------------------------- #
# Anypoint CLI wrappers
# --------------------------------------------------------------------------- #
function Invoke-AnypointCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [switch]$AsJson,
        [switch]$AllowFail
    )
    $exe = if ($env:ANYPOINT_CLI) { $env:ANYPOINT_CLI } else { 'anypoint-cli-v4' }
    Write-Host "[anypoint-cli] $exe $($ArgumentList -join ' ')"
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $stdout = (& $exe @ArgumentList 2> $errFile | Out-String)
        $code = $LASTEXITCODE
        $stderr = (Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue)
    }
    finally {
        Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
    }
    Write-Host "[anypoint-cli] exit $code"
    if ($stdout -and $stdout.Trim()) { Write-Host "[anypoint-cli] response:`n$($stdout.Trim())" }
    if ($stderr -and $stderr.Trim()) { Write-Host "[anypoint-cli] stderr:`n$($stderr.Trim())" }
    if (($code -ne 0) -and -not $AllowFail) {
        throw "anypoint-cli-v4 $($ArgumentList -join ' ') failed (exit $code):`n$stderr`n$stdout"
    }
    if ($AsJson) {
        $text = $stdout.Trim()
        if (-not $text) { return $null }
        try { return ($text | ConvertFrom-Json) }
        catch {
            $i = $text.IndexOfAny([char[]]@('{', '['))
            if ($i -ge 0) { return ($text.Substring($i) | ConvertFrom-Json) }
            throw
        }
    }
    return $stdout
}

function Resolve-ApimEnvironmentName {
    param([Parameter(Mandatory)][string]$LogicalEnv)
    if ($env:APIM_ENV_MAP) {
        $map = $env:APIM_ENV_MAP | ConvertFrom-Json
        if ($map.PSObject.Properties[$LogicalEnv]) {
            $resolved = "$($map.$LogicalEnv)"
            Write-Host "[env] '$LogicalEnv' -> '$resolved' (APIM_ENV_MAP)"
            return $resolved
        }
        Write-Host "[env] '$LogicalEnv' has no APIM_ENV_MAP entry - using it as the Anypoint environment name"
    }
    return $LogicalEnv
}

function Get-ApimEnvironmentId {
    param([Parameter(Mandatory)][string]$EnvName)
    $data = Invoke-AnypointCli -ArgumentList @('account', 'environment', 'list', '--output', 'json') -AsJson
    foreach ($e in @($data)) {
        if (($e.name -eq $EnvName) -or ($e.id -eq $EnvName)) {
            Write-Host "[env] '$EnvName' resolved to environment id $($e.id)"
            return "$($e.id)"
        }
    }
    $seen = @(@($data) | ForEach-Object { $_.name })
    throw "Environment '$EnvName' not found in this organization (environments seen: $(if ($seen) { $seen -join ', ' } else { 'none' }))"
}

function Get-ApimInstanceId {
    param(
        [Parameter(Mandatory)][string]$EnvName,
        [Parameter(Mandatory)][string]$InstanceLabel
    )
    $res = Invoke-AnypointCli -AsJson -ArgumentList @(
        'api-mgr', 'api', 'list', '--instanceLabel', $InstanceLabel,
        '--environment', $EnvName, '--output', 'json')

    $items = @()
    if ($null -eq $res) { $items = @() }
    elseif ($res -is [System.Array]) { $items = $res }
    elseif ($res.PSObject.Properties['apis']) { $items = @($res.apis) }
    elseif ($res.PSObject.Properties['assets']) { foreach ($a in @($res.assets)) { $items += @($a.apis) } }
    else { $items = @($res) }

    foreach ($i in $items) {
        $label = if ($i.PSObject.Properties['instanceLabel']) { $i.instanceLabel } else { $null }
        if ($label -eq $InstanceLabel) {
            Write-Host "[instance] '$InstanceLabel' -> id $($i.id) in '$EnvName'"
            Set-ApimApiContext $i
            return "$($i.id)"
        }
    }
    $seen = @($items | ForEach-Object { if ($_.PSObject.Properties['instanceLabel']) { $_.instanceLabel } } | Where-Object { $_ })
    Write-Host "[instance] '$InstanceLabel' not found in '$EnvName' (instance labels seen: $(if ($seen) { $seen -join ', ' } else { 'none' }))"
    return $null
}

function Resolve-ApimPromotedInstanceId {
    <# `api-mgr api promote` does not keep the source instance's label verbatim - Anypoint
       appends " (promoted)" to it, so the exact config label is never there right after a
       promote and every later lookup by that clean label keeps missing it. Try the clean
       label first (already fixed up, or never needed it), then the mangled form Anypoint
       actually assigns; if found only under the mangled form, rename it back via
       `api edit --apiInstanceLabel` so every later lookup - and the user's own view in API
       Manager - uses the clean, config-matching label from here on. #>
    param([Parameter(Mandatory)][string]$EnvName, [Parameter(Mandatory)][string]$Label)
    $id = Get-ApimInstanceId -EnvName $EnvName -InstanceLabel $Label
    if ($id) { return $id }
    $mangled = "$Label (promoted)"
    $id = Get-ApimInstanceId -EnvName $EnvName -InstanceLabel $mangled
    if ($id) {
        Write-Host "[promote] Anypoint labeled the instance '$mangled' - renaming it back to '$Label'."
        Invoke-AnypointCli -ArgumentList @(
            'api-mgr', 'api', 'edit', $id, '--apiInstanceLabel', $Label,
            '--environment', $EnvName, '--output', 'json') -AsJson | Out-Null
    }
    return $id
}

function Set-ApimApiContext {
    <# Remember org/env ids from an API object so the REST policies call needs no extra lookup. #>
    param($ApiObject)
    $id = Get-DictValue $ApiObject 'id'
    if (-not $id) { return }
    $org = Get-DictValue $ApiObject 'organizationId'
    $envId = Get-DictValue $ApiObject 'environmentId'
    if ($org -or $envId) { $script:ApimApiContext["$id"] = @{ OrgId = "$org"; EnvId = "$envId" } }
}

function Get-CliDeploymentType {
    param([string]$Value)
    if (-not $Value) { return 'cloudhub2' }
    if ($script:DeploymentTypeMap.ContainsKey($Value)) { return $script:DeploymentTypeMap[$Value] }
    return $Value
}

function New-ApimInstance {
    param([Parameter(Mandatory)][string]$EnvName, [Parameter(Mandatory)]$Config)
    $inst = $Config.ApiInstance
    $args = @('api-mgr', 'api', 'manage', "$($inst.assetId)", "$($inst.assetVersion)")
    if (Get-DictValue $inst 'groupId') { $args += "$($inst.groupId)" }
    $args += @('--environment', $EnvName,
               '--deploymentType', (Get-CliDeploymentType (Get-DictValue $inst 'deploymentType')),
               '--output', 'json')

    $ep = Get-DictValue $inst 'endpoint'
    if ($ep) {
        if (Get-DictValue $ep 'implementationUri') { $args += @('--uri', "$($ep.implementationUri)") }
        if (Get-DictValue $ep 'consumerUri') { $args += @('--endpointUri', "$($ep.consumerUri)") }
        if (Get-DictValue $ep 'type') { $args += @('--type', "$($ep.type)") }
        if (Get-DictValue $ep 'scheme') { $args += @('--scheme', "$($ep.scheme)") }
        if ($null -ne (Get-DictValue $ep 'port')) { $args += @('--port', "$($ep.port)") }
        if ($null -ne (Get-DictValue $ep 'path')) { $args += @('--path', "$($ep.path)") }
        if (Get-DictValue $ep 'responseTimeout') { $args += @('--responseTimeout', "$($ep.responseTimeout)") }
        if (Get-DictValue $ep 'withProxy') { $args += '--withProxy' }
        if (Get-DictValue $ep 'muleVersion4OrAbove') { $args += '--muleVersion4OrAbove' }
    }
    $args += @('--apiInstanceLabel', "$($inst.instanceLabel)")

    $res = Invoke-AnypointCli -ArgumentList $args -AsJson
    Set-ApimApiContext $res
    $id = Get-FirstValue $res @('id', 'apiId', 'instanceId')
    if (-not $id) { throw "api-mgr api manage did not return a recognizable instance id. Raw response: $($res | ConvertTo-Json -Depth 10 -Compress)" }
    return "$id"
}

function Invoke-ApimPromotion {
    param(
        [Parameter(Mandatory)][string]$TargetEnvName,
        [Parameter(Mandatory)][string]$SourceInstanceId,
        [Parameter(Mandatory)][string]$SourceEnvId,
        [Parameter(Mandatory)]$Config
    )
    $p = $Config.Promotion
    $b = { param($v) if ($v) { 'true' } else { 'false' } }
    $args = @('api-mgr', 'api', 'promote', $SourceInstanceId, $SourceEnvId,
        '--environment', $TargetEnvName,
        '--copyPolicies', (& $b (Get-DictValue $p 'copyPolicies')),
        '--copyTiers', (& $b (Get-DictValue $p 'copyTiers')),
        '--copyAlerts', (& $b (Get-DictValue $p 'copyAlerts')),
        '--output', 'json')
    Invoke-AnypointCli -ArgumentList $args -AsJson | Out-Null
    # `api promote`'s JSON response carries no instance id at all - just a human-readable
    # confirmation message naming the SOURCE instance id (e.g. `API with ID "210040"
    # promoted from "..." to "Bat"`). The promoted instance in $TargetEnvName gets its own,
    # different id that this response never reports, so look it up by label afterward - the
    # same way every other instance lookup in this module already works - instead of trying
    # to parse an id field that doesn't exist. Anypoint also doesn't keep the source's
    # instanceLabel verbatim on the new instance - it appends " (promoted)" - so look under
    # that mangled form too, and rename back to the clean label when found there.
    $targetLabel = "$($Config.ApiInstance.instanceLabel)"
    $id = Resolve-ApimPromotedInstanceId -EnvName $TargetEnvName -Label $targetLabel
    if (-not $id) { throw "Promoted into '$TargetEnvName' but could not find an instance labeled '$targetLabel' or '$targetLabel (promoted)' there afterwards." }
    return "$id"
}

# --------------------------------------------------------------------------- #
# Anypoint Platform REST (used for the policy read - returns structured
# configurationData, unlike `anypoint-cli policy list`'s stringified table).
# --------------------------------------------------------------------------- #
function Get-ApimBaseUri {
    $apiHost = if ($env:ANYPOINT_HOST) { "$($env:ANYPOINT_HOST)".Trim() } else { 'anypoint.mulesoft.com' }
    $apiHost = ($apiHost -replace '^https?://', '') -replace '/+$', ''
    return "https://$apiHost"
}

function Get-ApimAccessToken {
    <# client_credentials grant using the connected-app creds the CLI already uses. Cached. #>
    if ($script:ApimToken -and ($script:ApimToken.Expires -gt (Get-Date).AddSeconds(60))) {
        return $script:ApimToken.Value
    }
    $cid = "$($env:ANYPOINT_CLIENT_ID)"; $sec = "$($env:ANYPOINT_CLIENT_SECRET)"
    if (-not $cid -or -not $sec) {
        throw "ANYPOINT_CLIENT_ID / ANYPOINT_CLIENT_SECRET are required for the REST policy read (or set APIM_POLICY_READ=cli)"
    }
    $uri = "$(Get-ApimBaseUri)/accounts/api/v2/oauth2/token"
    Write-Host "[anypoint-rest] POST $uri (client_credentials)"
    $resp = Invoke-RestMethod -Method Post -Uri $uri -ErrorAction Stop `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'client_credentials'; client_id = $cid; client_secret = $sec }
    if (-not $resp.access_token) { throw "token endpoint returned no access_token" }
    $ttl = if ($resp.PSObject.Properties['expires_in'] -and $resp.expires_in) { [int]$resp.expires_in } else { 3600 }
    $script:ApimToken = @{ Value = "$($resp.access_token)"; Expires = (Get-Date).AddSeconds($ttl) }
    Write-Host "[anypoint-rest] token acquired (expires in ${ttl}s)"
    return $script:ApimToken.Value
}

function Invoke-ApimRest {
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Uri, [hashtable]$Headers)
    Write-Host "[anypoint-rest] $Method $Uri"
    try {
        $resp = Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -ErrorAction Stop
    }
    catch {
        Write-Host "[anypoint-rest] ERROR $($_.Exception.Message)"
        throw
    }
    if ($null -ne $resp) { Write-Host "[anypoint-rest] response:`n$($resp | ConvertTo-Json -Depth 15)" }
    return $resp
}

function Get-ApimOrgId {
    if ($script:ApimOrgId) { return $script:ApimOrgId }
    $org = "$($env:ANYPOINT_ORG)"
    if ($org -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        Write-Host "[org] ANYPOINT_ORG is a GUID - using it directly: $org"
        $script:ApimOrgId = $org; return $org
    }
    foreach ($c in $script:ApimApiContext.Values) {
        if ($c.OrgId) {
            Write-Host "[org] resolved from a prior 'api list' response: $($c.OrgId)"
            $script:ApimOrgId = $c.OrgId; return $c.OrgId
        }
    }
    throw "Cannot resolve the organization id for the REST call - ANYPOINT_ORG is '$org' (not a GUID) and no prior api lookup has org context. Set ANYPOINT_ORG to the business group id (GUID), or set APIM_POLICY_READ=cli"
}

# --------------------------------------------------------------------------- #
# NZ Government API Standard spec validation (Exchange fetch + Spectral lint)
# --------------------------------------------------------------------------- #
function Get-ApimExchangeAssetSpec {
    <# Download the primary spec file (OAS/RAML/WSDL) for an Exchange asset so it can be
       linted. Exchange asset identity (groupId/assetId/assetVersion) is the same triple
       apiInstance already carries - this is NOT the Anypoint Platform API Manager API,
       it's the separate Exchange REST API. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter(Mandatory)][string]$AssetId,
        [Parameter(Mandatory)][string]$AssetVersion,
        [Parameter(Mandatory)][string]$OutFile
    )
    $uri = "$(Get-ApimBaseUri)/exchange/api/v2/assets/$GroupId/$AssetId/$AssetVersion"
    $asset = Invoke-ApimRest -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $(Get-ApimAccessToken)" }
    $files = @($asset.files)
    if (-not $files) { throw "Exchange asset $GroupId/$AssetId/$AssetVersion has no files to validate" }

    # Prefer an API-spec classifier over other asset files (icons, examples, ...).
    $file = $null
    foreach ($classifier in @('fat-oas', 'oas', 'fat-raml', 'raml', 'wsdl')) {
        $file = $files | Where-Object { "$($_.classifier)" -eq $classifier } | Select-Object -First 1
        if ($file) { break }
    }
    if (-not $file) { $file = $files[0] }
    if (-not $file.downloadURL) { throw "Exchange asset $GroupId/$AssetId/${AssetVersion}: spec file has no downloadURL" }

    Write-Host "[spec] downloading '$($file.classifier)' spec for $AssetId@$AssetVersion"
    # The asset-metadata GET above needs a bearer token; the file itself is behind the same
    # auth unless the asset is flagged fully public in Exchange - send it here too, or a
    # non-public asset's download comes back 401 even though the metadata call succeeded.
    Invoke-WebRequest -Uri "$($file.downloadURL)" -OutFile $OutFile -UseBasicParsing `
        -Headers @{ Authorization = "Bearer $(Get-ApimAccessToken)" } | Out-Null
    return [pscustomobject]@{ Path = $OutFile; Classifier = "$($file.classifier)" }
}

function Invoke-ApimSpecLint {
    <# Run `spectral lint` against a downloaded spec with a classification-tiered ruleset.
       A spec mismatch is advisory, not a pipeline failure: every finding (any severity) is
       logged and returned, never thrown on. Only a genuine tool failure - spectral producing
       no output at all (bad ruleset, missing CLI, crash) - throws, since that isn't a "the
       spec doesn't match the standard" situation the caller can just warn about. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SpecFile, [Parameter(Mandatory)][string]$RulesetFile)

    $exe = if ($env:SPECTRAL_CLI) { $env:SPECTRAL_CLI } else { 'spectral' }
    $outFile = [System.IO.Path]::GetTempFileName()
    try {
        Write-Host "[spec] $exe lint $SpecFile --ruleset $RulesetFile"
        & $exe lint $SpecFile --ruleset $RulesetFile --format json --output $outFile 2>&1 |
            ForEach-Object { Write-Host "[spec] $_" }
        $code = $LASTEXITCODE
        $json = if (Test-Path -LiteralPath $outFile) { "$(Get-Content -Raw -LiteralPath $outFile)".Trim() } else { '' }
    }
    finally { Remove-Item -LiteralPath $outFile -ErrorAction SilentlyContinue }

    if (-not $json) {
        throw "spectral produced no output against '$RulesetFile' (exit $code) - this looks like a tool or ruleset failure, not a spec finding; see [spec] lines above"
    }

    $results = @($json | ConvertFrom-Json)
    $sevNames = @('ERROR', 'WARN', 'INFO', 'HINT')
    foreach ($r in $results) {
        $sev = if ($null -ne $r.severity -and [int]$r.severity -lt $sevNames.Count) { $sevNames[[int]$r.severity] } else { '?' }
        $path = if ($r.path) { ($r.path -join '.') } else { '(root)' }
        Write-Host "[spec] $sev $($r.code) at $path : $($r.message)"
    }
    return $results
}

# Rule code -> NZ Standard category this scorecard groups findings into. A rule code not
# listed here (e.g. a future rule nobody updated this map for) falls into "Other" rather
# than being silently dropped from the report - see ConvertTo-ApimSpecReportHtml below.
$script:ApimSpecReportCategories = @(
    @{ Name = 'Authentication'; Var = 'auth'
       Rules = @('nz-security-scheme-required', 'nz-oauth2-scheme-required')
       Icon = '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>' }
    @{ Name = 'Resource design'; Var = 'res'
       Rules = @('nz-resource-path-lowercase', 'nz-resource-no-verbs-in-path')
       Icon = '<path d="M3 12h18M3 6h18M3 18h18"/>' }
    @{ Name = 'Data validation'; Var = 'data'
       Rules = @('nz-json-schema-required-for-response', 'nz-json-schema-required-for-request-body')
       Icon = '<path d="M9 12l2 2 4-4M12 3a9 9 0 1 0 9 9"/>' }
    @{ Name = 'HTTP requirements'; Var = 'http'
       Rules = @('nz-request-content-type-required', 'nz-response-content-type-required')
       Icon = '<path d="M4 17V7l8-4 8 4v10l-8 4-8-4z"/><path d="M4 7l8 4 8-4M12 11v10"/>' }
    @{ Name = 'Versioning'; Var = 'ver'
       Rules = @('nz-url-version-major-only')
       Icon = '<path d="M12 3v18M3 12h18"/>' }
)

function ConvertTo-ApimSpecReportHtml {
    <# Render Invoke-ApimSpecLint's results as a colour-coded scorecard: a severity donut
       + stat tiles, then one card per NZ Standard category (see $script:ApimSpecReportCategories),
       each carrying its own accent hue. Written to -ArtifactDir by the validate-spec action
       so the pipeline can publish it as a build artifact alongside the console [spec] lines.
       Pure string building, no template engine - consistent with the rest of this module. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Api,
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][string]$Classification,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LintResults
    )

    function HtmlEnc([string]$s) { [System.Net.WebUtility]::HtmlEncode($s) }

    $findings = @($LintResults | ForEach-Object {
        $sevNum = if ($null -ne $_.severity) { [int]$_.severity } else { 1 }
        [pscustomobject]@{
            Code     = "$($_.code)"
            Severity = if ($sevNum -eq 0) { 'err' } else { 'warn' }
            Path     = if ($_.path) { ($_.path -join '.') } else { '(root)' }
            Message  = "$($_.message)"
        }
    })
    $errCount = @($findings | Where-Object { $_.Severity -eq 'err' }).Count
    $warnCount = @($findings | Where-Object { $_.Severity -eq 'warn' }).Count
    $total = $findings.Count

    $circ = 2 * [Math]::PI * 50
    $warnLen = if ($total -gt 0) { [Math]::Round(($warnCount / $total) * $circ, 1) } else { 0 }
    $errLen = if ($total -gt 0) { [Math]::Round(($errCount / $total) * $circ, 1) } else { 0 }
    $errOffset = -$warnLen

    function New-ApimSpecReportRow($f) {
        "<tr><td><span class=`"sev $($f.Severity)`"></span></td><td style=`"display:block`">" +
        "<span class=`"rule`">$(HtmlEnc $f.Code)</span>" +
        "<span class=`"loc`">$(HtmlEnc $f.Path)</span>" +
        "<div style=`"margin-top:4px`">$(HtmlEnc $f.Message)</div></td></tr>"
    }

    $catCards = ''
    $usedCodes = @{}
    foreach ($cat in $script:ApimSpecReportCategories) {
        $catFindings = @($findings | Where-Object { $cat.Rules -contains $_.Code })
        foreach ($f in $catFindings) { $usedCodes["$($f.Code)"] = $true }
        if ($catFindings.Count -eq 0) { continue }
        $catErr = @($catFindings | Where-Object { $_.Severity -eq 'err' }).Count
        $badgeBg = if ($catErr -gt 0) { 'var(--err-soft)' } else { 'var(--warn-soft)' }
        $badgeFg = if ($catErr -gt 0) { 'var(--err)' } else { 'var(--warn)' }
        $rows = ($catFindings | ForEach-Object { New-ApimSpecReportRow $_ }) -join "`n"
        $catCards += @"
    <div class="cat">
      <div class="cat-top" style="background:var(--cat-$($cat.Var))"></div>
      <div class="cat-head">
        <div class="cat-icon" style="background:var(--cat-$($cat.Var)-soft)">
          <svg viewBox="0 0 24 24" fill="none" stroke="var(--cat-$($cat.Var))" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">$($cat.Icon)</svg>
        </div>
        <h3>$(HtmlEnc $cat.Name)</h3>
        <span class="count" style="background:$badgeBg;color:$badgeFg">$($catFindings.Count)</span>
      </div>
      <table>
$rows
      </table>
    </div>
"@
    }
    $other = @($findings | Where-Object { -not $usedCodes.ContainsKey($_.Code) })
    if ($other.Count -gt 0) {
        $catErr = @($other | Where-Object { $_.Severity -eq 'err' }).Count
        $badgeBg = if ($catErr -gt 0) { 'var(--err-soft)' } else { 'var(--warn-soft)' }
        $badgeFg = if ($catErr -gt 0) { 'var(--err)' } else { 'var(--warn)' }
        $rows = ($other | ForEach-Object { New-ApimSpecReportRow $_ }) -join "`n"
        $catCards += @"
    <div class="cat" style="grid-column:1 / -1">
      <div class="cat-top" style="background:var(--muted)"></div>
      <div class="cat-head">
        <div class="cat-icon" style="background:var(--line)">
          <svg viewBox="0 0 24 24" fill="none" stroke="var(--muted)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/></svg>
        </div>
        <h3>Other</h3>
        <span class="count" style="background:$badgeBg;color:$badgeFg">$($other.Count)</span>
      </div>
      <table>
$rows
      </table>
    </div>
"@
    }

    $legend = ($script:ApimSpecReportCategories | ForEach-Object {
        "<span><i style=`"background:var(--cat-$($_.Var))`"></i>$(HtmlEnc $_.Name)</span>"
    }) -join "`n    "

    $heroStats = if ($total -eq 0) {
        '<div class="stat s-ok" style="grid-column:1 / -1"><div class="num">All clear</div><div class="lbl">no findings against the standard</div></div>'
    }
    else {
        "<div class=`"stat s-err`"><div class=`"num`">$errCount</div><div class=`"lbl`">error&#8209;tier</div></div>" +
        "<div class=`"stat s-warn`"><div class=`"num`">$warnCount</div><div class=`"lbl`">warn&#8209;tier</div></div>" +
        '<div class="stat s-ok"><div class="num">0</div><div class="lbl">blocking the pipeline</div></div>'
    }

    $generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm \U\T\C')
    $title = "$(HtmlEnc $Api) spec compliance"

    @"
<meta name="claude:viewport-fit-sides" content="cover">
<title>$title</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500;600&display=swap">
<style>
:root{
  --ink:#171a21; --paper:#f4f5f3; --surface:#ffffff; --line:#e4e4df; --muted:#6b7280;
  --err:#e11d48; --err-soft:#ffe4e9; --warn:#d97706; --warn-soft:#fef1da;
  --cat-auth:#7c3aed; --cat-auth-soft:#efe6fd;
  --cat-res:#0d9488; --cat-res-soft:#d9f3ef;
  --cat-data:#ea580c; --cat-data-soft:#fde6d6;
  --cat-http:#db2777; --cat-http-soft:#fbe0ec;
  --cat-ver:#2563eb; --cat-ver-soft:#dde8fd;
  --font-display:'IBM Plex Sans',Arial,sans-serif; --font-mono:'IBM Plex Mono',ui-monospace,Menlo,monospace;
  color-scheme:light;
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    --ink:#eceef2; --paper:#13151b; --surface:#1a1d25; --line:#2a2d38; --muted:#9298a8;
    --err:#fb7185; --err-soft:#3a1a22; --warn:#f0b15c; --warn-soft:#3a2a12;
    --cat-auth:#b29bf7; --cat-auth-soft:#2a2246;
    --cat-res:#5fd0c2; --cat-res-soft:#133030;
    --cat-data:#ff9c5c; --cat-data-soft:#3a2415;
    --cat-http:#f488b9; --cat-http-soft:#3a1c2a;
    --cat-ver:#7aa6fb; --cat-ver-soft:#1b2a4a;
    color-scheme:dark;
  }
}
:root[data-theme="dark"]{
  --ink:#eceef2; --paper:#13151b; --surface:#1a1d25; --line:#2a2d38; --muted:#9298a8;
  --err:#fb7185; --err-soft:#3a1a22; --warn:#f0b15c; --warn-soft:#3a2a12;
  --cat-auth:#b29bf7; --cat-auth-soft:#2a2246;
  --cat-res:#5fd0c2; --cat-res-soft:#133030;
  --cat-data:#ff9c5c; --cat-data-soft:#3a2415;
  --cat-http:#f488b9; --cat-http-soft:#3a1c2a;
  --cat-ver:#7aa6fb; --cat-ver-soft:#1b2a4a;
  color-scheme:dark;
}
*{box-sizing:border-box}
body{background:var(--paper);color:var(--ink);font-family:var(--font-display);line-height:1.45;
  padding-left:max(16px,env(safe-area-inset-left,0px));padding-right:max(16px,env(safe-area-inset-right,0px));}
.wrap{max-width:1180px;margin:0 auto;padding-block:28px 72px}
.mono{font-family:var(--font-mono)}
h1{font-size:30px;font-weight:700;margin:0;text-wrap:balance}
.topline{display:flex;flex-wrap:wrap;gap:14px;align-items:baseline;justify-content:space-between;margin-bottom:4px}
.tags{display:flex;gap:8px;flex-wrap:wrap}
.tag{font-size:12px;font-weight:600;padding:4px 11px;border-radius:40px;background:var(--surface);
  border:1px solid var(--line);color:var(--muted);font-family:var(--font-mono)}
.sub{color:var(--muted);font-size:14px;margin:6px 0 28px}
.hero{display:grid;grid-template-columns:220px 1fr;gap:28px;margin-bottom:34px;align-items:center}
.donut-card{background:var(--surface);border:1px solid var(--line);border-radius:18px;padding:20px;
  display:flex;flex-direction:column;align-items:center;gap:6px;min-width:0}
.donut-card .total{font-size:34px;font-weight:700;font-variant-numeric:tabular-nums}
.donut-card .totlbl{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.05em}
.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;min-width:0}
.stat{border-radius:16px;padding:18px 20px;min-width:0;position:relative;overflow:hidden}
.stat .num{font-size:30px;font-weight:700;font-variant-numeric:tabular-nums}
.stat .lbl{font-size:13px;margin-top:2px;opacity:.85}
.stat.s-err{background:linear-gradient(145deg,var(--err-soft),var(--surface));color:var(--err)}
.stat.s-warn{background:linear-gradient(145deg,var(--warn-soft),var(--surface));color:var(--warn)}
.stat.s-ok{background:linear-gradient(145deg,var(--cat-res-soft),var(--surface));color:var(--cat-res)}
.stat .lbl{color:var(--ink);opacity:.65}
.legend{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:26px}
.legend span{display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:600;color:var(--muted)}
.legend i{width:9px;height:9px;border-radius:50%;display:inline-block}
.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:18px}
.cat{background:var(--surface);border:1px solid var(--line);border-radius:16px;overflow:hidden;min-width:0;
  box-shadow:0 1px 2px rgba(0,0,0,.04)}
.cat-top{height:5px}
.cat-head{display:flex;align-items:center;gap:12px;padding:16px 18px 12px}
.cat-icon{width:36px;height:36px;border-radius:10px;display:flex;align-items:center;justify-content:center;flex:none}
.cat-icon svg{width:19px;height:19px}
.cat-head h3{font-size:16px;font-weight:700;margin:0}
.cat-head .count{margin-left:auto;font-size:12px;font-weight:700;padding:3px 10px;border-radius:40px;font-family:var(--font-mono)}
.cat table{width:100%;border-collapse:collapse;font-size:13.5px}
.cat td{padding:9px 18px;border-top:1px solid var(--line);vertical-align:top}
.cat tr:first-child td{border-top:none}
.cat .rule{font-family:var(--font-mono);font-size:12.5px;display:block;margin-bottom:2px}
.cat .loc{color:var(--muted);font-size:12px}
.sev{display:inline-block;width:8px;height:8px;border-radius:50%;margin-top:5px}
.sev.err{background:var(--err)} .sev.warn{background:var(--warn)}
@media (max-width:760px){ .hero{grid-template-columns:1fr} .stats{grid-template-columns:repeat(3,1fr)} .grid{grid-template-columns:1fr} }
@media (max-width:460px){ .stats{grid-template-columns:1fr 1fr} }
</style>
<div class="wrap">
  <div class="topline">
    <h1>$title</h1>
    <div class="tags">
      <span class="tag">classification: $(HtmlEnc $Classification)</span>
      <span class="tag">env: $(HtmlEnc $Environment)</span>
      <span class="tag">advisory only</span>
    </div>
  </div>
  <p class="sub">validate-spec against the NZ Government API Standard &middot; generated $generated</p>
  <div class="hero">
    <div class="donut-card">
      <svg viewBox="0 0 120 120" width="120" height="120">
        <circle cx="60" cy="60" r="50" fill="none" stroke="var(--line)" stroke-width="14"/>
        <circle cx="60" cy="60" r="50" fill="none" stroke="var(--warn)" stroke-width="14"
          stroke-dasharray="$warnLen $([Math]::Round($circ,1))" stroke-dashoffset="0" transform="rotate(-90 60 60)" stroke-linecap="round"/>
        <circle cx="60" cy="60" r="50" fill="none" stroke="var(--err)" stroke-width="14"
          stroke-dasharray="$errLen $([Math]::Round($circ,1))" stroke-dashoffset="$errOffset" transform="rotate(-90 60 60)" stroke-linecap="round"/>
      </svg>
      <div class="total">$total</div>
      <div class="totlbl">total findings</div>
    </div>
    <div class="stats">
$heroStats
    </div>
  </div>
  <div class="legend">
    $legend
  </div>
  <div class="grid">
$catCards
  </div>
</div>
"@
}

function Get-ApimAppliedPolicyViaRest {
    param([Parameter(Mandatory)][string]$EnvName, [Parameter(Mandatory)][string]$InstanceId)
    $ctx = $script:ApimApiContext["$InstanceId"]
    $orgId = if ($ctx -and $ctx.OrgId) { $ctx.OrgId } else { Get-ApimOrgId }
    $envId = if ($ctx -and $ctx.EnvId) { $ctx.EnvId } else { Get-ApimEnvironmentId -EnvName $EnvName }
    $uri = "$(Get-ApimBaseUri)/apimanager/api/v1/organizations/$orgId/environments/$envId/apis/$InstanceId/policies"
    $resp = Invoke-ApimRest -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $(Get-ApimAccessToken)" }
    if ($null -eq $resp) { return , [object[]]@() }
    if ($resp -is [System.Array]) { return , [object[]]@($resp) }
    if ($resp.PSObject.Properties['policies']) { return , [object[]]@($resp.policies) }
    return , [object[]]@($resp)
}

function Get-ApimAppliedPolicy {
    param([Parameter(Mandatory)][string]$EnvName, [Parameter(Mandatory)][string]$InstanceId)

    if ("$($env:APIM_POLICY_READ)".ToLower() -ne 'cli') {
        try {
            $rest = Get-ApimAppliedPolicyViaRest -EnvName $EnvName -InstanceId $InstanceId
            return , [object[]]@($rest)
        }
        catch { Write-Warning "[anypoint-rest] policy read failed, falling back to anypoint-cli: $($_.Exception.Message)" }
    }
    $res = Invoke-AnypointCli -AsJson -ArgumentList @(
        'api-mgr', 'policy', 'list', $InstanceId, '--muleVersion4OrAbove',
        '--environment', $EnvName, '--output', 'json')
    if ($null -eq $res) { return , [object[]]@() }
    if ($res -is [System.Array]) { return , [object[]]@($res) }
    if ($res.PSObject.Properties['policies']) { return , [object[]]@($res.policies) }
    return , [object[]]@($res)
}

function New-ApimPolicyConfigFile {
    param($ConfigObject)
    # anypoint-cli requires the --configFile to have a .json extension.
    $file = Join-Path ([System.IO.Path]::GetTempPath()) ("apim-policy-{0}.json" -f [guid]::NewGuid().ToString('N'))
    $json = (ConvertTo-CanonicalObject $ConfigObject | ConvertTo-Json -Depth 40)
    if (-not $json) { $json = '{}' }
    Set-Content -LiteralPath $file -Value $json -Encoding utf8
    return $file
}

function Add-ApimPolicy {
    param([Parameter(Mandatory)][string]$EnvName, [Parameter(Mandatory)][string]$InstanceId, [Parameter(Mandatory)]$Policy)
    $cfgFile = New-ApimPolicyConfigFile $Policy.Config
    try {
        $args = @('api-mgr', 'policy', 'apply', $InstanceId, $Policy.AssetId,
            '--policyVersion', $Policy.Version, '--groupId', $Policy.GroupId,
            '--configFile', $cfgFile, '--environment', $EnvName, '--output', 'json')
        if ($Policy.PointcutJson -and $Policy.PointcutJson -ne 'null') {
            $args += @('--pointcut', $Policy.PointcutJson)
        }
        $res = Invoke-AnypointCli -ArgumentList $args -AsJson
    }
    finally { Remove-Item -LiteralPath $cfgFile -ErrorAction SilentlyContinue }

    $newId = if ($res -and $res.PSObject.Properties['policyId']) { "$($res.policyId)" }
             elseif ($res -and $res.PSObject.Properties['id']) { "$($res.id)" } else { $null }
    if ($Policy.Disabled -and $newId) {
        Set-ApimPolicyState -EnvName $EnvName -InstanceId $InstanceId -PolicyInstanceId $newId -Disabled $true
    }
}

function Set-ApimPolicy {
    param(
        [Parameter(Mandatory)][string]$EnvName,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$PolicyInstanceId,
        [Parameter(Mandatory)]$Policy,
        [string[]]$Changes = @('config')
    )
    $cfgFile = New-ApimPolicyConfigFile $Policy.Config
    try {
        $args = @('api-mgr', 'policy', 'edit', $InstanceId, $PolicyInstanceId,
            '--configFile', $cfgFile, '--environment', $EnvName, '--output', 'json')
        if ($Changes -contains 'pointcut') {
            $pc = if ($Policy.PointcutJson) { $Policy.PointcutJson } else { 'null' }
            $args += @('--pointcut', $pc)
        }
        Invoke-AnypointCli -ArgumentList $args -AsJson | Out-Null
    }
    finally { Remove-Item -LiteralPath $cfgFile -ErrorAction SilentlyContinue }
}

function Remove-ApimPolicy {
    param([Parameter(Mandatory)][string]$EnvName, [Parameter(Mandatory)][string]$InstanceId, [Parameter(Mandatory)][string]$PolicyInstanceId)
    Invoke-AnypointCli -AsJson -ArgumentList @(
        'api-mgr', 'policy', 'remove', $InstanceId, $PolicyInstanceId,
        '--environment', $EnvName, '--output', 'json') | Out-Null
}

function Set-ApimPolicyState {
    param(
        [Parameter(Mandatory)][string]$EnvName,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$PolicyInstanceId,
        [Parameter(Mandatory)][bool]$Disabled
    )
    $verb = if ($Disabled) { 'disable' } else { 'enable' }
    Invoke-AnypointCli -AsJson -ArgumentList @(
        'api-mgr', 'policy', $verb, $InstanceId, $PolicyInstanceId,
        '--environment', $EnvName, '--output', 'json') | Out-Null
}

# --------------------------------------------------------------------------- #
# Normalisation + diff
# --------------------------------------------------------------------------- #
function ConvertTo-ApimNormalizedPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Raw, [Parameter(Mandatory)][ValidateSet('Desired', 'Live')][string]$Kind)

    $d = ConvertTo-Dict $Raw
    if ($null -eq $d) { throw "Cannot normalise policy: not a mapping ($Raw)" }

    if ($Kind -eq 'Desired') {
        $groupId = Get-FirstValue $d @('groupId')
        if (-not $groupId) { $groupId = $script:MuleSoftGroupId }
        $assetId = Get-FirstValue $d @('assetId')
        $version = "$(Get-FirstValue $d @('version'))"
        $order = Get-DictValue $d 'order'
        $disabled = [bool](Get-DictValue $d 'disabled')
        $config = Get-DictValue $d 'configurationData'
        $pointcut = ConvertTo-ApimPointcutArray (Get-DictValue $d 'pointcutData')
        $pointcutKnown = $true
        $instanceId = $null
    }
    else {
        # `policy list` / `policy describe --output json` return a table-shaped record:
        #   "ID", "Template ID", "Asset ID", "Asset Version", "Status", "Configuration".
        # There is no groupId in that shape, so fall back to the MuleSoft standard-policy
        # groupId (same default the Desired side uses) to keep the match key stable.
        # REST puts identity under `template` (assetId / assetVersion). The CLI table shape
        # uses `Asset ID` / `Asset Version` at top level. Never treat `policyTemplateId` or
        # the top-level `version` (a revision number in the REST payload) as identity.
        $tmpl = ConvertTo-Dict (Get-DictValue $d 'template')
        $groupId = Get-FirstValue $tmpl @('groupId')
        if (-not $groupId) { $groupId = Get-FirstValue $d @('groupId') }
        if (-not $groupId) { $groupId = $script:MuleSoftGroupId }
        $assetId = Get-FirstValue $tmpl @('assetId')
        if (-not $assetId) { $assetId = Get-FirstValue $d @('assetId', 'Asset ID') }
        $version = Get-FirstValue $tmpl @('assetVersion', 'version')
        if (-not $version) { $version = Get-FirstValue $d @('assetVersion', 'Asset Version') }
        $version = "$version"
        $order = Get-DictValue $d 'order'
        $disVal = Get-DictValue $d 'disabled'
        if ($null -ne $disVal) {
            $disabled = [bool]$disVal
        }
        else {
            $status = Get-FirstValue $d @('Status', 'status')
            $disabled = ("$status".Trim() -eq 'Disabled')
        }
        $config = ConvertFrom-ApimConfigBlob (Get-FirstValue $d @('configurationData', 'configuration', 'Configuration'))
        $pointcut = ConvertTo-ApimPointcutArray (Get-FirstValue $d @('pointcutData', 'pointcut'))
        # The table-shaped `policy list` output carries no pointcut field at all; only
        # trust a null pointcut if the key was actually present in the record.
        $pointcutKnown = [bool]($d.Contains('pointcutData') -or $d.Contains('pointcut'))
        $instanceId = Get-FirstValue $d @('policyId', 'id', 'ID')
    }

    # Key starts equal to BaseKey (groupId:assetId) and is the identity Get-ApimPolicyPlan
    # matches Desired against Live with. Resolve-ApimPolicyKeys may extend Key with a
    # pointcut fingerprint afterwards, for an assetId that's deliberately applied more than
    # once (e.g. one jwt-validation instance per path/role) - BaseKey stays the plain form so
    # per-policy lookups like $script:PolicyConfigDiffIgnore (keyed by "groupId:assetId")
    # keep working no matter how Key ends up.
    $baseKey = ('{0}:{1}' -f $groupId, $assetId)
    [pscustomobject]@{
        Key          = $baseKey
        BaseKey      = $baseKey
        GroupId      = "$groupId"
        AssetId      = "$assetId"
        Version      = $version
        Order        = if ($null -ne $order) { [int]$order } else { $null }
        Disabled     = $disabled
        Config       = $config
        Pointcut     = $pointcut
        PointcutJson = (ConvertTo-ApimPointcutJson $pointcut)
        PointcutKnown = $pointcutKnown
        InstanceId   = if ($null -ne $instanceId) { "$instanceId" } else { $null }
    }
}

function ConvertFrom-ApimConfigBlob {
    <# `policy list` renders some configs as a newline record list ("key: value", where
       a value may be multi-line JSON) instead of an object. Parse it into a dict.
       This is NOT YAML: a leading '#' in a value (DataWeave "#[...]") is literal, not a
       comment. Non-strings and real JSON objects pass through unchanged. #>
    param($Config)
    if ($Config -isnot [string]) { return $Config }
    $t = $Config.Trim()
    if ($t -eq '') { return $Config }
    if ($t.StartsWith('{') -or $t.StartsWith('[')) {
        try { return (ConvertFrom-ApimJsonValue $t) } catch { return $Config }
    }

    # A record starts at a line like "<identifier>: ..."; other lines continue the
    # previous value (e.g. a pretty-printed JSON array spanning several lines).
    $records = [ordered]@{}
    $key = $null
    foreach ($line in ($t -split "`r?`n")) {
        if ($line -match '^([A-Za-z_][\w.\-]*)\s*:\s?(.*)$') {
            $key = $Matches[1]
            $records[$key] = $Matches[2]
        }
        elseif ($null -ne $key) {
            $records[$key] = "$($records[$key])`n$line"
        }
    }
    if ($records.Count -eq 0) { return $Config }

    $out = [ordered]@{}
    foreach ($k in $records.Keys) {
        $v = "$($records[$k])".Trim()
        if ($v.StartsWith('{') -or $v.StartsWith('[')) {
            try { $out[$k] = (ConvertFrom-ApimJsonValue $v); continue } catch { }
        }
        $out[$k] = $v
    }
    return $out
}

function ConvertFrom-ApimJsonValue {
    <# ConvertFrom-Json unwraps a single-element JSON array to a scalar; keep the array
       shape so "[ {one object} ]" stays comparable to a desired one-element list. #>
    param([string]$Json)
    $parsed = $Json | ConvertFrom-Json
    if (-not $Json.TrimStart().StartsWith('[')) { return $parsed }
    if ($null -eq $parsed) { return , [object[]]@() }
    return , [object[]]@($parsed)
}

function Remove-ApimIgnoredConfigKey {
    <# Drop ignored top-level keys (common + per-policy) for this policy, for diffing only. #>
    param($Config, [string]$PolicyKey)
    $ignore = @($script:PolicyConfigDiffIgnoreCommon) + @($script:PolicyConfigDiffIgnore[$PolicyKey])
    $d = ConvertTo-Dict $Config
    if ($null -eq $d) { return $Config }
    $out = [ordered]@{}
    foreach ($k in $d.Keys) { if ($ignore -notcontains "$k") { $out["$k"] = $d["$k"] } }
    return $out
}

function Resolve-ApimPolicyKeys {
    <# The same policy template can be deliberately applied more than once - e.g. one
       jwt-validation instance per path, each authorising a different set of roles via its
       own pointcutData. Key starts out as BaseKey (groupId:assetId) for every policy, which
       is fine as long as an assetId appears at most once on each side: it lets a pointcut
       change on a lone instance go through as an in-place "policy edit --pointcut" instead
       of a remove+add.
       It breaks down the moment an assetId appears more than once on either side though:
       Get-ApimPolicyPlan's liveByKey/desiredKeys dictionaries can only hold one entry per
       key, so every instance beyond the first silently disappears from tracking - which is
       exactly how a plan ends up trying to ADD a policy Anypoint already has an identical
       twin of ("the policy defines a pointcut already defined by a policy with the same
       characteristics").
       Fix: for any BaseKey that appears more than once in Desired OR more than once in
       Live, extend Key (on every policy sharing that BaseKey, both sides) with a canonical
       pointcut fingerprint, so each distinct pointcut is tracked as its own entity. A
       BaseKey that appears at most once on each side is left alone, so the common
       single-instance case is unaffected. #>
    param([object[]]$Desired = @(), [object[]]$Live = @())

    $multi = @{}
    foreach ($group in @($Desired, $Live)) {
        $seen = @{}
        foreach ($p in $group) {
            if ($seen.ContainsKey($p.Key)) { $multi[$p.Key] = $true } else { $seen[$p.Key] = $true }
        }
    }
    foreach ($p in (@($Desired) + @($Live))) {
        if ($multi.ContainsKey($p.Key)) { $p.Key = "$($p.Key)::$($p.PointcutJson)" }
    }
}

function Get-ApimPolicyPlan {
    [CmdletBinding()]
    param([object[]]$Desired = @(), [object[]]$Live = @(), [bool]$Prune = $true)

    $add = @(); $edit = @(); $remove = @(); $toggle = @(); $drift = @(); $orderWarn = @()
    $liveByKey = @{}
    foreach ($l in $Live) { $liveByKey[$l.Key] = $l }
    $desiredKeys = @{}

    foreach ($dp in $Desired) {
        $desiredKeys[$dp.Key] = $true
        $lp = if ($liveByKey.ContainsKey($dp.Key)) { $liveByKey[$dp.Key] } else { $null }
        if ($null -eq $lp) { $add += $dp; continue }

        if ($dp.Version -ne $lp.Version) {
            $remove += [pscustomobject]@{ Policy = $lp; Reason = "version $($lp.Version) -> $($dp.Version) (recreate)" }
            $add += $dp
            continue
        }
        $dCfg = Remove-ApimIgnoredConfigKey $dp.Config $dp.BaseKey
        $lCfg = Remove-ApimIgnoredConfigKey $lp.Config $lp.BaseKey
        $cfgEqual = Test-ApimConfigTreeEqual $dCfg $lCfg
        if ($lp.PointcutKnown) {
            $pcEqual = ($dp.PointcutJson -eq $lp.PointcutJson)
        }
        else {
            $pcEqual = $true   # `policy list` does not return the pointcut - cannot compare
            if ($dp.PointcutJson -ne 'null') {
                $orderWarn += "$($dp.AssetId): pointcutData is set in config but 'policy list' does not return it (cannot verify or reconcile the pointcut)"
            }
        }
        if (-not ($cfgEqual -and $pcEqual)) {
            $changes = @()
            if (-not $cfgEqual) {
                $changes += 'config'
                foreach ($d in (Get-ApimConfigTreeDiff $dCfg $lCfg 'configurationData')) {
                    Write-Host "  [diff] $($dp.AssetId) $d"
                }
            }
            if (-not $pcEqual) {
                $changes += 'pointcut'
                Write-Host "  [diff] $($dp.AssetId) pointcutData : config=$($dp.PointcutJson) live=$($lp.PointcutJson)"
            }
            $edit += [pscustomobject]@{ Desired = $dp; InstanceId = $lp.InstanceId; Changes = $changes }
        }
        if ($dp.Disabled -ne $lp.Disabled) {
            $toggle += [pscustomobject]@{ InstanceId = $lp.InstanceId; AssetId = $dp.AssetId; Disabled = $dp.Disabled }
        }
        if (($null -ne $dp.Order) -and ($null -ne $lp.Order) -and ($dp.Order -ne $lp.Order)) {
            $orderWarn += "$($dp.AssetId): config order $($dp.Order) != live order $($lp.Order) (CLI cannot reorder policies)"
        }
    }

    foreach ($l in $Live) {
        if ($desiredKeys.ContainsKey($l.Key)) { continue }
        if ($Prune) { $remove += [pscustomobject]@{ Policy = $l; Reason = 'not in config (prune)' } }
        else { $drift += "$($l.AssetId) ($($l.GroupId)) applied but absent from config; prune disabled" }
    }

    [pscustomobject]@{
        Add           = $add
        Edit          = $edit
        Remove        = $remove
        Toggle        = $toggle
        Drift         = $drift
        OrderWarnings = $orderWarn
        IsEmpty       = (($add.Count + $edit.Count + $remove.Count + $toggle.Count) -eq 0)
    }
}

function Write-ApimPlan {
    param([Parameter(Mandatory)]$Plan)
    if ($Plan.IsEmpty -and $Plan.Drift.Count -eq 0 -and $Plan.OrderWarnings.Count -eq 0) {
        Write-Host '  (no changes)'
        return
    }
    foreach ($r in $Plan.Remove) { Write-Host "  REMOVE $($r.Policy.AssetId)@$($r.Policy.Version) (id $($r.Policy.InstanceId); $($r.Reason))" }
    foreach ($a in $Plan.Add) { Write-Host "  ADD    $($a.AssetId)@$($a.Version) (order $($a.Order))" }
    foreach ($e in $Plan.Edit) { Write-Host "  EDIT   $($e.Desired.AssetId)@$($e.Desired.Version) (id $($e.InstanceId); $($e.Changes -join ', '))" }
    foreach ($t in $Plan.Toggle) { Write-Host "  $(if ($t.Disabled) {'DISABLE'} else {'ENABLE '}) $($t.AssetId) (id $($t.InstanceId))" }
    foreach ($d in $Plan.Drift) { Write-Host "  DRIFT  $d" }
    foreach ($w in $Plan.OrderWarnings) { Write-Host "  WARN   $w" }
}

# --------------------------------------------------------------------------- #
# Orchestration
# --------------------------------------------------------------------------- #
function Get-ApimCreateStrategy {
    param([string]$CreateMode, [string]$Environment, $Config)
    if ($CreateMode -eq 'scratch') { return 'scratch' }
    if ($CreateMode -eq 'promote') { return 'promote' }
    if (($Environment -eq (Get-ApimInitialEnv)) -or -not (Get-DictValue $Config.Promotion 'fromEnvironment')) {
        return 'scratch'
    }
    return 'promote'
}

function Get-ApimDefaultSourceLabel {
    param([string]$TargetLabel, [string]$SourceEnv)
    $prefix = $TargetLabel -replace '-[^-]+$', ''
    if ($prefix -and ($prefix -ne $TargetLabel)) { return "$prefix-$SourceEnv" }
    return $TargetLabel
}

function Assert-ApimConverged {
    param([string]$EnvName, [string]$InstanceId, $Config, [bool]$Prune)
    $liveRaw = Get-ApimAppliedPolicy -EnvName $EnvName -InstanceId $InstanceId
    $desired = @($Config.Policies | ForEach-Object { ConvertTo-ApimNormalizedPolicy -Raw $_ -Kind Desired })
    $live = @($liveRaw | ForEach-Object { ConvertTo-ApimNormalizedPolicy -Raw $_ -Kind Live })
    Resolve-ApimPolicyKeys -Desired $desired -Live $live
    $residual = Get-ApimPolicyPlan -Desired $desired -Live $live -Prune $Prune
    if (-not $residual.IsEmpty) {
        throw "Post-apply verification failed for '$($Config.ApiInstance.instanceLabel)'. Residual plan is not empty."
    }
}

function Invoke-ApimReconcile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Environment,
        [switch]$DryRun,
        [ValidateSet('auto', 'scratch', 'promote')][string]$CreateMode = 'auto',
        [Nullable[bool]]$PruneOverride = $null
    )
    $envName = Resolve-ApimEnvironmentName $Environment
    $label = "$($Config.ApiInstance.instanceLabel)"
    $prune = if ($null -ne $PruneOverride) { [bool]$PruneOverride } else { [bool]$Config.Prune }

    $result = [pscustomobject]@{
        Api = $Config.Key; Environment = $Environment; InstanceLabel = $label
        InstanceId = $null; Action = 'none'; Changed = $false; DryRun = [bool]$DryRun
        Plan = $null; Drift = @(); Messages = @()
    }

    $instanceId = Resolve-ApimPromotedInstanceId -EnvName $envName -Label $label

    if (-not $instanceId) {
        $how = Get-ApimCreateStrategy -CreateMode $CreateMode -Environment $Environment -Config $Config
        $recoveredExisting = $false
        if ($how -eq 'promote') {
            $srcLogical = "$(Get-DictValue $Config.Promotion 'fromEnvironment')"
            $srcName = Resolve-ApimEnvironmentName $srcLogical
            $srcLabel = Get-DictValue $Config.Promotion 'sourceInstanceLabel'
            if (-not $srcLabel) { $srcLabel = Get-ApimDefaultSourceLabel $label $srcLogical }
            $srcEnvId = Get-ApimEnvironmentId -EnvName $srcName
            $srcInstanceId = Get-ApimInstanceId -EnvName $srcName -InstanceLabel $srcLabel
            if (-not $srcInstanceId) { throw "Cannot promote '$label': source instance '$srcLabel' not found in '$srcLogical'." }
            $result.Action = 'promote'
            $result.Messages += "promote from $srcLogical/$srcLabel (instance $srcInstanceId, env $srcEnvId)"
            if (-not $DryRun) {
                try { $instanceId = Invoke-ApimPromotion -TargetEnvName $envName -SourceInstanceId $srcInstanceId -SourceEnvId $srcEnvId -Config $Config }
                catch {
                    # The check above (Get-ApimInstanceId) is supposed to catch an
                    # already-existing target instance and skip promote entirely - if it
                    # missed (e.g. a listing/filter quirk) and Anypoint itself now rejects
                    # the promote as a duplicate, recover by looking it up directly instead
                    # of failing on a condition that isn't actually a problem.
                    $instanceId = Resolve-ApimPromotedInstanceId -EnvName $envName -Label $label
                    if (-not $instanceId) { throw "PROMOTE failed for '$label' from '$srcLogical/$srcLabel' (source instance $srcInstanceId) into '$Environment': $($_.Exception.Message)" }
                    Write-Host "[promote] '$label' already existed in '$Environment' (missed by the earlier check) - found instance $instanceId; reconciling policies instead of promoting again."
                    $result.Action = 'none'
                    $recoveredExisting = $true
                }
            }
        }
        else {
            $result.Action = 'create-scratch'
            $result.Messages += "create instance '$label' from $($Config.ApiInstance.assetId):$($Config.ApiInstance.assetVersion)"
            if (-not $DryRun) {
                try { $instanceId = New-ApimInstance -EnvName $envName -Config $Config }
                catch {
                    $instanceId = Get-ApimInstanceId -EnvName $envName -InstanceLabel $label
                    if (-not $instanceId) { throw "CREATE failed for '$label' ($($Config.ApiInstance.assetId):$($Config.ApiInstance.assetVersion)) in '$Environment': $($_.Exception.Message)" }
                    Write-Host "[create] '$label' already existed in '$Environment' (missed by the earlier check) - found instance $instanceId; reconciling policies instead of creating again."
                    $result.Action = 'none'
                    $recoveredExisting = $true
                }
            }
        }
        if ($recoveredExisting) {
            $result.Messages += "instance exists (id $instanceId)"
            $liveRaw = Get-ApimAppliedPolicy -EnvName $envName -InstanceId $instanceId
        }
        else {
            $result.Changed = $true
            $liveRaw = if ($DryRun -or -not $instanceId) { @() } else { Get-ApimAppliedPolicy -EnvName $envName -InstanceId $instanceId }
        }
    }
    else {
        $result.Messages += "instance exists (id $instanceId)"
        $liveRaw = Get-ApimAppliedPolicy -EnvName $envName -InstanceId $instanceId
    }
    $result.InstanceId = $instanceId

    $desired = @($Config.Policies | ForEach-Object { ConvertTo-ApimNormalizedPolicy -Raw $_ -Kind Desired }) |
        Sort-Object { if ($null -ne $_.Order) { $_.Order } else { [int]::MaxValue } }
    $live = @($liveRaw | ForEach-Object { ConvertTo-ApimNormalizedPolicy -Raw $_ -Kind Live })
    Resolve-ApimPolicyKeys -Desired $desired -Live $live
    $plan = Get-ApimPolicyPlan -Desired @($desired) -Live @($live) -Prune $prune
    $result.Plan = $plan
    $result.Drift = $plan.Drift

    Write-Host "[$Environment/$($Config.Key)] $($result.Messages -join '; ')"
    Write-ApimPlan -Plan $plan

    if ($plan.IsEmpty) {
        if ($result.Action -eq 'none') { $result.Messages += 'no changes' }
        if (-not $DryRun -and (@('create-scratch', 'promote') -contains $result.Action)) {
            Assert-ApimConverged -EnvName $envName -InstanceId $instanceId -Config $Config -Prune $prune
        }
        return $result
    }
    if ($DryRun) { $result.Messages += 'dry run: no changes applied'; return $result }

    # Each step names the exact policy + operation on failure, then stops immediately -
    # $ErrorActionPreference = 'Stop' means the throw here propagates straight past the
    # remaining foreach iterations, out of Invoke-ApimReconcile, to Invoke-ApimSync.ps1's
    # catch block. No partial-apply continues past a failed operation.
    foreach ($rm in $plan.Remove) {
        try { Remove-ApimPolicy -EnvName $envName -InstanceId $instanceId -PolicyInstanceId $rm.Policy.InstanceId }
        catch { throw "REMOVE failed for $($rm.Policy.AssetId)@$($rm.Policy.Version) (policy id $($rm.Policy.InstanceId)) on instance $instanceId : $($_.Exception.Message)" }
    }
    foreach ($ad in $plan.Add) {
        try { Add-ApimPolicy -EnvName $envName -InstanceId $instanceId -Policy $ad }
        catch { throw "ADD failed for $($ad.AssetId)@$($ad.Version) on instance $instanceId : $($_.Exception.Message)" }
    }
    foreach ($ed in $plan.Edit) {
        try { Set-ApimPolicy -EnvName $envName -InstanceId $instanceId -PolicyInstanceId $ed.InstanceId -Policy $ed.Desired -Changes $ed.Changes }
        catch { throw "EDIT failed for $($ed.Desired.AssetId)@$($ed.Desired.Version) (policy id $($ed.InstanceId)) on instance $instanceId : $($_.Exception.Message)" }
    }
    foreach ($tg in $plan.Toggle) {
        try { Set-ApimPolicyState -EnvName $envName -InstanceId $instanceId -PolicyInstanceId $tg.InstanceId -Disabled $tg.Disabled }
        catch { throw "TOGGLE failed for $($tg.AssetId) (policy id $($tg.InstanceId)) on instance $instanceId : $($_.Exception.Message)" }
    }

    $result.Changed = $true
    if ($result.Action -eq 'none') { $result.Action = 'update' }
    Assert-ApimConverged -EnvName $envName -InstanceId $instanceId -Config $Config -Prune $prune
    $result.Messages += 'converged'
    return $result
}

# --------------------------------------------------------------------------- #
# Extract (reverse sync) + git
# --------------------------------------------------------------------------- #
function Export-ApimConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Environment)

    $envName = Resolve-ApimEnvironmentName $Environment
    $label = "$($Config.ApiInstance.instanceLabel)"
    $instanceId = Get-ApimInstanceId -EnvName $envName -InstanceLabel $label
    if (-not $instanceId) { throw "Cannot extract '$($Config.Key)': instance '$label' not found in '$Environment'." }
    Write-Host "[extract] $($Config.Key)/${Environment}: reading live policies for instance $instanceId"

    $liveRaw = Get-ApimAppliedPolicy -EnvName $envName -InstanceId $instanceId

    # Same disambiguation as reconcile: an assetId applied more than once (e.g. one
    # jwt-validation instance per path/role) needs its pointcut folded into the match key,
    # or every instance beyond the first collapses onto the same "existing" config entry -
    # which would restore the wrong prior textKey/masked value for whichever instance lost
    # the collision.
    $existingNormalized = @($Config.Policies | ForEach-Object { ConvertTo-ApimNormalizedPolicy -Raw $_ -Kind Desired })
    $liveNormalized = @($liveRaw | ForEach-Object { ConvertTo-ApimNormalizedPolicy -Raw $_ -Kind Live })
    Resolve-ApimPolicyKeys -Desired $existingNormalized -Live $liveNormalized

    $existingByKey = @{}
    for ($i = 0; $i -lt $existingNormalized.Count; $i++) { $existingByKey[$existingNormalized[$i].Key] = @($Config.Policies)[$i] }

    $warnings = @()
    $entries = @()
    foreach ($n in $liveNormalized) {
        $prior = if ($existingByKey.ContainsKey($n.Key)) { $existingByKey[$n.Key] } else { $null }
        $priorCfg = if ($prior) { Get-DictValue $prior 'configurationData' } else { $null }
        $restored = Restore-ApimMaskedValue (ConvertTo-CanonicalObject $n.Config) $priorCfg
        # Make the written configurationData match what `reconcile` expects:
        #  - drop keys the read injects but config never sets (assetId / assetVersion / ...)
        #  - keep apply-only keys the read never returns (jwt-validation textKey): take them
        #    from the existing config file, else write a placeholder to fix before applying
        $rd = ConvertTo-Dict $restored
        if ($null -ne $rd) {
            $pd = ConvertTo-Dict $priorCfg
            $kept = [ordered]@{}
            foreach ($k in $rd.Keys) {
                if ($script:PolicyConfigDiffIgnoreCommon -notcontains "$k") { $kept["$k"] = $rd["$k"] }
            }
            foreach ($ik in @($script:PolicyConfigDiffIgnore[$n.BaseKey] | Where-Object { $_ })) {
                if ($kept.Contains($ik)) { continue }
                if (($null -ne $pd) -and $pd.Contains($ik)) {
                    $kept[$ik] = $pd[$ik]
                }
                else {
                    $kept[$ik] = 'CHANGE_ME'
                    $warnings += "$($n.AssetId): '$ik' is required on apply but not returned by the API - wrote a placeholder, set it before applying."
                }
            }
            $restored = ConvertTo-CanonicalObject $kept
        }
        if ((ConvertTo-CanonicalJson $restored) -match '\*{3,}') {
            $warnings += "$($n.AssetId): a masked value has no prior in the config file - left as placeholder, edit before committing."
        }
        $entries += [ordered]@{
            assetId           = $n.AssetId
            groupId           = $n.GroupId
            version           = $n.Version
            order             = $n.Order
            disabled          = $n.Disabled
            pointcutData      = $n.Pointcut
            configurationData = $restored
        }
    }
    $entries = @($entries | Sort-Object `
        @{ Expression = { if ($null -ne $_.order) { [int]$_.order } else { [int]::MaxValue } } }, `
        @{ Expression = { $_.assetId } })

    $newRaw = [ordered]@{}
    foreach ($k in $Config.Raw.Keys) {
        if ("$k" -eq 'policies') { $newRaw['policies'] = $entries }
        else { $newRaw["$k"] = $Config.Raw[$k] }
    }
    if (-not $newRaw.Contains('policies')) { $newRaw['policies'] = $entries }

    $header = "# Managed by apim-sync. 'extract' overwrites the policies list from the live $Environment instance;`n" +
              "# other sections are preserved. Review before merging.`n"
    $changed = Write-ApimConfigFile -Path $Config.Path -Raw $newRaw -YamlHeader $header

    [pscustomobject]@{
        Api = $Config.Key; Path = $Config.Path; Changed = $changed
        PolicyCount = $entries.Count; Warnings = $warnings
    }
}

function Write-ApimConfigFile {
    <# Serialize $Raw to $Path in whatever format the path's extension implies (.json has
       no comments; .yaml/.yml gets $YamlHeader prepended), writing only if the content
       actually changed. Shared by extract and configVersion bumps so both stay consistent. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Raw, [string]$YamlHeader)

    if ([System.IO.Path]::GetExtension($Path) -eq '.json') {
        $text = ($Raw | ConvertTo-Json -Depth 40)
    }
    else {
        $text = "$YamlHeader$(ConvertTo-Yaml $Raw)"
    }
    $current = if (Test-Path -LiteralPath $Path) { Get-Content -Raw -LiteralPath $Path } else { '' }
    $changed = ($current -ne $text)
    if ($changed) { Set-Content -LiteralPath $Path -Value $text -Encoding utf8 }
    return $changed
}

function Step-ApimConfigVersion {
    <# Patch-bump a plain x.y.z semver: 1.0.0 -> 1.0.1. Major/minor are left for a human
       to bump deliberately in the config file - reconcile only ever advances patch. #>
    param([Parameter(Mandatory)][string]$Version)
    if ("$Version" -notmatch '^(\d+)\.(\d+)\.(\d+)$') { throw "configVersion '$Version' is not a plain semver x.y.z" }
    return "$($Matches[1]).$($Matches[2]).$([int]$Matches[3] + 1)"
}

function Set-ApimConfigVersion {
    <# Write a new configVersion into the config file, preserving every other section.
       Compares against the already-parsed current version, not a re-serialized text diff -
       Write-ApimConfigFile's own header comment would otherwise make every call look
       "changed" even when the version value is identical. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Version)
    if ("$($Config.ConfigVersion)" -eq $Version) {
        return [pscustomobject]@{ Path = $Config.Path; Version = $Version; Changed = $false }
    }
    $newRaw = [ordered]@{}
    foreach ($k in $Config.Raw.Keys) { $newRaw["$k"] = $Config.Raw[$k] }
    $newRaw['configVersion'] = $Version
    $header = "# apim-sync: configVersion bumped to $Version by a successful reconcile.`n"
    Write-ApimConfigFile -Path $Config.Path -Raw $newRaw -YamlHeader $header | Out-Null
    [pscustomobject]@{ Path = $Config.Path; Version = $Version; Changed = $true }
}

function Get-ApimConfigAtVersion {
    <# Walk $Path's git history (inside $RepoDir) for the commit whose configVersion equals
       $Version, and return that historical file content - does not touch the working tree.
       Used for rollback: "redeploy" restores this content, then reconciles it like any
       other config. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoDir, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Version)

    $fullRepo = (Resolve-Path -LiteralPath $RepoDir).Path.TrimEnd('\', '/')
    $fullPath = (Resolve-Path -LiteralPath $Path).Path
    if (-not $fullPath.StartsWith($fullRepo, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Path is not under $RepoDir"
    }
    $relPath = $fullPath.Substring($fullRepo.Length).TrimStart('\', '/') -replace '\\', '/'

    # Not "$(& git ...)" - that joins multi-line native output with a space (via $OFS),
    # collapsing every commit onto one bogus line. Let PowerShell's own line-array capture
    # through instead.
    $shas = @(@(& git -C $RepoDir log --format=%H -- $relPath) | Where-Object { $_ })
    if (-not $shas) { throw "No git history for $relPath under $RepoDir" }

    foreach ($sha in $shas) {
        $lines = & git -C $RepoDir show "${sha}:${relPath}" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $lines) { continue }
        $content = ($lines -join "`n")
        try { $raw = ConvertFrom-Yaml $content -Ordered } catch { continue }
        $v = Get-DictValue $raw 'configVersion'
        if ("$v" -eq $Version) { return [pscustomobject]@{ Commit = $sha; Content = $content } }
    }
    throw "No commit of $relPath has configVersion '$Version' (searched $($shas.Count) commit(s))"
}

function Invoke-ApimConfigCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)][string]$Message,
        [switch]$Push,
        [string]$Branch   # omit -> push back to whatever branch $RepoDir currently has checked out
    )
    & git -C $RepoDir add -- @Path
    & git -C $RepoDir diff --cached --quiet
    if ($LASTEXITCODE -eq 0) { Write-Host 'No config changes to commit.'; return $false }

    $name = if ($env:GIT_COMMITTER_NAME) { $env:GIT_COMMITTER_NAME } else { 'apim-sync bot' }
    $email = if ($env:GIT_COMMITTER_EMAIL) { $env:GIT_COMMITTER_EMAIL } else { 'apim-sync@noreply.local' }
    & git -C $RepoDir -c "user.name=$name" -c "user.email=$email" commit -m $Message
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
    Write-Host "Committed: $Message"

    if ($Push) {
        if (-not $Branch) {
            $Branch = "$(& git -C $RepoDir rev-parse --abbrev-ref HEAD)".Trim()
            if (-not $Branch -or $Branch -eq 'HEAD') {
                throw "Cannot push: no -Branch given and $RepoDir is in detached HEAD (nothing to derive it from)"
            }
            Write-Host "No -Branch given; pushing to the branch currently checked out: $Branch"
        }
        & git -C $RepoDir push origin "HEAD:refs/heads/$Branch"
        if ($LASTEXITCODE -ne 0) { throw 'git push failed' }
        Write-Host "Pushed to origin/$Branch"
    }
    return $true
}

Export-ModuleMember -Function @(
    'Read-ApimConfig', 'Get-ApimConfigList',
    'Invoke-ApimReconcile', 'Export-ApimConfig', 'Invoke-ApimConfigCommit',
    'Get-ApimPolicyPlan', 'Resolve-ApimPolicyKeys', 'ConvertTo-ApimNormalizedPolicy', 'Test-ApimConfigTreeEqual',
    'Get-ApimConfigTreeDiff', 'ConvertFrom-ApimConfigBlob',
    'Write-ApimPlan', 'Invoke-AnypointCli', 'Resolve-ApimEnvironmentName',
    'Get-ApimEnvironmentId', 'Get-ApimInstanceId', 'Resolve-ApimPromotedInstanceId', 'Get-ApimAppliedPolicy',
    'Get-ApimAppliedPolicyViaRest', 'Get-ApimBaseUri', 'Get-ApimAccessToken',
    'New-ApimInstance', 'Invoke-ApimPromotion', 'Get-ApimInitialEnv',
    'Write-ApimConfigFile', 'Step-ApimConfigVersion', 'Set-ApimConfigVersion',
    'Get-ApimConfigAtVersion', 'Get-ApimExchangeAssetSpec', 'Invoke-ApimSpecLint', 'ConvertTo-ApimSpecReportHtml'
)
