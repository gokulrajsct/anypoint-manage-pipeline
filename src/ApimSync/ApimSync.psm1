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

function Test-ApimConfigTreeEqual {
    <# True when Desired would be a no-op against Live. Masked Live leaves are ignored. #>
    param($Desired, $Live)

    if (Test-ApimMaskedValue $Live) { return $true }

    $dNull = ($null -eq $Desired); $lNull = ($null -eq $Live)
    if ($dNull -and $lNull) { return $true }
    if ($dNull -or $lNull) { return $false }

    $dDict = ConvertTo-Dict $Desired; $lDict = ConvertTo-Dict $Live
    if (($null -ne $dDict) -and ($null -ne $lDict)) {
        $dKeys = @($dDict.Keys | ForEach-Object { "$_" } | Sort-Object)
        $lKeys = @($lDict.Keys | ForEach-Object { "$_" } | Sort-Object)
        if (($dKeys -join '|') -ne ($lKeys -join '|')) { return $false }
        foreach ($k in $dKeys) {
            if (-not (Test-ApimConfigTreeEqual $dDict[$k] $lDict[$k])) { return $false }
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
        $dKeys = @($dDict.Keys | ForEach-Object { "$_" })
        $lKeys = @($lDict.Keys | ForEach-Object { "$_" })
        foreach ($k in ($dKeys | Where-Object { $lKeys -notcontains $_ })) {
            $diffs += "$Path/$k : only in config (=$(Format-ApimDiffValue $dDict[$k]))"
        }
        foreach ($k in ($lKeys | Where-Object { $dKeys -notcontains $_ })) {
            $diffs += "$Path/$k : only on live policy (=$(Format-ApimDiffValue $lDict[$k]))"
        }
        foreach ($k in ($dKeys | Where-Object { $lKeys -contains $_ })) {
            $diffs += Get-ApimConfigTreeDiff $dDict[$k] $lDict[$k] "$Path/$k"
        }
        return $diffs
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
    param([Parameter(Mandatory)][string]$Path)

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

    $policies = @()
    $rawPolicies = Get-DictValue $raw 'policies'
    if ($rawPolicies) { $policies = @($rawPolicies) }
    $idx = 0
    foreach ($p in $policies) {
        $idx++
        foreach ($req in @('assetId', 'version')) {
            if (-not (Get-DictValue $p $req)) { throw "${Path}: policies[$idx].$req is required" }
        }
        if (-not ($p -is [System.Collections.IDictionary]) -or -not $p.Contains('configurationData')) {
            throw "${Path}: policies[$idx].configurationData is required (use {} for none)"
        }
        if ($null -eq (Get-DictValue $p 'order')) { $p['order'] = $idx }
    }

    $promotion = Get-DictValue $raw 'promotion'
    if ($null -eq $promotion) { $promotion = [ordered]@{} }
    $prune = if ($raw.Contains('prune')) { [bool]$raw['prune'] } else { $true }

    [pscustomobject]@{
        Path        = (Resolve-Path -LiteralPath $Path).Path
        Key         = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        Raw         = $raw
        ApiInstance = $inst
        Promotion   = $promotion
        Prune       = $prune
        Policies    = $policies
    }
}

function Get-ApimConfigList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigDir, [string]$Api = 'all')

    if (-not (Test-Path -LiteralPath $ConfigDir)) { throw "Config directory not found: $ConfigDir" }
    $all = Get-ChildItem -LiteralPath $ConfigDir -File |
        Where-Object { @('.yaml', '.yml', '.json') -contains $_.Extension } | Sort-Object Name

    if ($Api -and $Api -ne 'all') {
        $match = @($all | Where-Object { $_.BaseName -eq $Api })
        if (-not $match) { throw "No config file for api '$Api' in $ConfigDir" }
        if ($match.Count -gt 1) { throw "Multiple config files for api '$Api' in ${ConfigDir}: $($match.Name -join ', ')" }
        return , (Read-ApimConfig -Path $match[0].FullName)
    }
    if (-not $all) { throw "No *.yaml / *.yml / *.json config files in $ConfigDir" }
    $dupe = $all | Group-Object BaseName | Where-Object Count -gt 1
    if ($dupe) { throw "Ambiguous config: $($dupe.Name -join ', ') defined in more than one file under $ConfigDir" }
    return , @($all | ForEach-Object { Read-ApimConfig -Path $_.FullName })
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
        if ($map.PSObject.Properties[$LogicalEnv]) { return $map.$LogicalEnv }
    }
    return $LogicalEnv
}

