#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\src\ApimSync\ApimSync.psd1'
    Import-Module $script:ModulePath -Force
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

Describe 'Read-ApimConfig' {

    It 'loads the sample test config' {
        $c = Read-ApimConfig -Path (Join-Path $RepoRoot 'config/test/orders-api.yaml')
        $c.Key                        | Should -Be 'orders-api'
        $c.ApiInstance.instanceLabel  | Should -Be 'orders-api-test'
        $c.ApiInstance.deploymentType | Should -Be 'cloudhub2'
        $c.Prune                      | Should -BeTrue
        $c.Policies.Count             | Should -Be 2
    }

    It 'loads every file when Api = all' {
        $list = @(Get-ApimConfigList -ConfigDir (Join-Path $RepoRoot 'config/prod') -Api all)
        $list.Count             | Should -Be 1
        $list[0].Policies.Count | Should -Be 3
    }

    It 'throws for an unknown api' {
        { Get-ApimConfigList -ConfigDir (Join-Path $RepoRoot 'config/test') -Api nope } |
            Should -Throw -ExpectedMessage '*No config file for api*'
    }

    It 'loads a JSON config file' {
        $p = Join-Path $TestDrive 'orders-api.json'
        @'
{
  "apiInstance": { "assetId": "orders-api", "assetVersion": "1.0.3", "instanceLabel": "orders-api-test", "deploymentType": "cloudhub2" },
  "prune": false,
  "policies": [
    { "assetId": "rate-limiting-sla", "version": "1.4.0", "configurationData": { "rateLimits": [ { "maximumRequests": 200 } ] } }
  ]
}
'@ | Set-Content -LiteralPath $p
        $c = Read-ApimConfig -Path $p
        $c.Key                       | Should -Be 'orders-api'
        $c.ApiInstance.instanceLabel | Should -Be 'orders-api-test'
        $c.Prune                     | Should -BeFalse
        $c.Policies.Count            | Should -Be 1
        $c.Policies[0].order         | Should -Be 1
    }

    It 'refuses when the same api is defined in two files' {
        $d = Join-Path $TestDrive 'dupes'
        New-Item -ItemType Directory -Path $d | Out-Null
        '{}' | Set-Content -LiteralPath (Join-Path $d 'orders-api.yaml')
        '{}' | Set-Content -LiteralPath (Join-Path $d 'orders-api.json')
        { Get-ApimConfigList -ConfigDir $d -Api all }        | Should -Throw -ExpectedMessage '*Ambiguous config*'
        { Get-ApimConfigList -ConfigDir $d -Api 'orders-api' } | Should -Throw -ExpectedMessage '*Multiple config files*'
    }

    It 'rejects an invalid deploymentType' {
        $p = Join-Path $TestDrive 'bad.yaml'
        @'
apiInstance:
  assetId: x
  assetVersion: "1.0.0"
  instanceLabel: x-dev
  deploymentType: NOPE
policies: []
'@ | Set-Content -LiteralPath $p
        { Read-ApimConfig -Path $p } | Should -Throw -ExpectedMessage '*deploymentType*'
    }

    It 'requires a policy version' {
        $p = Join-Path $TestDrive 'bad2.yaml'
        @'
apiInstance:
  assetId: x
  assetVersion: "1.0.0"
  instanceLabel: x-dev
policies:
  - assetId: rate-limiting
    configurationData: {}
'@ | Set-Content -LiteralPath $p
        { Read-ApimConfig -Path $p } | Should -Throw -ExpectedMessage '*policies*version*'
    }

    It 'defaults missing policy order to position' {
        $p = Join-Path $TestDrive 'ok.yaml'
        @'
apiInstance:
  assetId: x
  assetVersion: "1.0.0"
  instanceLabel: x-dev
policies:
  - assetId: a
    version: "1.0.0"
    configurationData: {}
  - assetId: b
    version: "1.0.0"
    configurationData: {}
'@ | Set-Content -LiteralPath $p
        $c = Read-ApimConfig -Path $p
        $c.Policies[0]['order'] | Should -Be 1
        $c.Policies[1]['order'] | Should -Be 2
    }
}

Describe 'Test-ApimConfigTreeEqual' {

    It 'treats equal trees as equal regardless of key order' {
        Test-ApimConfigTreeEqual @{ a = 1; b = @{ y = 2; x = 1 } } @{ b = @{ x = 1; y = 2 }; a = 1 } |
            Should -BeTrue
    }

    It 'ignores a masked live leaf' {
        Test-ApimConfigTreeEqual @{ user = 'real-secret'; keep = 1 } @{ user = '********'; keep = 1 } |
            Should -BeTrue
    }

    It 'still compares non-masked leaves' {
        Test-ApimConfigTreeEqual @{ user = 'real-secret'; keep = 1 } @{ user = '********'; keep = 2 } |
            Should -BeFalse
    }

    It 'compares numbers by value across string/number types' {
        Test-ApimConfigTreeEqual @{ n = 200 } @{ n = '200' } | Should -BeTrue
    }

    It 'compares booleans across bool/string types' {
        Test-ApimConfigTreeEqual @{ b = $false } @{ b = 'false' } | Should -BeTrue
        Test-ApimConfigTreeEqual @{ b = $false } @{ b = 'true' } | Should -BeFalse
    }

    It 'ignores keys present only on the live side (subset match)' {
        Test-ApimConfigTreeEqual @{ a = 1 } @{ a = 1; b = 2; c = @{ d = 3 } } | Should -BeTrue
    }

    It 'a key in config but absent from live is still a difference' {
        Test-ApimConfigTreeEqual @{ a = 1; b = 2 } @{ a = 1 } | Should -BeFalse
    }

    It 'a null config value against a live-absent key is a no-op' {
        Test-ApimConfigTreeEqual @{ a = 1; b = $null } @{ a = 1 } | Should -BeTrue
    }
}

