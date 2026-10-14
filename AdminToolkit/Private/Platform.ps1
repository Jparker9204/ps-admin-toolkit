function Test-IsWindowsHost {
    <#
    .SYNOPSIS
        Returns $true on Windows for both Windows PowerShell 5.1 and PowerShell 7+.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    return [bool]$IsWindows
}

function Test-ADModuleAvailable {
    <#
    .SYNOPSIS
        Returns $true when the RSAT ActiveDirectory module can be loaded.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool](Get-Module -ListAvailable -Name ActiveDirectory)
}

function Assert-DirectoryBackend {
    <#
    .SYNOPSIS
        Throws a helpful error when AD is required but missing (and -Simulate was not used).
    #>
    [CmdletBinding()]
    param([switch]$Simulate)
    if ($Simulate) { return }
    if (-not (Test-ADModuleAvailable)) {
        throw 'The ActiveDirectory module (RSAT) is not available on this machine. Install RSAT, or re-run with -Simulate to demo against the sample directory.'
    }
    Import-Module ActiveDirectory -ErrorAction Stop -Verbose:$false
}
