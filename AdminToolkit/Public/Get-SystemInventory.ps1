function Get-SystemInventory {
    <#
    .SYNOPSIS
        Collects OS, CPU, memory, disk, uptime, software and network adapter inventory and exports CSV/JSON/HTML.

    .DESCRIPTION
        Works on Windows (CIM + registry uninstall keys) and Linux (/proc, /etc/os-release,
        dpkg/rpm). Network adapters use .NET NetworkInterface on every platform.

        With -OutputPath, writes:
          * <name>.json  - full nested inventory
          * <name>.html  - single-file report for a ticket or asset audit
          * <name>-summary.csv, -disks.csv, -network.csv, -software.csv  - flat tables for Excel

    .PARAMETER OutputPath
        Folder for report files. When omitted only the object is returned.

    .PARAMETER Format
        One or more of Csv, Json, Html (default all three).

    .PARAMETER SkipSoftware
        Skip the installed software list (faster).

    .EXAMPLE
        Get-SystemInventory | Select-Object ComputerName, OS, CPU, MemoryGB, UptimeDays

    .EXAMPLE
        Get-SystemInventory -OutputPath .\reports -Format Html, Json

    .OUTPUTS
        PSCustomObject with ComputerName, OS, OSVersion, CPU, Cores, MemoryGB,
        MemoryFreeGB, UptimeDays, LastBoot, Disks, NetworkAdapters, Software, CollectedAt.
    #>
    [CmdletBinding()]
    param(
        [string]$OutputPath,
        [ValidateSet('Csv', 'Json', 'Html')][string[]]$Format = @('Csv', 'Json', 'Html'),
        [switch]$SkipSoftware
    )

    $onWindows = Test-IsWindowsHost
    $inv = if ($onWindows) { Get-WindowsInventoryData -SkipSoftware:$SkipSoftware } else { Get-UnixInventoryData -SkipSoftware:$SkipSoftware }
    $inv | Add-Member -NotePropertyName NetworkAdapters -NotePropertyValue @(Get-NetworkAdapterData)
    $inv | Add-Member -NotePropertyName CollectedAt -NotePropertyValue ((Get-Date).ToString('s'))

    if ($OutputPath) {
        if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        $name = "inventory-{0}-{1:yyyyMMdd-HHmmss}" -f $inv.ComputerName, (Get-Date)
        $base = Join-Path $OutputPath $name
        $files = @()
        if ('Json' -in $Format) {
            $inv | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$base.json" -Encoding UTF8
            $files += "$base.json"
        }
        if ('Csv' -in $Format) {
            $inv | Select-Object * -ExcludeProperty Disks, NetworkAdapters, Software | Export-Csv "$base-summary.csv" -NoTypeInformation -Encoding UTF8
            $inv.Disks | Export-Csv "$base-disks.csv" -NoTypeInformation -Encoding UTF8
            $inv.NetworkAdapters | Export-Csv "$base-network.csv" -NoTypeInformation -Encoding UTF8
            $files += "$base-summary.csv", "$base-disks.csv", "$base-network.csv"
            if (@($inv.Software).Count) {
                $inv.Software | Export-Csv "$base-software.csv" -NoTypeInformation -Encoding UTF8
                $files += "$base-software.csv"
            }
        }
        if ('Html' -in $Format) {
            ConvertTo-InventoryHtml -Inventory $inv | Set-Content -LiteralPath "$base.html" -Encoding UTF8
            $files += "$base.html"
        }
        Write-AdminLog -Message "Inventory exported for $($inv.ComputerName)" -Data @{ files = $files }
        $inv | Add-Member -NotePropertyName ReportFiles -NotePropertyValue $files
    }
    $inv
}