Describe 'ConvertFrom-ApimConfigBlob' {

    It 'parses a newline "key: value" blob into a dict' {
        $r = ConvertFrom-ApimConfigBlob "credentialsOrigin:customExpression`nclientIdExpression:#[attributes.headers['client_id']]"
        $r['credentialsOrigin'] | Should -Be 'customExpression'
        $r['clientIdExpression'] | Should -Be "#[attributes.headers['client_id']]"
    }

    It 'splits only on the first colon so expression values survive' {
        $r = ConvertFrom-ApimConfigBlob 'x: #[now() as String {format: "yyyy"}]'
        $r['x'] | Should -Be '#[now() as String {format: "yyyy"}]'
    }

    It 'keeps DataWeave "#[...]" values literal (not a YAML comment)' {
        $blob = "clientIdExpression: #[attributes.headers['client_id']]`n" +
                "clientSecretExpression: #[attributes.headers['client_secret']]`n" +
                "credentialsOriginHasHttpBasicAuthenticationHeader: customExpression"
        $r = ConvertFrom-ApimConfigBlob $blob
        $r['clientIdExpression'] | Should -Be "#[attributes.headers['client_id']]"
        $r['clientSecretExpression'] | Should -Be "#[attributes.headers['client_secret']]"
        $r['credentialsOriginHasHttpBasicAuthenticationHeader'] | Should -Be 'customExpression'
    }

    It 'reassembles a multi-line JSON value and keeps a one-element array an array' {
        $blob = "clusterizable: true`nexposeHeaders: false`nrateLimits: [`n  {`n    ""maximumRequests"": 100,`n    ""timePeriodInMilliseconds"": 60000`n  }`n]"
        $r = ConvertFrom-ApimConfigBlob $blob
        $r['clusterizable'] | Should -Be 'true'
        ,$r['rateLimits'] | Should -BeOfType [System.Object[]]   # not unwrapped to a bare object
        $r['rateLimits'].Count | Should -Be 1
        $r['rateLimits'][0].maximumRequests | Should -Be 100
    }

    It 'a one-element rateLimits list converges (regression: single-element array unwrap)' {
        $g = '68ef9520-24e9-4cf2-b2f5-620025690913'
        $blob = "clusterizable: true`nexposeHeaders: false`nrateLimits: [`n  {`n    ""maximumRequests"": 100,`n    ""timePeriodInMilliseconds"": 60000`n  }`n]"
        $desired = ConvertTo-ApimNormalizedPolicy -Kind Desired -Raw @{
            assetId = 'rate-limiting'; groupId = $g; version = '1.4.1'
            configurationData = @{ clusterizable = $true; exposeHeaders = $false
                rateLimits = @(@{ maximumRequests = 100; timePeriodInMilliseconds = 60000 }) }
        }
        $live = ConvertTo-ApimNormalizedPolicy -Kind Live -Raw ([ordered]@{
            'ID' = 9181953; 'Asset ID' = 'rate-limiting'; 'Asset Version' = '1.4.1'
            'Status' = 'Enabled'; 'Configuration' = $blob
        })
        (Get-ApimPolicyPlan -Desired @($desired) -Live @($live) -Prune $true).IsEmpty | Should -BeTrue
    }

    It 'passes structured input through unchanged' {
        $in = @{ a = 1 }
        ConvertFrom-ApimConfigBlob $in | Should -Be $in
    }

    It 'lets a blob-config live policy match a structured desired policy' {
        $g = '68ef9520-24e9-4cf2-b2f5-620025690913'
        $desired = ConvertTo-ApimNormalizedPolicy -Kind Desired -Raw @{
            assetId = 'client-id-enforcement'; groupId = $g; version = '1.3.2'
            configurationData = @{ credentialsOrigin = 'customExpression'; clientIdExpression = "#[a]" }
        }
        $live = ConvertTo-ApimNormalizedPolicy -Kind Live -Raw @{
            policyId = '5'; template = @{ assetId = 'client-id-enforcement'; groupId = $g; version = '1.3.2' }
            configuration = "credentialsOrigin:customExpression`nclientIdExpression:#[a]"
        }
        (Get-ApimPolicyPlan -Desired @($desired) -Live @($live) -Prune $true).IsEmpty | Should -BeTrue
    }
}

