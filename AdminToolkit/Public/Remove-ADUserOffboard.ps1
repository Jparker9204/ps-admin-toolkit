function Remove-ADUserOffboard {
    <#
    .SYNOPSIS
        Offboards departing users from a CSV: disable, strip groups, stamp, move to a Disabled OU.

    .DESCRIPTION
        For each SamAccountName in the CSV (columns: SamAccountName, Reason, TicketId) this:

          1. Disables the account
          2. Removes every group membership except the primary group (Domain Users)
          3. Sets Description to "Offboarded <date> | <ticket> | <reason>"
          4. Moves the account to -DisabledOU

        Accounts are disabled, not deleted, so they can be restored during the
        retention window. Removed groups are recorded in the report so access can be
        rebuilt if HR reverses the decision. Use -Simulate to run against
        samples/simulated-directory.csv without AD. ConfirmImpact is High, so you are
        prompted per user unless -Confirm:$false is passed.

    .PARAMETER Path
        CSV of users to offboard. See samples/offboard.csv.

    .PARAMETER DisabledOU
        Destination OU for disabled accounts.

    .PARAMETER ReportPath
        Report file (.csv or .json).

    .PARAMETER Simulate
        Do not touch AD; report what would happen.

    .PARAMETER SimulatedDirectoryPath
        Directory CSV used in -Simulate mode.

    .EXAMPLE
        Remove-ADUserOffboard -Path .\samples\offboard.csv -Simulate

    .EXAMPLE
        Remove-ADUserOffboard -Path .\leavers.csv -DisabledOU 'OU=Disabled,DC=contoso,DC=com' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$Path,
        [string]$DisabledOU = 'OU=Disabled Users,DC=contoso,DC=com',
        [string]$ReportPath = (Join-Path (Get-Location) ("reports/offboarding-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date))),
        [switch]$Simulate,
        [string]$SimulatedDirectoryPath
    )

    Assert-DirectoryBackend -Simulate:$Simulate
    $rows = @(Import-Csv -LiteralPath $Path)
    $directory = @{}
    if ($Simulate) {
        $dirArgs = @{}
        if ($SimulatedDirectoryPath) { $dirArgs.Path = $SimulatedDirectoryPath }
        foreach ($u in (Get-SimulatedDirectory @dirArgs)) { $directory[$u.SamAccountName] = $u }
    }
    $stamp = "Offboarded {0:yyyy-MM-dd}" -f (Get-Date)

    $results = foreach ($row in $rows) {
        $sam = "$($row.SamAccountName)".Trim()
        $description = (@($stamp, $row.TicketId, $row.Reason) | Where-Object { $_ }) -join ' | '
        $result = [pscustomobject]@{
            SamAccountName = $sam; DisplayName = $null; GroupsRemoved = $null
            MovedTo = $DisabledOU; Description = $description; Status = $null; Message = $null
        }
        try {
            if ($Simulate) {
                if (-not $directory.ContainsKey($sam)) { throw "User '$sam' not found in simulated directory" }
                $user = $directory[$sam]
                $groups = @($user.MemberOf | Where-Object { $_ -ne 'Domain Users' })
            }
            else {
                $user = Get-ADUser -Identity $sam -Properties DisplayName, MemberOf -ErrorAction Stop
                $groups = @($user.MemberOf)
            }
            $result.DisplayName = $user.DisplayName
            $result.GroupsRemoved = ($groups | ForEach-Object { ($_ -split ',')[0] -replace '^CN=' }) -join ';'
            if (-not $user.Enabled -and $Simulate) { $result.Message = 'Already disabled; ' }

            if ($Simulate) {
                $result.Status = 'Simulated'
                $result.Message += "Would disable, remove $($groups.Count) group(s), move to Disabled OU"
                Write-AdminLog -Message "Simulated offboard $sam" -Data @{ groups = $groups.Count }
            }
            elseif ($PSCmdlet.ShouldProcess("$sam ($($user.DisplayName))", 'Disable, remove groups, move to Disabled OU')) {
                Disable-ADAccount -Identity $sam -ErrorAction Stop
                foreach ($g in $groups) {
                    Remove-ADGroupMember -Identity $g -Members $sam -Confirm:$false -ErrorAction Stop
                }
                Set-ADUser -Identity $sam -Description $description -ErrorAction Stop
                Move-ADObject -Identity $user.DistinguishedName -TargetPath $DisabledOU -ErrorAction Stop
                $result.Status = 'Offboarded'
                $result.Message = "Disabled and removed from $($groups.Count) group(s)"
                Write-AdminLog -Message "Offboarded $sam" -Data @{ groups = $result.GroupsRemoved; ticket = $row.TicketId }
            }
            else {
                $result.Status = 'WhatIf'; $result.Message = 'No changes made (-WhatIf or declined)'
            }
        }
        catch {
            $result.Status = 'Failed'; $result.Message = $_.Exception.Message
            Write-AdminLog -Level Warning -Message "Offboard failed for ${sam}: $($_.Exception.Message)"
        }
        $result
    }

    $results = @($results)
    Export-ActionReport -InputObject $results -Path $ReportPath
    $results
}
