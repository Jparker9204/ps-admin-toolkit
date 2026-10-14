BeforeAll { . (Join-Path $PSScriptRoot 'TestHelpers.ps1') }

Describe 'Get-SystemInventory' {
    It 'returns the core fields on any platform' {
        $inv = Get-SystemInventory -SkipSoftware
        $inv.ComputerName | Should -Not -BeNullOrEmpty
        $inv.OS | Should -Not -BeNullOrEmpty
        $inv.Cores | Should -BeGreaterThan 0
        $inv.MemoryGB | Should -BeGreaterThan 0
        $inv.PSObject.Properties.Name | Should -Contain 'NetworkAdapters'
    }
    It 'exports CSV, JSON and HTML reports' {
        $inv = Get-SystemInventory -SkipSoftware -OutputPath $TestDrive
        ($inv.ReportFiles | Where-Object { $_ -like '*.json' }) | Should -Exist
        ($inv.ReportFiles | Where-Object { $_ -like '*.html' }) | Should -Exist
        ($inv.ReportFiles | Where-Object { $_ -like '*-summary.csv' }) | Should -Exist
        $json = Get-Content ($inv.ReportFiles | Where-Object { $_ -like '*.json' }) -Raw | ConvertFrom-Json
        $json.ComputerName | Should -Be $inv.ComputerName
    }
    It 'only writes the requested formats' {
        $out = Join-Path $TestDrive 'jsononly'
        $inv = Get-SystemInventory -SkipSoftware -OutputPath $out -Format Json
        @($inv.ReportFiles).Count | Should -Be 1
    }
    It 'parses Linux /proc and os-release files (mocked filesystem)' {
        $proc = Join-Path $TestDrive 'proc'; New-Item -ItemType Directory $proc | Out-Null
        "model name`t: Test CPU @ 3.00GHz" | Set-Content (Join-Path $proc 'cpuinfo')
        "MemTotal:       16384000 kB`nMemAvailable:    8192000 kB" | Set-Content (Join-Path $proc 'meminfo')
        '172800.50 1000.00' | Set-Content (Join-Path $proc 'uptime')
        $rel = Join-Path $TestDrive 'os-release'
        "PRETTY_NAME=`"Ubuntu 24.04 LTS`"`nVERSION_ID=`"24.04`"" | Set-Content $rel
        $inv = InModuleScope AdminToolkit -Parameters @{ p = $proc; r = $rel } {
            Get-UnixInventoryData -SkipSoftware -ProcRoot $p -OsReleasePath $r
        }
        $inv.OS | Should -Be 'Ubuntu 24.04 LTS'
        $inv.CPU | Should -Be 'Test CPU @ 3.00GHz'
        $inv.MemoryGB | Should -Be 15.6
        $inv.UptimeDays | Should -Be 2
    }
    It 'collects Windows data via CIM' -Skip:(-not ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows)) {
        $inv = Get-SystemInventory -SkipSoftware
        $inv.Disks.Count | Should -BeGreaterThan 0
        $inv.OS | Should -Match 'Windows'
    }
}

Describe 'Invoke-DiskCleanup' {
    BeforeEach {
        $dir = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $dir | Out-Null
        $old = Join-Path $dir 'old.tmp'; $new = Join-Path $dir 'new.tmp'
        Set-Content $old ('x' * 2048); Set-Content $new ('y' * 1024)
        (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-30)
    }
    It 'reports but does not delete with -WhatIf' {
        $r = Invoke-DiskCleanup -Target @() -AdditionalPath $dir -WhatIf | Where-Object Target -eq 'Custom'
        $r.Status | Should -Be 'WhatIf'
        $r.FilesFound | Should -Be 1
        $old | Should -Exist
    }
    It 'deletes only files older than -OlderThanDays and reports space freed' {
        $r = Invoke-DiskCleanup -Target @() -AdditionalPath $dir -OlderThanDays 7 -Confirm:$false |
            Where-Object Target -eq 'Custom'
        $r.Status | Should -Be 'Cleaned'
        $r.FilesRemoved | Should -Be 1
        $r.BytesFreed | Should -BeGreaterThan 2000
        $old | Should -Not -Exist
        $new | Should -Exist
    }
    It 'counts locked/undeletable files as skipped' {
        Mock -ModuleName AdminToolkit Remove-Item { throw 'in use' }
        $r = Invoke-DiskCleanup -Target @() -AdditionalPath $dir -Confirm:$false | Where-Object Target -eq 'Custom'
        $r.Status | Should -Be 'CleanedWithSkips'
        $r.Skipped | Should -Be 1
    }
    It 'marks Windows-only targets as unsupported on Linux/macOS' -Skip:($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
        $r = Invoke-DiskCleanup -Target WindowsTemp, WindowsUpdateCache, RecycleBin -WhatIf
        $r.Status | Sort-Object -Unique | Should -Be 'NotSupportedOnPlatform'
    }
    It 'stops wuauserv around the update cache cleanup' -Skip:(-not ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows)) {
        Mock -ModuleName AdminToolkit Get-ChildItem { [pscustomobject]@{ FullName = 'C:\x.cab'; Length = 1MB; LastWriteTime = (Get-Date).AddDays(-60) } }
        Mock -ModuleName AdminToolkit Test-Path { $true }
        Mock -ModuleName AdminToolkit Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock -ModuleName AdminToolkit Stop-Service { }
        Mock -ModuleName AdminToolkit Start-Service { }
        Mock -ModuleName AdminToolkit Remove-Item { }
        $r = Invoke-DiskCleanup -Target WindowsUpdateCache -Confirm:$false
        $r.FilesRemoved | Should -Be 1
        Should -Invoke -ModuleName AdminToolkit Stop-Service -Times 1
        Should -Invoke -ModuleName AdminToolkit Start-Service -Times 1
    }
}