Describe 'ConvertTo-ApimNormalizedPolicy - table-shaped live (policy list / describe)' {

    # Fields/values as returned by `anypoint-cli-v4 api-mgr policy list --output json`.
    BeforeAll {
        $script:LiveRl = [ordered]@{
            'ID' = 9181953; 'Template ID' = '433839'; 'Asset ID' = 'rate-limiting'
            'Asset Version' = '1.4.1'; 'Label' = $null; 'Status' = 'Enabled'
            'Configuration' = "clusterizable: true`nexposeHeaders: false`nrateLimits: [`n  {`n    `"maximumRequests`": 100,`n    `"timePeriodInMilliseconds`": 60000`n  }`n]"
            'Updated' = '16 minutes ago'
        }
        $script:LiveCie = [ordered]@{
            'ID' = 9181954; 'Template ID' = '433807'; 'Asset ID' = 'client-id-enforcement'
            'Asset Version' = '1.3.3'; 'Label' = $null; 'Status' = 'Enabled'
            'Configuration' = "clientIdExpression: #[attributes.headers['client_id']]`nclientSecretExpression: #[attributes.headers['client_secret']]`ncredentialsOriginHasHttpBasicAuthenticationHeader: customExpression"
            'Updated' = '16 minutes ago'
        }
    }

    It 'maps ID / Asset ID / Asset Version / Status and defaults the groupId' {
        $g = '68ef9520-24e9-4cf2-b2f5-620025690913'
        $cie = ConvertTo-ApimNormalizedPolicy -Raw $script:LiveCie -Kind Live
        $cie.InstanceId | Should -Be '9181954'
        $cie.Version    | Should -Be '1.3.3'
        $cie.Disabled   | Should -BeFalse
        $cie.Key        | Should -Be "${g}:client-id-enforcement"
    }

    It 'converges against matching desired config (no residual EDIT)' {
        $g = '68ef9520-24e9-4cf2-b2f5-620025690913'
        $desired = @(
            (ConvertTo-ApimNormalizedPolicy -Kind Desired -Raw @{
                assetId = 'rate-limiting'; groupId = $g; version = '1.4.1'
                configurationData = @{ clusterizable = $true; exposeHeaders = $false
                    rateLimits = @(@{ maximumRequests = 100; timePeriodInMilliseconds = 60000 }) }
            }),
            (ConvertTo-ApimNormalizedPolicy -Kind Desired -Raw @{
                assetId = 'client-id-enforcement'; groupId = $g; version = '1.3.3'
                configurationData = @{
                    clientIdExpression = "#[attributes.headers['client_id']]"
                    clientSecretExpression = "#[attributes.headers['client_secret']]"
                    credentialsOriginHasHttpBasicAuthenticationHeader = 'customExpression' }
            })
        )
        $live = @($script:LiveRl, $script:LiveCie | ForEach-Object { ConvertTo-ApimNormalizedPolicy -Raw $_ -Kind Live })
        (Get-ApimPolicyPlan -Desired $desired -Live $live -Prune $true).IsEmpty | Should -BeTrue
    }

    It 'converges for jwt-validation (string bools/numbers, JSON array, write-only textKey)' {
        $g = '68ef9520-24e9-4cf2-b2f5-620025690913'
        $desired = ConvertTo-ApimNormalizedPolicy -Kind Desired -Raw @{
            assetId = 'jwt-validation'; groupId = $g; version = '1.4.0'
            configurationData = @{
                jwtKeyOrigin = 'jwks'; jwksUrl = 'https://login.example.com/oauth2/v1/keys'
                jwksServiceTimeToLive = 60; skipClientIdValidation = $true
                validateAudClaim = $true; supportedAudiences = 'api://orders-api'
                mandatoryExpirationClaim = $true; signingMethod = 'rsa'; signingKeyLength = '256'
                validateCustomClaim = $false
                mandatoryCustomClaims = @(@{ key = 'scope'; value = "#[vars.claimSet.scope]" })
                textKey = 'unused'   # required on apply, never returned by policy list
            }
        }
        $blob = "jwtKeyOrigin: jwks`n" +
                "jwksUrl: https://login.example.com/oauth2/v1/keys`n" +
                "jwksServiceTimeToLive: 60`n" +
                "skipClientIdValidation: true`n" +
                "validateAudClaim: true`n" +
                "supportedAudiences: api://orders-api`n" +
                "mandatoryExpirationClaim: true`n" +
                "signingMethod: rsa`n" +
                "signingKeyLength: 256`n" +
                "validateCustomClaim: false`n" +
                "mandatoryCustomClaims: [`n  {`n    ""key"": ""scope"",`n    ""value"": ""#[vars.claimSet.scope]""`n  }`n]"
        $live = ConvertTo-ApimNormalizedPolicy -Kind Live -Raw ([ordered]@{
            'ID' = 9181999; 'Asset ID' = 'jwt-validation'; 'Asset Version' = '1.4.0'
            'Status' = 'Enabled'; 'Configuration' = $blob
        })
        (Get-ApimPolicyPlan -Desired @($desired) -Live @($live) -Prune $true).IsEmpty | Should -BeTrue
    }

    It 'still flags a real jwt-validation config drift' {
        $g = '68ef9520-24e9-4cf2-b2f5-620025690913'
        $desired = ConvertTo-ApimNormalizedPolicy -Kind Desired -Raw @{
            assetId = 'jwt-validation'; groupId = $g; version = '1.4.0'
            configurationData = @{ jwksUrl = 'https://login.example.com/oauth2/v1/keys'; skipClientIdValidation = $true; textKey = 'unused' }
        }
        $live = ConvertTo-ApimNormalizedPolicy -Kind Live -Raw ([ordered]@{
            'ID' = 9181999; 'Asset ID' = 'jwt-validation'; 'Asset Version' = '1.4.0'; 'Status' = 'Enabled'
            'Configuration' = "jwksUrl: https://OTHER.example.com/keys`nskipClientIdValidation: true"
        })
        $plan = Get-ApimPolicyPlan -Desired @($desired) -Live @($live) -Prune $true
        $plan.Edit.Count | Should -Be 1
    }

    It 'does not loop on pointcutData the table output cannot report - warns instead' {
        $g = '68ef9520-24e9-4cf2-b2f5-620025690913'
        $desired = ConvertTo-ApimNormalizedPolicy -Kind Desired -Raw @{
            assetId = 'rate-limiting'; groupId = $g; version = '1.4.1'
            configurationData = @{ a = 1 }
            pointcutData = @(@{ methodRegex = 'GET'; uriTemplateRegex = '/orders/.*' })
        }
        $live = ConvertTo-ApimNormalizedPolicy -Kind Live -Raw ([ordered]@{
            'ID' = 1; 'Asset ID' = 'rate-limiting'; 'Asset Version' = '1.4.1'; 'Status' = 'Enabled'
            'Configuration' = 'a: 1'
        })
        $plan = Get-ApimPolicyPlan -Desired @($desired) -Live @($live) -Prune $true
        $plan.IsEmpty | Should -BeTrue
        ($plan.OrderWarnings -join ' ') | Should -Match 'pointcutData'
    }

    It 'still compares pointcutData when the live record carries it' {
        $g = '68ef9520-24e9-4cf2-b2f5-620025690913'
        $desired = ConvertTo-ApimNormalizedPolicy -Kind Desired -Raw @{
            assetId = 'rate-limiting'; groupId = $g; version = '1.4.1'
            configurationData = @{ a = 1 }; pointcutData = @(@{ methodRegex = 'GET' })
        }
        $live = ConvertTo-ApimNormalizedPolicy -Kind Live -Raw @{
            policyId = '1'; template = @{ assetId = 'rate-limiting'; groupId = $g; version = '1.4.1' }
            configurationData = @{ a = 1 }; pointcut = @(@{ methodRegex = 'POST' })
        }
        $plan = Get-ApimPolicyPlan -Desired @($desired) -Live @($live) -Prune $true
        $plan.Edit.Count | Should -Be 1
        $plan.Edit[0].Changes | Should -Contain 'pointcut'
    }

    It 'normalises a lone pointcut mapping to a JSON array (CLI requires an array)' {
        $g = '68ef9520-24e9-4cf2-b2f5-620025690913'
        $desired = ConvertTo-ApimNormalizedPolicy -Kind Desired -Raw @{
            assetId = 'jwt-validation'; groupId = $g; version = '1.4.0'
            configurationData = @{ jwksUrl = 'https://idp/keys' }
            pointcutData = @{ methodRegex = 'GET'; uriTemplateRegex = '/enrol/.*' }   # a bare mapping
        }
        $desired.PointcutJson | Should -Be '[{"methodRegex":"GET","uriTemplateRegex":"/enrol/.*"}]'
        # matches a live policy whose REST payload already has it as a one-element array
        $live = ConvertTo-ApimNormalizedPolicy -Kind Live -Raw ([pscustomobject]@{
            policyId = 9; template = [pscustomobject]@{ groupId = $g; assetId = 'jwt-validation'; assetVersion = '1.4.0' }
            configuration = [pscustomobject]@{ jwksUrl = 'https://idp/keys' }
            pointcutData = @([pscustomobject]@{ methodRegex = 'GET'; uriTemplateRegex = '/enrol/.*' })
        })
        (Get-ApimPolicyPlan -Desired @($desired) -Live @($live) -Prune $true).IsEmpty | Should -BeTrue
    }
}

