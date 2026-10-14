function Get-WindowsInventoryData {
    [CmdletBinding()]
    param([switch]$SkipSoftware)
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cpu = @(Get-CimInstance -ClassName Win32_Processor)
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        [pscustomobject]@{
            Name = $_.DeviceID; FileSystem = $_.FileSystem
            SizeGB = [math]::Round($_.Size / 1GB, 1); FreeGB = [math]::Round($_.FreeSpace / 1GB, 1)
            PercentFree = if ($_.Size) { [math]::Round(100 * $_.FreeSpace / $_.Size, 1) } else { 0 }
        }
    }
    $software = @()
    if (-not $SkipSoftware) {
        $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        $software = @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
                Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName } |
                ForEach-Object {
                    [pscustomobject]@{
                        Name      = $_.DisplayName
                        Version   = if ($_.PSObject.Properties['DisplayVersion']) { $_.DisplayVersion } else { $null }
                        Publisher = if ($_.PSObject.Properties['Publisher']) { $_.Publisher } else { $null }
                    }
                } | Sort-Object Name -Unique)
    }
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        OS           = $os.Caption
        OSVersion    = $os.Version
        CPU          = $cpu[0].Name.Trim()
        Cores        = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        MemoryGB     = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        MemoryFreeGB = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 1)
        UptimeDays   = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 2)
        LastBoot     = $os.LastBootUpTime.ToString('s')
        Disks        = @($disks)
        Software     = $software
    }
}

function Get-UnixInventoryData {
    [CmdletBinding()]
    param([switch]$SkipSoftware, [string]$ProcRoot = '/proc', [string]$OsReleasePath = '/etc/os-release')
    $osName = [Environment]::OSVersion.VersionString; $osVersion = ''
    if (Test-Path -LiteralPath $OsReleasePath) {
        $rel = @{}
        foreach ($line in (Get-Content -LiteralPath $OsReleasePath)) {
            if ($line -match '^([A-Z_]+)=(.*)$') { $rel[$Matches[1]] = $Matches[2].Trim('"') }
        }
        if ($rel['PRETTY_NAME']) { $osName = $rel['PRETTY_NAME'] }
        if ($rel['VERSION_ID']) { $osVersion = $rel['VERSION_ID'] }
    }
    $cpuName = 'Unknown'
    $cpuInfo = Join-Path $ProcRoot 'cpuinfo'
    if (Test-Path -LiteralPath $cpuInfo) {
        $m = Select-String -LiteralPath $cpuInfo -Pattern '^model name\s*:\s*(.+)$' | Select-Object -First 1
        if ($m) { $cpuName = $m.Matches[0].Groups[1].Value.Trim() }
    }
    $memTotal = 0; $memAvail = 0
    $memInfo = Join-Path $ProcRoot 'meminfo'
    if (Test-Path -LiteralPath $memInfo) {
        foreach ($line in (Get-Content -LiteralPath $memInfo)) {
            if ($line -match '^MemTotal:\s+(\d+)') { $memTotal = [double]$Matches[1] * 1KB }
            if ($line -match '^MemAvailable:\s+(\d+)') { $memAvail = [double]$Matches[1] * 1KB }
        }
    }
    $uptimeSec = 0
    $uptimeFile = Join-Path $ProcRoot 'uptime'
    if (Test-Path -LiteralPath $uptimeFile) {
        $uptimeSec = [double]::Parse((Get-Content -LiteralPath $uptimeFile -Raw).Split(' ')[0], [Globalization.CultureInfo]::InvariantCulture)
    }
    $disks = [System.IO.DriveInfo]::GetDrives() | Where-Object {
        $_.IsReady -and $_.DriveType -eq 'Fixed' -and $_.TotalSize -gt 1GB -and $_.Name -notmatch '^/(proc|sys|dev|run|snap)'
    } | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Name; FileSystem = $_.DriveFormat
            SizeGB = [math]::Round($_.TotalSize / 1GB, 1); FreeGB = [math]::Round($_.AvailableFreeSpace / 1GB, 1)
            PercentFree = [math]::Round(100 * $_.AvailableFreeSpace / $_.TotalSize, 1)
        }
    }
    $software = @()
    if (-not $SkipSoftware) {
        if (Get-Command dpkg-query -ErrorAction SilentlyContinue) {
            $software = @(& dpkg-query -W -f '${Package}\t${Version}\t${Maintainer}\n' 2>$null | ForEach-Object {
                    $p = $_ -split "`t"; [pscustomobject]@{ Name = $p[0]; Version = $p[1]; Publisher = $p[2] }
                })
        }
        elseif (Get-Command rpm -ErrorAction SilentlyContinue) {
            $software = @(& rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{VENDOR}\n' 2>$null | ForEach-Object {
                    $p = $_ -split "`t"; [pscustomobject]@{ Name = $p[0]; Version = $p[1]; Publisher = $p[2] }
                } | Sort-Object Name)
        }
    }
    $boot = (Get-Date).AddSeconds(-$uptimeSec)
    [pscustomobject]@{
        ComputerName = [Environment]::MachineName
        OS           = $osName
        OSVersion    = $osVersion
        CPU          = $cpuName
        Cores        = [Environment]::ProcessorCount
        MemoryGB     = [math]::Round($memTotal / 1GB, 1)
        MemoryFreeGB = [math]::Round($memAvail / 1GB, 1)
        UptimeDays   = [math]::Round($uptimeSec / 86400, 2)
        LastBoot     = $boot.ToString('s')
        Disks        = @($disks)
        Software     = $software
    }
}