Describe 'Test-ServiceHealth' {
    It 'requires at least one check' {
        { Test-ServiceHealth } | Should -Throw '*Nothing to check*'
    }
    It 'reports open and closed ports' {
        Mock -ModuleName AdminToolkit Test-TcpPort { @{ Open = ($Port -eq 443); Detail = 'x'; Ms = 5 } }
        $r = Test-ServiceHealth -Port 'example.com:443', 'example.com:3389'
        ($r | Where-Object Target -eq 'example.com:443').Status | Should -Be 'Healthy'
        ($r | Where-Object Target -eq 'example.com:3389').Status | Should -Be 'Unhealthy'
    }
    It 'treats HTTP 4xx/5xx as unhealthy' {
        Mock -ModuleName AdminToolkit Test-HttpEndpoint { @{ Healthy = $Uri -notmatch '503'; Detail = 'HTTP'; Ms = 10 } }
        $r = Test-ServiceHealth -Url 'https://ok.example', 'https://x.example/503' -WarningAction SilentlyContinue
        ($r.Status -join ',') | Should -Be 'Healthy,Unhealthy'
    }
    It 'reads checks from a JSON config file' {
        Mock -ModuleName AdminToolkit Test-ServiceState { @{ Exists = $true; Healthy = $true; Detail = 'Running'; Restarted = $false } }
        Mock -ModuleName AdminToolkit Test-TcpPort { @{ Open = $true; Detail = 'ok'; Ms = 1 } }
        Mock -ModuleName AdminToolkit Test-HttpEndpoint { @{ Healthy = $true; Detail = 'HTTP 200'; Ms = 1 } }
        $r = Test-ServiceHealth -ConfigPath (Join-Path $Samples 'health-checks.json')
        $r.Count | Should -Be 7
    }
    It 'restarts a stopped service when -RestartFailed is used' {
        $script:calls = 0
        Mock -ModuleName AdminToolkit Test-ServiceState {
            $script:calls++
            @{ Exists = $true; Healthy = ($script:calls -gt 1); Detail = 'state'; Restarted = $false }
        }
        Mock -ModuleName AdminToolkit Restart-ServiceCrossPlatform { }
        Mock -ModuleName AdminToolkit Start-Sleep { }
        $r = Test-ServiceHealth -Service Spooler -RestartFailed -Confirm:$false
        $r.Status | Should -Be 'Restarted'
        Should -Invoke -ModuleName AdminToolkit Restart-ServiceCrossPlatform -Times 1
    }
    It 'does not restart with -WhatIf' {
        Mock -ModuleName AdminToolkit Test-ServiceState { @{ Exists = $true; Healthy = $false; Detail = 'Stopped'; Restarted = $false } }
        Mock -ModuleName AdminToolkit Restart-ServiceCrossPlatform { }
        $r = Test-ServiceHealth -Service Spooler -RestartFailed -WhatIf -WarningAction SilentlyContinue
        $r.Status | Should -Be 'Unhealthy'
        Should -Invoke -ModuleName AdminToolkit Restart-ServiceCrossPlatform -Times 0
    }
    It 'sends webhook and Telegram alerts only when something is unhealthy' {
        Mock -ModuleName AdminToolkit Test-TcpPort { @{ Open = $false; Detail = 'refused'; Ms = $null } }
        Mock -ModuleName AdminToolkit Invoke-RestMethod { }
        $env:ADMINTOOLKIT_TELEGRAM_TOKEN = 'test-token-not-real'
        try {
            Test-ServiceHealth -Port 'db01:1433' -WebhookUrl 'https://hooks.example/abc' -TelegramChatId 42 -WarningAction SilentlyContinue | Out-Null
        }
        finally { Remove-Item Env:ADMINTOOLKIT_TELEGRAM_TOKEN }
        Should -Invoke -ModuleName AdminToolkit Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -eq 'https://hooks.example/abc' -and $Body -match 'db01:1433' }
        Should -Invoke -ModuleName AdminToolkit Invoke-RestMethod -Times 1 -ParameterFilter { $Uri -like 'https://api.telegram.org/bot*/sendMessage' }
    }
    It 'skips Telegram when the token env var is missing' {
        Mock -ModuleName AdminToolkit Test-TcpPort { @{ Open = $false; Detail = 'refused'; Ms = $null } }
        Mock -ModuleName AdminToolkit Invoke-RestMethod { }
        Test-ServiceHealth -Port 'db01:1433' -TelegramChatId 42 -TelegramTokenEnvVar 'NOPE_NOT_SET' -WarningAction SilentlyContinue | Out-Null
        Should -Invoke -ModuleName AdminToolkit Invoke-RestMethod -Times 0
    }
    It 'checks a real Windows service' -Skip:(-not ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows)) {
        (Test-ServiceHealth -Service 'EventLog').Status | Should -Be 'Healthy'
    }
}

Describe 'Module quality' {
    It 'exports every public function with comment-based help and examples' {
        $cmds = Get-Command -Module AdminToolkit
        $cmds.Count | Should -Be 8
        foreach ($c in $cmds) {
            $help = Get-Help $c.Name -Full
            $help.Synopsis | Should -Not -Match '^\s*$' -Because "$($c.Name) needs a synopsis"
            @($help.Examples.Example).Count | Should -BeGreaterThan 0 -Because "$($c.Name) needs examples"
        }
    }
    It 'supports -WhatIf on every state-changing command' {
        foreach ($n in 'New-BulkADUser', 'Remove-ADUserOffboard', 'Reset-UserPassword', 'Invoke-DiskCleanup', 'Test-ServiceHealth') {
            (Get-Command $n).Parameters.Keys | Should -Contain 'WhatIf'
        }
    }
}