function Get-ApimEnvironmentId {
    param([Parameter(Mandatory)][string]$EnvName)
    $data = Invoke-AnypointCli -ArgumentList @('account', 'environment', 'list', '--output', 'json') -AsJson
    foreach ($e in @($data)) {
        if (($e.name -eq $EnvName) -or ($e.id -eq $EnvName)) { return "$($e.id)" }
    }
    throw "Environment '$EnvName' not found in this organization"
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
        if ($label -eq $InstanceLabel) { return "$($i.id)" }
    }
    return $null
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
    return "$($res.id)"
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
    $res = Invoke-AnypointCli -ArgumentList $args -AsJson
    return "$($res.id)"
}

function Get-ApimAppliedPolicy {
    param([Parameter(Mandatory)][string]$EnvName, [Parameter(Mandatory)][string]$InstanceId)
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
    $file = [System.IO.Path]::GetTempFileName()
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
        if ($Policy.Pointcut) {
            $args += @('--pointcut', (ConvertTo-Json $Policy.Pointcut -Depth 20 -Compress))
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
            $pc = if ($Policy.Pointcut) { ConvertTo-Json $Policy.Pointcut -Depth 20 -Compress } else { 'null' }
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
        $pointcut = Get-DictValue $d 'pointcutData'
        $pointcutKnown = $true
        $instanceId = $null
    }
    else {
        # `policy list` / `policy describe --output json` return a table-shaped record:
        #   "ID", "Template ID", "Asset ID", "Asset Version", "Status", "Configuration".
        # There is no groupId in that shape, so fall back to the MuleSoft standard-policy
        # groupId (same default the Desired side uses) to keep the match key stable.
        $tmpl = ConvertTo-Dict (Get-DictValue $d 'template')
        $groupId = Get-FirstValue $d @('groupId')
        if (-not $groupId) { $groupId = Get-FirstValue $tmpl @('groupId') }
        if (-not $groupId) { $groupId = $script:MuleSoftGroupId }
        $assetId = Get-FirstValue $d @('assetId', 'policyTemplateId', 'Asset ID')
        if (-not $assetId) { $assetId = Get-FirstValue $tmpl @('assetId') }
        $version = Get-FirstValue $d @('assetVersion', 'version', 'Asset Version')
        if (-not $version) { $version = Get-FirstValue $tmpl @('version') }
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
        $pointcut = Get-FirstValue $d @('pointcutData', 'pointcut')
        # The table-shaped `policy list` output carries no pointcut field at all; only
        # trust a null pointcut if the key was actually present in the record.
        $pointcutKnown = [bool]($d.Contains('pointcutData') -or $d.Contains('pointcut'))
        $instanceId = Get-FirstValue $d @('policyId', 'id', 'ID')
    }

    [pscustomobject]@{
        Key          = ('{0}:{1}' -f $groupId, $assetId)
        GroupId      = "$groupId"
        AssetId      = "$assetId"
        Version      = $version
        Order        = if ($null -ne $order) { [int]$order } else { $null }
        Disabled     = $disabled
        Config       = $config
        Pointcut     = $pointcut
        PointcutJson = (ConvertTo-CanonicalJson $pointcut)
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
        try { return ($t | ConvertFrom-Json) } catch { return $Config }
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
            try { $out[$k] = ($v | ConvertFrom-Json); continue } catch { }
        }
        $out[$k] = $v
    }
    return $out
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
        $dCfg = Remove-ApimIgnoredConfigKey $dp.Config $dp.Key
        $lCfg = Remove-ApimIgnoredConfigKey $lp.Config $lp.Key
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

    $instanceId = Get-ApimInstanceId -EnvName $envName -InstanceLabel $label

    if (-not $instanceId) {
        $how = Get-ApimCreateStrategy -CreateMode $CreateMode -Environment $Environment -Config $Config
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
                $instanceId = Invoke-ApimPromotion -TargetEnvName $envName -SourceInstanceId $srcInstanceId -SourceEnvId $srcEnvId -Config $Config
            }
        }
        else {
            $result.Action = 'create-scratch'
            $result.Messages += "create instance '$label' from $($Config.ApiInstance.assetId):$($Config.ApiInstance.assetVersion)"
            if (-not $DryRun) { $instanceId = New-ApimInstance -EnvName $envName -Config $Config }
        }
        $result.Changed = $true
        $liveRaw = if ($DryRun -or -not $instanceId) { @() } else { Get-ApimAppliedPolicy -EnvName $envName -InstanceId $instanceId }
    }
    else {
        $result.Messages += "instance exists (id $instanceId)"
        $liveRaw = Get-ApimAppliedPolicy -EnvName $envName -InstanceId $instanceId
    }
    $result.InstanceId = $instanceId

    $desired = @($Config.Policies | ForEach-Object { ConvertTo-ApimNormalizedPolicy -Raw $_ -Kind Desired }) |
        Sort-Object { if ($null -ne $_.Order) { $_.Order } else { [int]::MaxValue } }
    $live = @($liveRaw | ForEach-Object { ConvertTo-ApimNormalizedPolicy -Raw $_ -Kind Live })
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

    foreach ($rm in $plan.Remove) { Remove-ApimPolicy -EnvName $envName -InstanceId $instanceId -PolicyInstanceId $rm.Policy.InstanceId }
    foreach ($ad in $plan.Add) { Add-ApimPolicy -EnvName $envName -InstanceId $instanceId -Policy $ad }
    foreach ($ed in $plan.Edit) { Set-ApimPolicy -EnvName $envName -InstanceId $instanceId -PolicyInstanceId $ed.InstanceId -Policy $ed.Desired -Changes $ed.Changes }
    foreach ($tg in $plan.Toggle) { Set-ApimPolicyState -EnvName $envName -InstanceId $instanceId -PolicyInstanceId $tg.InstanceId -Disabled $tg.Disabled }

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

    $liveRaw = Get-ApimAppliedPolicy -EnvName $envName -InstanceId $instanceId

    $existingByKey = @{}
    foreach ($p in @($Config.Policies)) {
        $gid = Get-DictValue $p 'groupId'; if (-not $gid) { $gid = $script:MuleSoftGroupId }
        $existingByKey[('{0}:{1}' -f $gid, (Get-DictValue $p 'assetId'))] = $p
    }

    $warnings = @()
    $entries = @()
    foreach ($raw in $liveRaw) {
        $n = ConvertTo-ApimNormalizedPolicy -Raw $raw -Kind Live
        $prior = if ($existingByKey.ContainsKey($n.Key)) { $existingByKey[$n.Key] } else { $null }
        $priorCfg = if ($prior) { Get-DictValue $prior 'configurationData' } else { $null }
        $restored = Restore-ApimMaskedValue (ConvertTo-CanonicalObject $n.Config) $priorCfg
        # carry over apply-only keys (e.g. jwt-validation textKey) that `policy list` never returns
        $ignore = $script:PolicyConfigDiffIgnore[$n.Key]
        if ($ignore -and $priorCfg) {
            $rd = ConvertTo-Dict $restored; $pd = ConvertTo-Dict $priorCfg
            if (($null -ne $rd) -and ($null -ne $pd)) {
                foreach ($ik in $ignore) {
                    if (-not $rd.Contains($ik) -and $pd.Contains($ik)) { $rd["$ik"] = $pd["$ik"] }
                }
                $restored = ConvertTo-CanonicalObject $rd
            }
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

    if ([System.IO.Path]::GetExtension($Config.Path) -eq '.json') {
        $text = ($newRaw | ConvertTo-Json -Depth 40)   # JSON has no comments; emit the object only
    }
    else {
        $header = "# Managed by apim-sync. 'extract' overwrites the policies list from the live $Environment instance;`n" +
                  "# other sections are preserved. Review before merging.`n"
        $text = $header + (ConvertTo-Yaml $newRaw)
    }

    $current = if (Test-Path -LiteralPath $Config.Path) { Get-Content -Raw -LiteralPath $Config.Path } else { '' }
    $changed = ($current -ne $text)
    if ($changed) { Set-Content -LiteralPath $Config.Path -Value $text -Encoding utf8 }

    [pscustomobject]@{
        Api = $Config.Key; Path = $Config.Path; Changed = $changed
        PolicyCount = $entries.Count; Warnings = $warnings
    }
}

function Invoke-ApimConfigCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoDir,
        [Parameter(Mandatory)][string[]]$Path,
        [Parameter(Mandatory)][string]$Message,
        [switch]$Push,
        [string]$Branch = 'main'
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
        & git -C $RepoDir push origin "HEAD:refs/heads/$Branch"
        if ($LASTEXITCODE -ne 0) { throw 'git push failed' }
        Write-Host "Pushed to origin/$Branch"
    }
    return $true
}

Export-ModuleMember -Function @(
    'Read-ApimConfig', 'Get-ApimConfigList',
    'Invoke-ApimReconcile', 'Export-ApimConfig', 'Invoke-ApimConfigCommit',
    'Get-ApimPolicyPlan', 'ConvertTo-ApimNormalizedPolicy', 'Test-ApimConfigTreeEqual',
    'Get-ApimConfigTreeDiff', 'ConvertFrom-ApimConfigBlob',
    'Write-ApimPlan', 'Invoke-AnypointCli', 'Resolve-ApimEnvironmentName',
    'Get-ApimEnvironmentId', 'Get-ApimInstanceId', 'Get-ApimAppliedPolicy',
    'New-ApimInstance', 'Invoke-ApimPromotion', 'Get-ApimInitialEnv'
)
