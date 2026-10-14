function Invoke-DiskCleanup {
    <#
    .SYNOPSIS
        Cleans temp files, the Recycle Bin and the Windows Update download cache, and reports space freed.

    .DESCRIPTION
        Targets:
          * UserTemp           - the current user's temp folder (all platforms)
          * WindowsTemp        - C:\Windows\Temp (Windows, needs admin)
          * WindowsUpdateCache - C:\Windows\SoftwareDistribution\Download (Windows, admin;
                                 the wuauserv service is stopped and restarted around the delete)
          * RecycleBin         - all drives (Windows)

        Only files older than -OlderThanDays are removed so in-use installer files are
        left alone. Locked files are skipped and counted. Always try it with -WhatIf
        first: the report shows what would be freed without deleting anything.

    .PARAMETER Target
        One or more targets (default: UserTemp, WindowsTemp, RecycleBin).

    .PARAMETER OlderThanDays
        Minimum file age to delete (default 7).

    .PARAMETER AdditionalPath
        Extra folders to clean with the same age rule (e.g. a log folder).

    .EXAMPLE
        Invoke-DiskCleanup -WhatIf | Format-Table

    .EXAMPLE
        Invoke-DiskCleanup -Target UserTemp, WindowsUpdateCache -OlderThanDays 14 -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [ValidateSet('UserTemp', 'WindowsTemp', 'WindowsUpdateCache', 'RecycleBin')]
        [AllowEmptyCollection()][string[]]$Target = @('UserTemp', 'WindowsTemp', 'RecycleBin'),
        [ValidateRange(0, 3650)][int]$OlderThanDays = 7,
        [string[]]$AdditionalPath = @()
    )

    $onWindows = Test-IsWindowsHost
    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $winDir = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
    $jobs = @()
    foreach ($t in $Target) {
        switch ($t) {
            'UserTemp' { $jobs += @{ Name = $t; Path = [IO.Path]::GetTempPath(); WindowsOnly = $false } }
            'WindowsTemp' { $jobs += @{ Name = $t; Path = "$winDir\Temp"; WindowsOnly = $true } }
            'WindowsUpdateCache' { $jobs += @{ Name = $t; Path = "$winDir\SoftwareDistribution\Download"; WindowsOnly = $true; Service = 'wuauserv' } }
            'RecycleBin' { $jobs += @{ Name = $t; Path = 'Recycle Bin'; WindowsOnly = $true; RecycleBin = $true } }
        }
    }
    foreach ($p in $AdditionalPath) { $jobs += @{ Name = 'Custom'; Path = $p; WindowsOnly = $false } }

    $results = foreach ($job in $jobs) {
        $r = [pscustomobject]@{
            Target = $job.Name; Path = $job.Path; FilesFound = 0; MBFound = 0
            FilesRemoved = 0; MBFreed = 0; BytesFreed = 0; Skipped = 0; Status = $null
        }
        if ($job.WindowsOnly -and -not $onWindows) { $r.Status = 'NotSupportedOnPlatform'; $r; continue }

        if ($job.ContainsKey('RecycleBin')) {
            $bytes = Get-RecycleBinSize
            $r.MBFound = [math]::Round($bytes / 1MB, 2)
            if ($PSCmdlet.ShouldProcess('Recycle Bin (all drives)', 'Empty')) {
                try {
                    Clear-RecycleBin -Force -ErrorAction Stop
                    $r.MBFreed = $r.MBFound; $r.BytesFreed = $bytes; $r.Status = 'Cleaned'
                }
                catch { $r.Status = "Failed: $($_.Exception.Message)" }
            }
            else { $r.Status = 'WhatIf' }
            $r; continue
        }

        if (-not (Test-Path -LiteralPath $job.Path)) { $r.Status = 'PathNotFound'; $r; continue }
        $files = @(Get-ChildItem -LiteralPath $job.Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoff })
        $r.FilesFound = $files.Count
        $found = 0
        foreach ($f in $files) { $found += $f.Length }
        $r.MBFound = [math]::Round($found / 1MB, 2)

        if (-not $files.Count) { $r.Status = 'NothingToClean'; $r; continue }
        if (-not $PSCmdlet.ShouldProcess("$($job.Path) ($($files.Count) files, $($r.MBFound) MB)", 'Delete files')) {
            $r.Status = 'WhatIf'; $r; continue
        }

        $serviceStopped = $false
        if ($job.ContainsKey('Service')) {
            $svc = Get-Service -Name $job.Service -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') { Stop-Service -Name $job.Service -Force -Confirm:$false; $serviceStopped = $true }
        }
        $freed = 0
        foreach ($f in $files) {
            try {
                $len = $f.Length
                Remove-Item -LiteralPath $f.FullName -Force -Confirm:$false -ErrorAction Stop
                $r.FilesRemoved++; $freed += $len
            }
            catch { $r.Skipped++ }
        }
        if ($serviceStopped) { Start-Service -Name $job.Service -Confirm:$false }
        $r.BytesFreed = $freed
        $r.MBFreed = [math]::Round($freed / 1MB, 2)
        $r.Status = if ($r.Skipped) { 'CleanedWithSkips' } else { 'Cleaned' }
        $r
    }

    $results = @($results)
    $total = 0
    foreach ($r in $results) { $total += $r.MBFreed }
    Write-AdminLog -Message ("Disk cleanup freed {0} MB" -f $total) -Data @{ whatIf = [bool]$WhatIfPreference; targets = $Target }
    $results
}
