function Get-RecycleBinSize {
    <#
    .SYNOPSIS
        Returns the total size in bytes of items in the Windows Recycle Bin (0 elsewhere).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param()
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.Namespace(10)
        $total = 0
        foreach ($item in $bin.Items()) { $total += [double]$item.ExtendedProperty('Size') }
        return $total
    }
    catch { return 0 }
}
