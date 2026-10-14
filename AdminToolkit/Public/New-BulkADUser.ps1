function New-BulkADUser {
    <#
    .SYNOPSIS
        Onboards new hires from a CSV into Active Directory (or a simulated directory).

    .DESCRIPTION
        Reads a CSV with FirstName, LastName, Department, Title, Office, Manager and
        optional EmployeeId / OU / Groups (semicolon separated) columns. For each row it:

          1. Builds a unique sAMAccountName (first initial + last name, numbered on collision)
          2. Generates a random 16-character initial password (SecureString)
          3. Creates the user (disabled until -Enable is used), forces a password change at logon
          4. Adds the user to the requested groups
          5. Writes a structured log entry and a CSV/JSON report row

        Use -Simulate to run without the ActiveDirectory module: collisions are
        checked against samples/simulated-directory.csv and nothing is changed.
        Supports -WhatIf and -Confirm. Passwords never appear in the report or log.

    .PARAMETER Path
        CSV of new hires. See samples/new-hires.csv.

    .PARAMETER UpnSuffix
        UPN suffix, e.g. contoso.com.

    .PARAMETER DefaultOU
        OU used when a row has no OU column value.

    .PARAMETER ReportPath
        Report file (.csv or .json). Defaults to ./reports/onboarding-<timestamp>.csv.

    .PARAMETER Simulate
        Do not touch AD; validate and report what would be created.

    .PARAMETER SimulatedDirectoryPath
        Directory CSV used for collision checks in -Simulate mode.

    .PARAMETER Enable
        Create accounts enabled (default is disabled until the start date).

    .EXAMPLE
        New-BulkADUser -Path .\samples\new-hires.csv -UpnSuffix contoso.com -Simulate

        Demo anywhere: shows the accounts that would be created and writes a report.

    .EXAMPLE
        New-BulkADUser -Path .\hires.csv -UpnSuffix contoso.com -DefaultOU 'OU=Staff,DC=contoso,DC=com' -WhatIf

    .OUTPUTS
        PSCustomObject per row: SamAccountName, DisplayName, UserPrincipalName, OU,
        Groups, Status (Created / Simulated / WhatIf / Skipped / Failed), Message,
        and InitialPassword (SecureString, only when Status is Created).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$Path,
        [Parameter(Mandatory)][string]$UpnSuffix,
        [string]$DefaultOU = 'OU=Users,OU=Staff,DC=contoso,DC=com',
        [string]$ReportPath = (Join-Path (Get-Location) ("reports/onboarding-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date))),
        [switch]$Simulate,
        [string]$SimulatedDirectoryPath,
        [switch]$Enable
    )

    Assert-DirectoryBackend -Simulate:$Simulate
    $rows = @(Import-Csv -LiteralPath $Path)
    $required = 'FirstName', 'LastName'
    $taken = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ($Simulate) {
        $dirArgs = @{}
        if ($SimulatedDirectoryPath) { $dirArgs.Path = $SimulatedDirectoryPath }
        foreach ($u in (Get-SimulatedDirectory @dirArgs)) { [void]$taken.Add($u.SamAccountName) }
    }
    Write-AdminLog -Message "Onboarding started: $($rows.Count) row(s) from $Path" -Data @{ simulate = [bool]$Simulate }

    $results = foreach ($row in $rows) {
        $missing = @($required | Where-Object { -not $row.$_ })
        if ($missing) {
            [pscustomobject]@{
                SamAccountName = $null; DisplayName = "$($row.FirstName) $($row.LastName)".Trim()
                UserPrincipalName = $null; OU = $null; Groups = $null
                Status = 'Skipped'; Message = "Missing required column(s): $($missing -join ', ')"; InitialPassword = $null
            }
            continue
        }

        $first = $row.FirstName.Trim(); $last = $row.LastName.Trim()
        $base = ConvertTo-SafeAccountName -FirstName $first -LastName $last
        $sam = $base; $n = 1
        while ($true) {
            $exists = $taken.Contains($sam)
            if (-not $exists -and -not $Simulate) {
                $exists = [bool](Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue)
            }
            if (-not $exists) { break }
            $n++
            $suffix = [string]$n
            $sam = $base.Substring(0, [Math]::Min($base.Length, 20 - $suffix.Length)) + $suffix
        }
        [void]$taken.Add($sam)

        $ou = $DefaultOU
        if ($row.PSObject.Properties['OU'] -and $row.OU) { $ou = $row.OU }
        $groups = @()
        if ($row.PSObject.Properties['Groups'] -and $row.Groups) { $groups = @($row.Groups -split ';' | Where-Object { $_ }) }
        $display = "$first $last"
        $upn = "$sam@$UpnSuffix"
        $result = [pscustomobject]@{
            SamAccountName = $sam; DisplayName = $display; UserPrincipalName = $upn; OU = $ou
            Groups = ($groups -join ';'); Status = $null; Message = $null; InitialPassword = $null
        }

        if ($Simulate) {
            $result.Status = 'Simulated'
            $result.Message = if ($n -gt 1) { "Name collision; numbered to $sam" } else { 'Would create user' }
            Write-AdminLog -Message "Simulated create $sam" -Data @{ upn = $upn; ou = $ou }
            $result; continue
        }

        if (-not $PSCmdlet.ShouldProcess("$display ($upn) in $ou", 'Create AD user')) {
            $result.Status = 'WhatIf'; $result.Message = 'Not created (-WhatIf or declined)'
            $result; continue
        }

        try {
            $password = Get-RandomPassword
            $params = @{
                Name                  = $display
                GivenName             = $first
                Surname               = $last
                DisplayName           = $display
                SamAccountName        = $sam
                UserPrincipalName     = $upn
                Path                  = $ou
                AccountPassword       = $password
                Enabled               = [bool]$Enable
                ChangePasswordAtLogon = $true
                ErrorAction           = 'Stop'
            }
            foreach ($map in @{ Department = 'Department'; Title = 'Title'; Office = 'Office'; EmployeeId = 'EmployeeID' }.GetEnumerator()) {
                if ($row.PSObject.Properties[$map.Key] -and $row.($map.Key)) { $params[$map.Value] = $row.($map.Key) }
            }
            New-ADUser @params
            foreach ($g in $groups) { Add-ADGroupMember -Identity $g -Members $sam -ErrorAction Stop }
            $result.Status = 'Created'; $result.Message = 'User created; must change password at logon'
            $result.InitialPassword = $password
            Write-AdminLog -Message "Created $sam" -Data @{ upn = $upn; ou = $ou; groups = $groups }
        }
        catch {
            $result.Status = 'Failed'; $result.Message = $_.Exception.Message
            Write-AdminLog -Level Warning -Message "Failed to create ${sam}: $($_.Exception.Message)"
        }
        $result
    }

    $results = @($results)
    Export-ActionReport -InputObject @($results | Select-Object * -ExcludeProperty InitialPassword) -Path $ReportPath
    Write-AdminLog -Message "Onboarding finished; report $ReportPath" -Data @{ total = $results.Count }
    Write-Verbose "Report written to $ReportPath"
    $results
}