Describe 'ConvertTo-ApimNormalizedPolicy - REST policy shape' {

    # A policy object exactly as the Anypoint REST policies endpoint returns it.
    It 'takes identity from template, not policyTemplateId / revision version' {
        $g = '68ef9520-24e9-4cf2-b2f5-620025690913'
        $rest = [pscustomobject]@{
            policyTemplateId = '433839'; order = 1; pointcutData = $null; type = 'system'
            policyId = 9181953; version = 1788921148318
            configuration = [pscustomobject]@{ clusterizable = $true; rateLimits = @([pscustomobject]@{ maximumRequests = 100 }) }
            template = [pscustomobject]@{ groupId = $g; assetId = 'rate-limiting'; assetVersion = '1.4.1' }
        }
        $n = ConvertTo-ApimNormalizedPolicy -Raw $rest -Kind Live
        $n.AssetId    | Should -Be 'rate-limiting'      # not '433839'
        $n.Version    | Should -Be '1.4.1'              # not '1788921148318'
        $n.Key        | Should -Be "${g}:rate-limiting"
        $n.InstanceId | Should -Be '9181953'
        $n.Config.rateLimits[0].maximumRequests | Should -Be 100
    }

    It 'converges a minimal desired config against the full live REST config (subset)' {
        $g = '68ef9520-24e9-4cf2-b2f5-620025690913'
        $desired = ConvertTo-ApimNormalizedPolicy -Kind Desired -Raw @{
            assetId = 'jwt-validation'; groupId = $g; version = '1.4.0'
            configurationData = @{ jwksUrl = 'https://idp/keys'; skipClientIdValidation = $true; textKey = 'unused' }
        }
        $live = ConvertTo-ApimNormalizedPolicy -Kind Live -Raw ([pscustomobject]@{
            policyId = 5; pointcutData = $null
            template = [pscustomobject]@{ groupId = $g; assetId = 'jwt-validation'; assetVersion = '1.4.0' }
            configuration = [pscustomobject]@{
                jwksUrl = 'https://idp/keys'; skipClientIdValidation = $true
                signingMethod = 'rsa'; signingKeyLength = '256'; jwksServiceTimeToLive = 60   # extra live-only keys
            }
        })
        (Get-ApimPolicyPlan -Desired @($desired) -Live @($live) -Prune $true).IsEmpty | Should -BeTrue
    }
}

