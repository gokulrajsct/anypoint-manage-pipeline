@{
    RootModule        = 'ApimSync.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b7e4c2a1-9d3f-4a6b-8c1e-2f5a7d9b0c34'
    Author            = 'Platform Engineering'
    Description       = 'Declarative Anypoint API Manager instance + policy reconciler (Anypoint CLI v4).'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Read-ApimConfig', 'Get-ApimConfigList',
        'Invoke-ApimReconcile', 'Export-ApimConfig', 'Invoke-ApimConfigCommit',
        'Get-ApimPolicyPlan', 'ConvertTo-ApimNormalizedPolicy', 'Test-ApimConfigTreeEqual',
        'Get-ApimConfigTreeDiff', 'ConvertFrom-ApimConfigBlob',
        'Write-ApimPlan', 'Invoke-AnypointCli', 'Resolve-ApimEnvironmentName',
        'Get-ApimEnvironmentId', 'Get-ApimInstanceId', 'Get-ApimAppliedPolicy',
        'Get-ApimAppliedPolicyViaRest', 'Get-ApimBaseUri', 'Get-ApimAccessToken',
        'New-ApimInstance', 'Invoke-ApimPromotion', 'Get-ApimInitialEnv'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('MuleSoft', 'Anypoint', 'API-Manager', 'CI-CD')
            ExternalModuleDependencies = @('powershell-yaml')
        }
    }
}
