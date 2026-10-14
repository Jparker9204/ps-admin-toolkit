BeforeAll { . (Join-Path $PSScriptRoot 'TestHelpers.ps1') }

Describe 'New-BulkADUser' {
    BeforeAll { $csv = Join-Path $Samples 'new-hires.csv' }

    Context '-Simulate (no AD required)' {
        BeforeAll {
            Mock -ModuleName AdminToolkit Test-ADModuleAvailable { $false }
            Mock -ModuleName AdminToolkit New-ADUser { throw 'must not be called' }
            $report = Join-Path $TestDrive 'onboard.csv'
            $result = New-BulkADUser -Path $csv -UpnSuffix contoso.com -Simulate -ReportPath $report
        }
        It 'returns one row per CSV line' { $result.Count | Should -Be 5 }
        It 'numbers a colliding account name (jsmith already exists)' {
            ($result | Where-Object DisplayName -eq 'James Smith').SamAccountName | Should -Be 'jsmith2'
        }
        It 'strips accents from account names' {
            ($result | Where-Object DisplayName -like 'Chlo*').SamAccountName | Should -Be 'cdubois'
        }
        It 'skips rows missing required fields' {
            ($result | Where-Object Status -eq 'Skipped').Message | Should -Match 'FirstName'
        }
        It 'uses the OU from the CSV when given' {
            ($result | Where-Object SamAccountName -eq 'jsmith2').OU | Should -Be 'OU=IT,OU=Staff,DC=contoso,DC=com'
        }
        It 'writes a report without passwords' {
            $report | Should -Exist
            (Get-Content $report -Raw) | Should -Not -Match 'Password'
        }
        It 'never calls New-ADUser' { Should -Invoke -ModuleName AdminToolkit New-ADUser -Times 0 }
    }

    Context 'against AD (mocked)' {
        BeforeAll {
            Mock -ModuleName AdminToolkit Test-ADModuleAvailable { $true }
            Mock -ModuleName AdminToolkit Import-Module { }
            Mock -ModuleName AdminToolkit Get-ADUser { if ($Filter -match "'msmith'") { [pscustomobject]@{ SamAccountName = 'msmith' } } }
            Mock -ModuleName AdminToolkit New-ADUser { }
            Mock -ModuleName AdminToolkit Add-ADGroupMember { }
            $one = Join-Path $TestDrive 'one.csv'
            "FirstName,LastName,Department,Groups`nMike,Smith,IT,IT-Helpdesk;VPN-Users" | Set-Content $one
        }
        It 'creates the user with a SecureString password and change-at-logon' {
            $r = New-BulkADUser -Path $one -UpnSuffix contoso.com -ReportPath (Join-Path $TestDrive 'r.csv') -Confirm:$false
            $r.Status | Should -Be 'Created'
            $r.SamAccountName | Should -Be 'msmith2'
            $r.InitialPassword | Should -BeOfType [securestring]
            Should -Invoke -ModuleName AdminToolkit New-ADUser -Times 1 -ParameterFilter {
                $ChangePasswordAtLogon -and $AccountPassword -is [securestring] -and $Department -eq 'IT' -and -not $Enabled
            }
            Should -Invoke -ModuleName AdminToolkit Add-ADGroupMember -Times 2
        }
        It 'honours -WhatIf' {
            $r = New-BulkADUser -Path $one -UpnSuffix contoso.com -ReportPath (Join-Path $TestDrive 'w.csv') -WhatIf
            $r.Status | Should -Be 'WhatIf'
            Should -Invoke -ModuleName AdminToolkit New-ADUser -Times 0 -Scope It
        }
        It 'reports Failed instead of throwing when AD errors' {
            Mock -ModuleName AdminToolkit New-ADUser { throw 'Access is denied' }
            $r = New-BulkADUser -Path $one -UpnSuffix contoso.com -ReportPath (Join-Path $TestDrive 'f.csv') -Confirm:$false -WarningAction SilentlyContinue
            $r.Status | Should -Be 'Failed'
            $r.Message | Should -Match 'Access is denied'
        }
    }

    It 'throws a helpful error when AD is missing and -Simulate is not used' {
        Mock -ModuleName AdminToolkit Test-ADModuleAvailable { $false }
        { New-BulkADUser -Path $csv -UpnSuffix contoso.com -WhatIf } | Should -Throw '*-Simulate*'
    }
}

Describe 'Remove-ADUserOffboard' {
    BeforeAll { $csv = Join-Path $Samples 'offboard.csv' }

    It 'simulates offboarding and reports missing users' {
        $r = Remove-ADUserOffboard -Path $csv -Simulate -ReportPath (Join-Path $TestDrive 'o.csv') -WarningAction SilentlyContinue
        ($r | Where-Object SamAccountName -eq 'bjohnson').GroupsRemoved | Should -Be 'Finance-Staff;VPN-Users;SharePoint-Finance'
        ($r | Where-Object SamAccountName -eq 'zz-notreal').Status | Should -Be 'Failed'
        ($r | Where-Object SamAccountName -eq 'bjohnson').Description | Should -Match 'INC-20431'
    }

    Context 'against AD (mocked)' {
        BeforeAll {
            Mock -ModuleName AdminToolkit Test-ADModuleAvailable { $true }
            Mock -ModuleName AdminToolkit Import-Module { }
            Mock -ModuleName AdminToolkit Get-ADUser {
                [pscustomobject]@{ SamAccountName = $Identity; DisplayName = 'Bob Johnson'; Enabled = $true
                    DistinguishedName = 'CN=Bob Johnson,OU=Staff,DC=contoso,DC=com'
                    MemberOf = @('CN=Finance-Staff,OU=Groups,DC=contoso,DC=com', 'CN=VPN-Users,OU=Groups,DC=contoso,DC=com') }
            }
            Mock -ModuleName AdminToolkit Disable-ADAccount { }
            Mock -ModuleName AdminToolkit Remove-ADGroupMember { }
            Mock -ModuleName AdminToolkit Set-ADUser { }
            Mock -ModuleName AdminToolkit Move-ADObject { }
            $one = Join-Path $TestDrive 'one.csv'
            "SamAccountName,Reason,TicketId`nbjohnson,Resigned,INC-1" | Set-Content $one
        }
        It 'disables, removes groups, stamps and moves the account' {
            $r = Remove-ADUserOffboard -Path $one -DisabledOU 'OU=Disabled,DC=contoso,DC=com' -ReportPath (Join-Path $TestDrive 'r.csv') -Confirm:$false
            $r.Status | Should -Be 'Offboarded'
            $r.GroupsRemoved | Should -Be 'Finance-Staff;VPN-Users'
            Should -Invoke -ModuleName AdminToolkit Disable-ADAccount -Times 1
            Should -Invoke -ModuleName AdminToolkit Remove-ADGroupMember -Times 2
            Should -Invoke -ModuleName AdminToolkit Move-ADObject -Times 1 -ParameterFilter { $TargetPath -eq 'OU=Disabled,DC=contoso,DC=com' }
        }
        It 'makes no changes with -WhatIf' {
            $r = Remove-ADUserOffboard -Path $one -ReportPath (Join-Path $TestDrive 'w.csv') -WhatIf
            $r.Status | Should -Be 'WhatIf'
            Should -Invoke -ModuleName AdminToolkit Disable-ADAccount -Times 0 -Scope It
        }
    }
}
