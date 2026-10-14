function Get-StaleAccounts {
    <#
    .SYNOPSIS
        Finds enabled accounts that have not logged on in N days.

    .DESCRIPTION
        Queries AD (Get-ADUser with LastLogonDate) or the simulated directory and
        returns enabled users whose last logon is older than -Days, or who have never
        logged on. Pipe the output to Export-Csv for an access review, or feed the
        SamAccountName column into Remove-ADUserOffboard.

        Note: LastLogonDate (lastLogonTimestamp) replicates with up to ~14 days of lag,
        which is fine for a 30/60/90 day stale report.

    .PARAMETER Days
        Inactivity threshold in days (default 90).

    .PARAMETER AsOf
        Reference date (default now). Useful for repeatable reports and tests.

    .PARAMETER SearchBase
        Optional OU to limit the AD query.

    .PARAMETER IncludeNeverLoggedOn
        Include accounts with no recorded logon (default: included).

    .PARAMETER Simulate
        Use samples/simulated-directory.csv instead of AD.

    .PARAMETER SimulatedDirectoryPath
        Directory CSV used in -Simulate mode.

    .EXAMPLE
        Get-StaleAccounts -Days 90 -Simulate | Format-Table

    .EXAMPLE
        Get-StaleAccounts -Days 60 -SearchBase 'OU=Staff,DC=contoso,DC=com' | Export-Csv stale.csv -NoTypeInformation
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Name requested for discoverability; returns a set of accounts.')]
    [CmdletBinding()]
    param(
        [ValidateRange(1, 3650)][int]$Days = 90,
        [datetime]$AsOf = (Get-Date),
        [string]$SearchBase,
        [bool]$IncludeNeverLoggedOn = $true,
        [switch]$Simulate,
        [string]$SimulatedDirectoryPath
    )

    Assert-DirectoryBackend -Simulate:$Simulate
    $cutoff = $AsOf.AddDays(-$Days)

    if ($Simulate) {
        $dirArgs = @{}
        if ($SimulatedDirectoryPath) { $dirArgs.Path = $SimulatedDirectoryPath }
        $users = @(Get-SimulatedDirectory @dirArgs)
    }
    else {
        $adArgs = @{ Filter = 'Enabled -eq $true'; Properties = 'LastLogonDate', 'DisplayName', 'Department'; ErrorAction = 'Stop' }
        if ($SearchBase) { $adArgs.SearchBase = $SearchBase }
        $users = @(Get-ADUser @adArgs)
    }

    $stale = foreach ($u in $users) {
        if (-not $u.Enabled) { continue }
        $last = $u.LastLogonDate
        if (-not $last -and -not $IncludeNeverLoggedOn) { continue }
        if ($last -and $last -ge $cutoff) { continue }
        [pscustomobject]@{
            SamAccountName = $u.SamAccountName
            DisplayName    = $u.DisplayName
            Department     = $u.Department
            LastLogonDate  = $last
            DaysInactive   = if ($last) { [int]($AsOf - $last).TotalDays } else { $null }
            Reason         = if ($last) { "No logon in $Days+ days" } else { 'Never logged on' }
        }
    }
    $stale = @($stale | Sort-Object -Property @{ Expression = { if ($null -eq $_.DaysInactive) { [int]::MaxValue } else { $_.DaysInactive } }; Descending = $true })
    Write-AdminLog -Message "Stale account scan: $($stale.Count) of $($users.Count) over $Days days" -Data @{ simulate = [bool]$Simulate }
    $stale
}
