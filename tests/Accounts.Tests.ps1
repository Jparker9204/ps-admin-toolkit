BeforeAll { . (Join-Path $PSScriptRoot 'TestHelpers.ps1') }

Describe 'Get-StaleAccounts' {
    BeforeAll { $asOf = [datetime]'2026-10-14' }

    It 'returns enabled accounts inactive for N+ days, plus never-logged-on' {
        $r = Get-StaleAccounts -Days 90 -AsOf $asOf -Simulate
        $r.SamAccountName | Should -Be @('temp-intern', 'svc-backup', 'tmiller', 'bjohnson')
    }
    It 'ignores disabled accounts' {
        (Get-StaleAccounts -Days 30 -AsOf $asOf -Simulate).SamAccountName | Should -Not -Contain 'rold'
    }
    It 'can exclude never-logged-on accounts' {
        (Get-StaleAccounts -Days 90 -AsOf $asOf -Simulate -IncludeNeverLoggedOn $false).SamAccountName | Should -Not -Contain 'temp-intern'
    }
    It 'computes DaysInactive' {
        (Get-StaleAccounts -Days 90 -AsOf $asOf -Simulate | Where-Object SamAccountName -eq 'tmiller').DaysInactive | Should -Be 182
    }
    It 'queries AD with LastLogonDate when not simulating' {
        Mock -ModuleName AdminToolkit Test-ADModuleAvailable { $true }
        Mock -ModuleName AdminToolkit Import-Module { }
        Mock -ModuleName AdminToolkit Get-ADUser {
            [pscustomobject]@{ SamAccountName = 'old'; DisplayName = 'Old'; Enabled = $true; Department = 'X'; LastLogonDate = $asOf.AddDays(-200) }
            [pscustomobject]@{ SamAccountName = 'new'; DisplayName = 'New'; Enabled = $true; Department = 'X'; LastLogonDate = $asOf.AddDays(-1) }
        }
        $r = Get-StaleAccounts -Days 90 -AsOf $asOf -SearchBase 'OU=Staff,DC=contoso,DC=com'
        $r.SamAccountName | Should -Be 'old'
        Should -Invoke -ModuleName AdminToolkit Get-ADUser -ParameterFilter { $Properties -contains 'LastLogonDate' -and $SearchBase -like 'OU=Staff*' }
    }
}

Describe 'Reset-UserPassword' {
    It 'simulates a reset for a known user and can show the generated password' {
        $r = Reset-UserPassword -Identity jsmith -Simulate -Unlock -ShowPassword
        $r.Status | Should -Be 'Simulated'
        $r.PlainTextPassword.Length | Should -Be 16
    }
    It 'fails cleanly for an unknown user' {
        (Reset-UserPassword -Identity nobody -Simulate -WarningAction SilentlyContinue).Status | Should -Be 'Failed'
    }
    It 'accepts pipeline input' {
        ('jsmith', 'dwright' | Reset-UserPassword -Simulate).Count | Should -Be 2
    }
    Context 'against AD (mocked)' {
        BeforeAll {
            Mock -ModuleName AdminToolkit Test-ADModuleAvailable { $true }
            Mock -ModuleName AdminToolkit Import-Module { }
            Mock -ModuleName AdminToolkit Set-ADAccountPassword { }
            Mock -ModuleName AdminToolkit Set-ADUser { }
            Mock -ModuleName AdminToolkit Unlock-ADAccount { }
        }
        It 'resets, forces change at logon and unlocks' {
            $r = Reset-UserPassword -Identity jdoe -Unlock -Confirm:$false
            $r.Status | Should -Be 'Reset'
            $r.PSObject.Properties['PlainTextPassword'] | Should -BeNullOrEmpty
            Should -Invoke -ModuleName AdminToolkit Set-ADAccountPassword -ParameterFilter { $Reset -and $NewPassword -is [securestring] }
            Should -Invoke -ModuleName AdminToolkit Set-ADUser -ParameterFilter { $ChangePasswordAtLogon }
            Should -Invoke -ModuleName AdminToolkit Unlock-ADAccount -Times 1
        }
        It 'does nothing with -WhatIf' {
            (Reset-UserPassword -Identity jdoe -WhatIf).Status | Should -Be 'WhatIf'
            Should -Invoke -ModuleName AdminToolkit Set-ADAccountPassword -Times 0 -Scope It
        }
    }
}

Describe 'Get-RandomPassword (private)' {
    It 'meets complexity and avoids ambiguous characters' {
        InModuleScope AdminToolkit {
            1..25 | ForEach-Object {
                $p = [System.Net.NetworkCredential]::new('', (Get-RandomPassword -Length 16)).Password
                $p.Length | Should -Be 16
                $p | Should -MatchExactly '[A-Z]'
                $p | Should -MatchExactly '[a-z]'
                $p | Should -Match '[0-9]'
                $p | Should -Match '[^A-Za-z0-9]'
                $p | Should -Not -MatchExactly '[0O1lI]'
            }
        }
    }
}

Describe 'Write-AdminLog' {
    It 'writes one JSON object per line with level, source and data' {
        $log = Join-Path $TestDrive 'log.jsonl'
        Write-AdminLog -Message 'first' -Path $log
        Write-AdminLog -Message 'second' -Level Warning -Data @{ ticket = 'INC-1' } -Path $log -WarningAction SilentlyContinue
        $lines = Get-Content $log
        $lines.Count | Should -Be 2
        $entry = $lines[1] | ConvertFrom-Json
        $entry.level | Should -Be 'Warning'
        $entry.data.ticket | Should -Be 'INC-1'
        { [datetime]::Parse($entry.timestamp) } | Should -Not -Throw
    }
    It 'still logs when -WhatIf is in effect' {
        $log = Join-Path $TestDrive 'whatif.jsonl'
        & { $WhatIfPreference = $true; Write-AdminLog -Message 'audit' -Path $log }
        $log | Should -Exist
    }
}