Describe 'pointcutData normalisation' {
    BeforeAll { $script:g = '68ef9520-24e9-4cf2-b2f5-620025690913' }

    It 'a lone mapping becomes a one-element array' {
        $n = ConvertTo-ApimNormalizedPolicy -Kind Desired -Raw @{
            assetId = 'jwt-validation'; groupId = $g; version = '1.4.0'; configurationData = @{ a = 1 }
            pointcutData = @{ methodRegex = 'GET'; uriTemplateRegex = '/enrol/.*' }
        }
        $n.Pointcut.Count      | Should -Be 1
        $n.PointcutJson        | Should -Be '[{"methodRegex":"GET","uriTemplateRegex":"/enrol/.*"}]'
    }

    It 'multiple pointcut objects keep their order and shape' {
        $n = ConvertTo-ApimNormalizedPolicy -Kind Desired -Raw @{
            assetId = 'jwt-validation'; groupId = $g; version = '1.4.0'; configurationData = @{ a = 1 }
            pointcutData = @(
                @{ methodRegex = 'GET';  uriTemplateRegex = '/enrol/student/.*' }
                @{ methodRegex = 'POST'; uriTemplateRegex = '/enrol/admin/.*' }
            )
        }
        $n.Pointcut.Count | Should -Be 2
        $n.PointcutJson   | Should -Be '[{"methodRegex":"GET","uriTemplateRegex":"/enrol/student/.*"},{"methodRegex":"POST","uriTemplateRegex":"/enrol/admin/.*"}]'
    }

    It 'Add-ApimPolicy sends the multi-entry pointcut as a JSON array to the CLI' {
        InModuleScope ApimSync {
            $g = '68ef9520-24e9-4cf2-b2f5-620025690913'
            Mock Invoke-AnypointCli { [pscustomobject]@{ policyId = 1 } }
            $pol = ConvertTo-ApimNormalizedPolicy -Kind Desired -Raw @{
                assetId = 'jwt-validation'; groupId = $g; version = '1.4.0'; configurationData = @{ a = 1 }
                pointcutData = @(
                    @{ methodRegex = 'GET';  uriTemplateRegex = '/a/.*' }
                    @{ methodRegex = 'POST'; uriTemplateRegex = '/b/.*' }
                )
            }
            Add-ApimPolicy -EnvName 'Test' -InstanceId '777' -Policy $pol
            Should -Invoke Invoke-AnypointCli -ParameterFilter {
                $j = [array]::IndexOf([object[]]$ArgumentList, '--pointcut')
                ($j -ge 0) -and
                ($ArgumentList[$j + 1] -eq '[{"methodRegex":"GET","uriTemplateRegex":"/a/.*"},{"methodRegex":"POST","uriTemplateRegex":"/b/.*"}]')
            }
        }
    }

    It 'converges when desired and live carry the same multi-entry pointcut' {
        $desired = ConvertTo-ApimNormalizedPolicy -Kind Desired -Raw @{
            assetId = 'jwt-validation'; groupId = $g; version = '1.4.0'
            configurationData = @{ jwksUrl = 'https://idp/keys' }
            pointcutData = @(
                @{ methodRegex = 'GET';  uriTemplateRegex = '/a/.*' }
                @{ methodRegex = 'POST'; uriTemplateRegex = '/b/.*' }
            )
        }
        $live = ConvertTo-ApimNormalizedPolicy -Kind Live -Raw ([pscustomobject]@{
            policyId = 9; template = [pscustomobject]@{ groupId = $g; assetId = 'jwt-validation'; assetVersion = '1.4.0' }
            configuration = [pscustomobject]@{ jwksUrl = 'https://idp/keys' }
            pointcutData = @(
                [pscustomobject]@{ methodRegex = 'GET';  uriTemplateRegex = '/a/.*' }
                [pscustomobject]@{ methodRegex = 'POST'; uriTemplateRegex = '/b/.*' }
            )
        })
        (Get-ApimPolicyPlan -Desired @($desired) -Live @($live) -Prune $true).IsEmpty | Should -BeTrue
    }

    It 'flags a change when a pointcut entry differs' {
        $desired = ConvertTo-ApimNormalizedPolicy -Kind Desired -Raw @{
            assetId = 'jwt-validation'; groupId = $g; version = '1.4.0'
            configurationData = @{ jwksUrl = 'https://idp/keys' }
            pointcutData = @(
                @{ methodRegex = 'GET';    uriTemplateRegex = '/a/.*' }
                @{ methodRegex = 'DELETE'; uriTemplateRegex = '/b/.*' }
            )
        }
        $live = ConvertTo-ApimNormalizedPolicy -Kind Live -Raw ([pscustomobject]@{
            policyId = 9; template = [pscustomobject]@{ groupId = $g; assetId = 'jwt-validation'; assetVersion = '1.4.0' }
            configuration = [pscustomobject]@{ jwksUrl = 'https://idp/keys' }
            pointcutData = @(
                [pscustomobject]@{ methodRegex = 'GET';  uriTemplateRegex = '/a/.*' }
                [pscustomobject]@{ methodRegex = 'POST'; uriTemplateRegex = '/b/.*' }
            )
        })
        $plan = Get-ApimPolicyPlan -Desired @($desired) -Live @($live) -Prune $true
        $plan.Edit.Count      | Should -Be 1
        $plan.Edit[0].Changes | Should -Contain 'pointcut'
    }
}

