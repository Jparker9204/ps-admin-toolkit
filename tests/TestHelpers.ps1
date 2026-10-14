# Shared setup for all Pester files: import the module fresh and create AD stubs
# so Mock has a command to replace on machines without RSAT (e.g. Linux CI runners).
$script:RepoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $script:RepoRoot 'AdminToolkit/AdminToolkit.psd1') -Force
$env:ADMINTOOLKIT_LOG = Join-Path ([IO.Path]::GetTempPath()) 'AdminToolkit-pester.jsonl'

# Superset of the AD cmdlet parameters the module uses, so mocks can bind and filter on them.
$adStub = {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        $Identity, $Filter, $Properties, $SearchBase, $Members, $TargetPath, $Description,
        $NewPassword, [switch]$Reset, $ChangePasswordAtLogon, $Name, $GivenName, $Surname,
        $DisplayName, $SamAccountName, $UserPrincipalName, $Path, $AccountPassword, $Enabled,
        $Department, $Title, $Office, $EmployeeID
    )
    throw 'AD stub called without a mock'
}
$adStubs = 'Get-ADUser', 'New-ADUser', 'Set-ADUser', 'Add-ADGroupMember', 'Remove-ADGroupMember',
'Disable-ADAccount', 'Move-ADObject', 'Set-ADAccountPassword', 'Unlock-ADAccount'
foreach ($name in $adStubs) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Set-Item -Path "function:global:$name" -Value $adStub
    }
}
$script:Samples = Join-Path $script:RepoRoot 'samples'
