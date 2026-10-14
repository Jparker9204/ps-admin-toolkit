@{
    RootModule           = 'AdminToolkit.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '6f3b8f0e-2d1c-4c1a-9a0e-6b1a3f4d2c11'
    Author               = 'Jonathan Parker'
    Copyright            = '(c) 2026 Jonathan Parker. MIT License.'
    Description          = 'Help desk / sysadmin toolkit: AD onboarding & offboarding, stale account reports, password resets, system inventory, disk cleanup and service health checks. Every AD command has a -Simulate mode so it can be demoed without a domain.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'New-BulkADUser'
        'Remove-ADUserOffboard'
        'Reset-UserPassword'
        'Get-StaleAccounts'
        'Get-SystemInventory'
        'Invoke-DiskCleanup'
        'Test-ServiceHealth'
        'Write-AdminLog'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('ActiveDirectory', 'HelpDesk', 'SysAdmin', 'Inventory', 'Monitoring', 'Windows', 'Linux')
            LicenseUri = 'https://github.com/Jparker9204/ps-admin-toolkit/blob/main/LICENSE'
            ProjectUri = 'https://github.com/Jparker9204/ps-admin-toolkit'
        }
    }
}
