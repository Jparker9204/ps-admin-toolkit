function Get-SimulatedDirectory {
    <#
    .SYNOPSIS
        Loads the sample directory CSV used by -Simulate mode.
    .DESCRIPTION
        Columns: SamAccountName, DisplayName, Enabled, LastLogonDate, Department,
        MemberOf (semicolon separated), DistinguishedName.
    #>
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path $script:SampleRoot 'simulated-directory.csv')
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Simulated directory file not found: $Path"
    }
    foreach ($row in (Import-Csv -LiteralPath $Path)) {
        $lastLogon = $null
        if ($row.LastLogonDate) {
            $lastLogon = [datetime]::Parse($row.LastLogonDate, [Globalization.CultureInfo]::InvariantCulture)
        }
        [pscustomobject]@{
            SamAccountName    = $row.SamAccountName
            DisplayName       = $row.DisplayName
            Enabled           = [System.Convert]::ToBoolean($row.Enabled)
            LastLogonDate     = $lastLogon
            Department        = $row.Department
            MemberOf          = @($row.MemberOf -split ';' | Where-Object { $_ })
            DistinguishedName = $row.DistinguishedName
        }
    }
}