function Get-NetworkAdapterData {
    [CmdletBinding()]
    param()
    [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.NetworkInterfaceType -ne 'Loopback' } | ForEach-Object {
            $props = $_.GetIPProperties()
            $ipv4 = @($props.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.Address.ToString() })
            $gw = @($props.GatewayAddresses | ForEach-Object { $_.Address.ToString() } | Where-Object { $_ -ne '0.0.0.0' })
            $dns = @($props.DnsAddresses | ForEach-Object { $_.ToString() })
            $mac = ($_.GetPhysicalAddress().ToString() -replace '(..)(?!$)', '$1:')
            [pscustomobject]@{
                Name       = $_.Name
                Status     = $_.OperationalStatus.ToString()
                Type       = $_.NetworkInterfaceType.ToString()
                MAC        = $mac
                SpeedMbps  = if ($_.Speed -gt 0) { [math]::Round($_.Speed / 1e6) } else { $null }
                IPv4       = $ipv4 -join ', '
                Gateway    = $gw -join ', '
                DnsServers = $dns -join ', '
            }
        }
}

function ConvertTo-InventoryHtml {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inventory)
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $summary = $Inventory | Select-Object ComputerName, OS, OSVersion, CPU, Cores, MemoryGB, MemoryFreeGB, UptimeDays, LastBoot, CollectedAt
    $sections = @(
        ($summary | ConvertTo-Html -As List -Fragment -PreContent '<h2>Summary</h2>')
        (@($Inventory.Disks) | ConvertTo-Html -Fragment -PreContent '<h2>Disks</h2>')
        (@($Inventory.NetworkAdapters) | ConvertTo-Html -Fragment -PreContent '<h2>Network adapters</h2>')
    )
    if (@($Inventory.Software).Count) {
        $sections += (@($Inventory.Software) | ConvertTo-Html -Fragment -PreContent "<h2>Installed software ($(@($Inventory.Software).Count))</h2>")
    }
    $css = 'body{font-family:Segoe UI,Arial,sans-serif;margin:2em;color:#222}h1{color:#0b5394}table{border-collapse:collapse;margin-bottom:1.5em}td,th{border:1px solid #ccc;padding:4px 8px;font-size:13px}th{background:#0b5394;color:#fff}tr:nth-child(even){background:#f3f6fa}'
    $title = "System inventory - $(& $enc $Inventory.ComputerName)"
    "<!DOCTYPE html><html><head><meta charset='utf-8'><title>$title</title><style>$css</style></head><body><h1>$title</h1>$(($sections | Out-String))<p><small>Generated by AdminToolkit</small></p></body></html>"
}