Describe 'New-ApimPolicyConfigFile' {
    It 'writes a .json file the CLI will accept' {
        InModuleScope ApimSync {
            $f = New-ApimPolicyConfigFile @{ a = 1 }
            try {
                [System.IO.Path]::GetExtension($f) | Should -Be '.json'
                (Get-Content -Raw $f | ConvertFrom-Json).a | Should -Be 1
            }
            finally { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Get-ApimAppliedPolicy - REST read path' {

    BeforeEach {
        $env:APIM_POLICY_READ = $null
        Mock -ModuleName ApimSync Get-ApimAccessToken { 'tok-123' }
        Mock -ModuleName ApimSync Get-ApimOrgId { 'ORG-1' }
        Mock -ModuleName ApimSync Get-ApimEnvironmentId { 'ENV-1' }
        Mock -ModuleName ApimSync Invoke-AnypointCli { throw 'CLI should not be called' }
    }

    It 'reads policies from the REST endpoint (structured configurationData, no blob)' {
        Mock -ModuleName ApimSync Invoke-ApimRest {
            @(
                [pscustomobject]@{ id = 9181953
                    template = [pscustomobject]@{ groupId = '68ef9520-24e9-4cf2-b2f5-620025690913'; assetId = 'rate-limiting'; version = '1.4.1' }
                    configurationData = [pscustomobject]@{ clusterizable = $true; rateLimits = @([pscustomobject]@{ maximumRequests = 100 }) }
                    pointcutData = $null; order = 1; disabled = $false }
            )
        }
        $live = Get-ApimAppliedPolicy -EnvName 'Test' -InstanceId '9181953'
        $live.Count | Should -Be 1
        $n = ConvertTo-ApimNormalizedPolicy -Raw $live[0] -Kind Live
        $n.AssetId | Should -Be 'rate-limiting'
        $n.Config.rateLimits[0].maximumRequests | Should -Be 100   # real object, not a blob
        Should -Invoke -ModuleName ApimSync Invoke-ApimRest -Times 1
    }

    It 'builds the policies URL from org / env / api ids' {
        Mock -ModuleName ApimSync Invoke-ApimRest { @() }
        Get-ApimAppliedPolicy -EnvName 'Test' -InstanceId '777' | Out-Null
        Should -Invoke -ModuleName ApimSync Invoke-ApimRest -ParameterFilter {
            $Uri -eq 'https://anypoint.mulesoft.com/apimanager/api/v1/organizations/ORG-1/environments/ENV-1/apis/777/policies'
        }
    }

    It 'falls back to the CLI when the REST call fails' {
        Mock -ModuleName ApimSync Invoke-ApimRest { throw 'boom (401)' }
        Mock -ModuleName ApimSync Invoke-AnypointCli {
            @([pscustomobject]@{ ID = 1; 'Asset ID' = 'rate-limiting'; 'Asset Version' = '1.4.1'; 'Status' = 'Enabled'; 'Configuration' = 'clusterizable: true' })
        }
        $live = Get-ApimAppliedPolicy -EnvName 'Test' -InstanceId '1' 3>$null
        $live.Count | Should -Be 1
        Should -Invoke -ModuleName ApimSync Invoke-AnypointCli -Times 1
    }

    It 'APIM_POLICY_READ=cli skips REST entirely' {
        $env:APIM_POLICY_READ = 'cli'
        Mock -ModuleName ApimSync Invoke-ApimRest { throw 'REST must not be called' }
        Mock -ModuleName ApimSync Invoke-AnypointCli { @() }
        Get-ApimAppliedPolicy -EnvName 'Test' -InstanceId '1' | Out-Null
        Should -Invoke -ModuleName ApimSync Invoke-ApimRest -Times 0
        Should -Invoke -ModuleName ApimSync Invoke-AnypointCli -Times 1
        $env:APIM_POLICY_READ = $null
    }
}

Describe 'Get-ApimBaseUri' {
    AfterEach { $env:ANYPOINT_HOST = $null }

    It 'defaults to the US control plane' {
        $env:ANYPOINT_HOST = $null
        Get-ApimBaseUri | Should -Be 'https://anypoint.mulesoft.com'
    }
    It 'honours ANYPOINT_HOST and strips scheme / trailing slash' {
        $env:ANYPOINT_HOST = 'https://eu1.anypoint.mulesoft.com/'
        Get-ApimBaseUri | Should -Be 'https://eu1.anypoint.mulesoft.com'
    }
}

Describe 'Get-ApimPolicyPlan' {

    BeforeAll {
        function New-Desired ($asset, $ver, $cfg, $order = 1, $disabled = $false) {
            ConvertTo-ApimNormalizedPolicy -Kind Desired -Raw ([ordered]@{
                    assetId = $asset; version = $ver; groupId = 'G'; order = $order
                    disabled = $disabled; configurationData = $cfg
                })
        }
        function New-Live ($asset, $ver, $cfg, $order = 1, $disabled = $false, $instanceId = 100) {
            ConvertTo-ApimNormalizedPolicy -Kind Live -Raw ([ordered]@{
                    id = $instanceId; order = $order; disabled = $disabled
                    template = [ordered]@{ groupId = 'G'; assetId = $asset; version = $ver }
                    configurationData = $cfg
                })
        }
    }

    It 'identical -> empty plan' {
        $plan = Get-ApimPolicyPlan -Desired @(New-Desired 'rl' '1.0' @{ x = 1 }) `
            -Live @(New-Live 'rl' '1.0' @{ x = 1 }) -Prune $true
        $plan.IsEmpty | Should -BeTrue
    }

    It 'missing on API -> Add' {
        $plan = Get-ApimPolicyPlan -Desired @(New-Desired 'rl' '1.0' @{ x = 1 }) -Live @() -Prune $true
        $plan.Add.Count    | Should -Be 1
        $plan.Remove.Count | Should -Be 0
    }

    It 'config differs -> Edit carrying the live instance id' {
        $plan = Get-ApimPolicyPlan -Desired @(New-Desired 'rl' '1.0' @{ x = 2 }) `
            -Live @(New-Live 'rl' '1.0' @{ x = 1 }) -Prune $true
        $plan.Edit.Count          | Should -Be 1
        $plan.Edit[0].InstanceId  | Should -Be '100'
        $plan.Edit[0].Changes     | Should -Contain 'config'
    }

    It 'version change -> Remove + Add (remove ordered first)' {
        $plan = Get-ApimPolicyPlan -Desired @(New-Desired 'rl' '2.0' @{ x = 1 }) `
            -Live @(New-Live 'rl' '1.0' @{ x = 1 }) -Prune $true
        $plan.Remove.Count | Should -Be 1
        $plan.Add.Count    | Should -Be 1
        $plan.Edit.Count   | Should -Be 0
    }

    It 'disabled flag differs -> Toggle' {
        $plan = Get-ApimPolicyPlan -Desired @(New-Desired 'rl' '1.0' @{ x = 1 } 1 $true) `
            -Live @(New-Live 'rl' '1.0' @{ x = 1 } 1 $false) -Prune $true
        $plan.Toggle.Count       | Should -Be 1
        $plan.Toggle[0].Disabled | Should -BeTrue
    }

    It 'prune removes an extra live policy' {
        $plan = Get-ApimPolicyPlan `
            -Desired @(New-Desired 'rl' '1.0' @{ x = 1 }) `
            -Live @((New-Live 'rl' '1.0' @{ x = 1 }), (New-Live 'extra' '1.0' @{} 2 $false 200)) `
            -Prune $true
        $plan.Remove.Count            | Should -Be 1
        $plan.Remove[0].Policy.InstanceId | Should -Be '200'
        $plan.Drift.Count             | Should -Be 0
    }

    It 'no prune -> drift reported, nothing removed' {
        $plan = Get-ApimPolicyPlan `
            -Desired @(New-Desired 'rl' '1.0' @{ x = 1 }) `
            -Live @((New-Live 'rl' '1.0' @{ x = 1 }), (New-Live 'extra' '1.0' @{} 2 $false 200)) `
            -Prune $false
        $plan.Remove.Count | Should -Be 0
        $plan.Drift.Count  | Should -Be 1
        $plan.IsEmpty      | Should -BeTrue
    }

    It 'order mismatch is a warning, not an action' {
        $plan = Get-ApimPolicyPlan -Desired @(New-Desired 'rl' '1.0' @{ x = 1 } 3) `
            -Live @(New-Live 'rl' '1.0' @{ x = 1 } 1) -Prune $true
        $plan.IsEmpty            | Should -BeTrue
        $plan.OrderWarnings.Count | Should -Be 1
    }
}

Describe 'Invoke-ApimReconcile (dry run, CLI mocked)' {

    BeforeAll {
        $script:initialCfg = Read-ApimConfig -Path (Join-Path $RepoRoot 'config/test/orders-api.yaml')
        $script:higherCfg = Read-ApimConfig -Path (Join-Path $RepoRoot 'config/uat/orders-api.yaml')

        function Get-DevLivePolicies {
            @(
                [ordered]@{
                    id = 1; order = 1; disabled = $false; pointcutData = $null
                    template = [ordered]@{ groupId = '68ef9520-24e9-4cf2-b2f5-620025690913'; assetId = 'rate-limiting-sla'; version = '1.4.0' }
                    configurationData = [ordered]@{ clusterizable = $true; exposeHeaders = $true
                        rateLimits = @([ordered]@{ maximumRequests = 200; timePeriodInMilliseconds = 60000 })
                    }
                },
                [ordered]@{
                    id = 2; order = 2; disabled = $false; pointcutData = $null
                    template = [ordered]@{ groupId = '68ef9520-24e9-4cf2-b2f5-620025690913'; assetId = 'client-id-enforcement'; version = '1.3.2' }
                    configurationData = [ordered]@{ credentialsOrigin = 'customExpression'
                        clientIdExpression = "#[attributes.headers['client_id']]"
                        clientSecretExpression = "#[attributes.headers['client_secret']]"
                    }
                }
            )
        }
    }

    It 'existing instance, config already matches -> no changes' {
        Mock -ModuleName ApimSync Get-ApimInstanceId { '777' }
        Mock -ModuleName ApimSync Get-ApimAppliedPolicy { Get-DevLivePolicies }

        $r = Invoke-ApimReconcile -Config $initialCfg -Environment test -DryRun -CreateMode auto
        $r.Action        | Should -Be 'none'
        $r.Changed       | Should -BeFalse
        $r.Plan.IsEmpty  | Should -BeTrue
    }

    It 'existing instance with drift, dry run -> plan only, no writes' {
        Mock -ModuleName ApimSync Get-ApimInstanceId { '777' }
        Mock -ModuleName ApimSync Get-ApimAppliedPolicy {
            $p = Get-DevLivePolicies
            $p[0].configurationData.rateLimits[0].maximumRequests = 5
            $p
        }
        Mock -ModuleName ApimSync Set-ApimPolicy { throw 'must not write during dry run' }

        $r = Invoke-ApimReconcile -Config $initialCfg -Environment test -DryRun
        $r.Changed          | Should -BeFalse
        $r.Plan.Edit.Count  | Should -Be 1
        Should -Invoke -ModuleName ApimSync Set-ApimPolicy -Times 0
    }

    It 'missing instance in the initial env -> create-scratch plan, no CLI create' {
        Mock -ModuleName ApimSync Get-ApimInstanceId { $null }
        Mock -ModuleName ApimSync Get-ApimAppliedPolicy { @() }
        Mock -ModuleName ApimSync New-ApimInstance { throw 'must not create during dry run' }

        $r = Invoke-ApimReconcile -Config $initialCfg -Environment test -DryRun -CreateMode auto
        $r.Action        | Should -Be 'create-scratch'
        $r.Changed       | Should -BeTrue
        $r.Plan.Add.Count | Should -Be 2
        Should -Invoke -ModuleName ApimSync New-ApimInstance -Times 0
    }

    It 'missing instance in a higher env -> promote plan' {
        Mock -ModuleName ApimSync Get-ApimInstanceId {
            param($EnvName, $InstanceLabel)
            if ($InstanceLabel -eq 'orders-api-uat') { $null } else { '555' }
        }
        Mock -ModuleName ApimSync Get-ApimEnvironmentId { 'ENV-TEST-ID' }
        Mock -ModuleName ApimSync Get-ApimAppliedPolicy { @() }
        Mock -ModuleName ApimSync Invoke-ApimPromotion { throw 'must not promote during dry run' }

        $r = Invoke-ApimReconcile -Config $higherCfg -Environment uat -DryRun -CreateMode auto
        $r.Action  | Should -Be 'promote'
        $r.Changed | Should -BeTrue
        ($r.Messages -join ' ') | Should -BeLike '*555*'
        Should -Invoke -ModuleName ApimSync Invoke-ApimPromotion -Times 0
    }
}

Describe 'Export-ApimConfig (CLI mocked)' {

    It 'rewrites policies, preserves other sections, restores a masked secret' {
        $p = Join-Path $TestDrive 'orders-api.yaml'
        @'
apiInstance:
  assetId: orders-api
  assetVersion: "1.0.3"
  instanceLabel: orders-api-dev
  deploymentType: cloudhub2
promotion:
  fromEnvironment: null
prune: true
policies:
  - assetId: client-id-enforcement
    groupId: 68ef9520-24e9-4cf2-b2f5-620025690913
    version: "1.3.2"
    configurationData:
      clientSecret: super-secret
      credentialsOrigin: customExpression
'@ | Set-Content -LiteralPath $p
        $cfg = Read-ApimConfig -Path $p

        Mock -ModuleName ApimSync Get-ApimInstanceId { '777' }
        Mock -ModuleName ApimSync Get-ApimAppliedPolicy {
            @(
                [ordered]@{
                    id = 5; order = 2; pointcutData = $null
                    template = [ordered]@{ groupId = '68ef9520-24e9-4cf2-b2f5-620025690913'; assetId = 'client-id-enforcement'; version = '1.3.2' }
                    configurationData = [ordered]@{ clientSecret = '********'; credentialsOrigin = 'customExpression' }
                },
                [ordered]@{
                    id = 4; order = 1; pointcutData = $null
                    template = [ordered]@{ groupId = '68ef9520-24e9-4cf2-b2f5-620025690913'; assetId = 'rate-limiting-sla'; version = '1.4.0' }
                    configurationData = [ordered]@{ rateLimits = @([ordered]@{ maximumRequests = 300; timePeriodInMilliseconds = 60000 }) }
                }
            )
        }

        $r = Export-ApimConfig -Config $cfg -Environment dev
        $r.Changed     | Should -BeTrue
        $r.PolicyCount | Should -Be 2
        $r.Warnings.Count | Should -Be 0

        $out = ConvertFrom-Yaml (Get-Content -Raw -LiteralPath $p)
        $out.apiInstance.instanceLabel | Should -Be 'orders-api-dev'
        $out.prune                     | Should -BeTrue
        # sorted by order: rate-limiting first
        $out.policies[0].assetId       | Should -Be 'rate-limiting-sla'
        $out.policies[0].configurationData.rateLimits[0].maximumRequests | Should -Be 300
        # masked secret restored from the prior file content
        $out.policies[1].configurationData.clientSecret | Should -Be 'super-secret'
    }

    It 'reads the REST policy shape: configuration -> configurationData, identity from template, pointcut list' {
        $g = '68ef9520-24e9-4cf2-b2f5-620025690913'
        $p = Join-Path $TestDrive 'rest-shape.yaml'
        "apiInstance: {assetId: x, assetVersion: '1', instanceLabel: x-dev}`npolicies: []" | Set-Content -LiteralPath $p
        $cfg = Read-ApimConfig -Path $p

        Mock -ModuleName ApimSync Get-ApimInstanceId { '21075040' }
        Mock -ModuleName ApimSync Get-ApimAppliedPolicy {
            @(
                [pscustomobject]@{
                    policyTemplateId = '433839'; order = 1; type = 'system'; policyId = 9181953
                    version = 1788921148318                     # revision number, must NOT become the version
                    pointcutData = @([pscustomobject]@{ methodRegex = 'GET'; uriTemplateRegex = '/enrol/.*' })
                    configuration = [pscustomobject]@{ clusterizable = $true; rateLimits = @([pscustomobject]@{ maximumRequests = 100 }) }
                    template = [pscustomobject]@{ groupId = $g; assetId = 'rate-limiting'; assetVersion = '1.4.1' }
                }
            )
        }

        $r = Export-ApimConfig -Config $cfg -Environment dev
        $r.Changed | Should -BeTrue

        $out = ConvertFrom-Yaml (Get-Content -Raw -LiteralPath $p)
        $out.policies[0].assetId  | Should -Be 'rate-limiting'      # from template, not '433839'
        $out.policies[0].version  | Should -Be '1.4.1'              # from template, not the revision
        $out.policies[0].configurationData.rateLimits[0].maximumRequests | Should -Be 100   # 'configuration' written as 'configurationData'
        @($out.policies[0].pointcutData).Count | Should -Be 1
        $out.policies[0].pointcutData[0].methodRegex | Should -Be 'GET'
    }

    It 'jwt-validation extract: carries textKey from the existing file, injects a placeholder when absent' {
        $g = '68ef9520-24e9-4cf2-b2f5-620025690913'
        $p = Join-Path $TestDrive 'jwt.yaml'
        @"
apiInstance: {assetId: x, assetVersion: '1', instanceLabel: x-dev}
policies:
  - assetId: jwt-validation
    groupId: $g
    version: '1.4.0'
    configurationData:
      jwksUrl: https://idp/keys
      textKey: my-real-signing-key
"@ | Set-Content -LiteralPath $p
        $cfg = Read-ApimConfig -Path $p

        Mock -ModuleName ApimSync Get-ApimInstanceId { '99' }
        Mock -ModuleName ApimSync Get-ApimAppliedPolicy {
            @(
                [pscustomobject]@{ policyId = 1; order = 1; pointcutData = $null
                    template = [pscustomobject]@{ groupId = $g; assetId = 'jwt-validation'; assetVersion = '1.4.0' }
                    configuration = [pscustomobject]@{ jwksUrl = 'https://idp/keys'; signingMethod = 'rsa' } },   # no textKey
                [pscustomobject]@{ policyId = 2; order = 2; pointcutData = $null
                    template = [pscustomobject]@{ groupId = $g; assetId = 'jwt-validation-2'; assetVersion = '1.4.0' }
                    configuration = [pscustomobject]@{ jwksUrl = 'https://idp/keys2' } }                          # new policy, no prior
            )
        }

        # register the apply-only key for jwt-validation-2 too, for this test
        InModuleScope ApimSync { $script:PolicyConfigDiffIgnore["68ef9520-24e9-4cf2-b2f5-620025690913:jwt-validation-2"] = @('textKey') }
        try {
            $r = Export-ApimConfig -Config $cfg -Environment dev
            $out = ConvertFrom-Yaml (Get-Content -Raw -LiteralPath $p)
            $byId = @{}; foreach ($pol in $out.policies) { $byId[$pol.assetId] = $pol }
            $byId['jwt-validation'].configurationData.textKey   | Should -Be 'my-real-signing-key'   # carried from file
            $byId['jwt-validation-2'].configurationData.textKey | Should -Be 'CHANGE_ME'             # injected placeholder
            ($r.Warnings -join ' ') | Should -Match "textKey.*placeholder"
        }
        finally {
            InModuleScope ApimSync { $script:PolicyConfigDiffIgnore.Remove("68ef9520-24e9-4cf2-b2f5-620025690913:jwt-validation-2") }
        }
    }

    It 'drops read-artifact keys (assetId / assetVersion) from the written configurationData' {
        $g = '68ef9520-24e9-4cf2-b2f5-620025690913'
        $p = Join-Path $TestDrive 'artifacts.yaml'
        "apiInstance: {assetId: x, assetVersion: '1', instanceLabel: x-dev}`npolicies: []" | Set-Content -LiteralPath $p
        $cfg = Read-ApimConfig -Path $p

        Mock -ModuleName ApimSync Get-ApimInstanceId { '1' }
        Mock -ModuleName ApimSync Get-ApimAppliedPolicy {
            @([pscustomobject]@{ policyId = 1; order = 1; pointcutData = $null
                template = [pscustomobject]@{ groupId = $g; assetId = 'client-id-enforcement'; assetVersion = '1.3.3' }
                # CLI-fallback style: identity leaked into the config blob
                configuration = [pscustomobject]@{ assetId = 'client-id-enforcement'; assetVersion = '1.3.3'; credentialsOrigin = 'customExpression' } })
        }

        Export-ApimConfig -Config $cfg -Environment dev | Out-Null
        $out = ConvertFrom-Yaml (Get-Content -Raw -LiteralPath $p)
        $out.policies[0].configurationData.PSObject.Properties.Name | Should -Not -Contain 'assetId'
        $out.policies[0].configurationData.PSObject.Properties.Name | Should -Not -Contain 'assetVersion'
        $out.policies[0].configurationData.credentialsOrigin | Should -Be 'customExpression'
    }
}
