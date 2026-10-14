function Reset-UserPassword {
    <#
    .SYNOPSIS
        Help desk password reset: sets a new (generated) password, optionally unlocks, forces change at logon.

    .DESCRIPTION
        Resets an AD user's password to a supplied SecureString or a newly generated
        16-character password, unlocks the account with -Unlock, and requires a
        change at next logon (default). The generated password is returned as a
        SecureString; use -ShowPassword to display it once so it can be read to the
        verified caller. Passwords are never logged.

        In -Simulate mode the user is validated against the simulated directory and
        a password is generated, but nothing is changed.

    .PARAMETER Identity
        sAMAccountName of the user. Accepts pipeline input.

    .PARAMETER NewPassword
        Optional SecureString; a random one is generated when omitted.

    .PARAMETER Unlock
        Also unlock the account.

    .PARAMETER MustChangePasswordAtLogon
        Require the user to change it at next logon (default $true).

    .PARAMETER ShowPassword
        Include the plain-text password in the output (for reading to the caller). Use with care.

    .PARAMETER Simulate
        Validate against samples/simulated-directory.csv; make no changes.

    .EXAMPLE
        Reset-UserPassword -Identity jdoe -Unlock -ShowPassword

    .EXAMPLE
        'jdoe','asmith' | Reset-UserPassword -Simulate
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)][Alias('SamAccountName')][string]$Identity,
        [securestring]$NewPassword,
        [switch]$Unlock,
        [bool]$MustChangePasswordAtLogon = $true,
        [switch]$ShowPassword,
        [switch]$Simulate,
        [string]$SimulatedDirectoryPath
    )
    begin {
        Assert-DirectoryBackend -Simulate:$Simulate
        $directory = @{}
        if ($Simulate) {
            $dirArgs = @{}
            if ($SimulatedDirectoryPath) { $dirArgs.Path = $SimulatedDirectoryPath }
            foreach ($u in (Get-SimulatedDirectory @dirArgs)) { $directory[$u.SamAccountName] = $u }
        }
    }
    process {
        $password = if ($NewPassword) { $NewPassword } else { Get-RandomPassword }
        $result = [pscustomobject]@{
            SamAccountName = $Identity; Status = $null; Unlocked = $false
            MustChangeAtLogon = $MustChangePasswordAtLogon; Message = $null; Password = $password
        }
        try {
            if ($Simulate) {
                if (-not $directory.ContainsKey($Identity)) { throw "User '$Identity' not found in simulated directory" }
                $result.Status = 'Simulated'; $result.Unlocked = [bool]$Unlock
                $result.Message = 'Password would be reset'
            }
            elseif ($PSCmdlet.ShouldProcess($Identity, 'Reset password')) {
                Set-ADAccountPassword -Identity $Identity -Reset -NewPassword $password -ErrorAction Stop
                if ($MustChangePasswordAtLogon) { Set-ADUser -Identity $Identity -ChangePasswordAtLogon $true -ErrorAction Stop }
                if ($Unlock) { Unlock-ADAccount -Identity $Identity -ErrorAction Stop; $result.Unlocked = $true }
                $result.Status = 'Reset'; $result.Message = 'Password reset'
            }
            else {
                $result.Status = 'WhatIf'; $result.Message = 'No changes made'
            }
            Write-AdminLog -Message "Password reset ($($result.Status)) for $Identity" -Data @{ unlock = [bool]$Unlock }
        }
        catch {
            $result.Status = 'Failed'; $result.Message = $_.Exception.Message
            Write-AdminLog -Level Warning -Message "Password reset failed for ${Identity}: $($_.Exception.Message)"
        }
        if ($ShowPassword -and $result.Status -in 'Reset', 'Simulated') {
            $plain = [System.Net.NetworkCredential]::new('', $password).Password
            $result | Add-Member -NotePropertyName PlainTextPassword -NotePropertyValue $plain
        }
        $result
    }
}
