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
}

Describe 'ConvertFrom-ApimConfigBlob' {

    It 'parses a newline "key: value" blob into a dict' {
        $r = ConvertFrom-ApimConfigBlob "credentialsOrigin:customExpression`nclientIdExpression:#[attributes.headers['client_id']]"
        $r['credentialsOrigin'] | Should -Be 'customExpression'
        $r['clientIdExpression'] | Should -Be "#[attributes.headers['client_id']]"
    }

    It 'splits only on the first colon so expression values survive' {
        $r = ConvertFrom-ApimConfigBlob 'x:#[now() as String {format: "yyyy"}]'
        $r['x'] | Should -Be '#[now() as String {format: "yyyy"}]'
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
}
