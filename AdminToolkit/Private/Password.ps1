function Get-RandomPassword {
    <#
    .SYNOPSIS
        Generates a random password as a SecureString using a cryptographic RNG.
    .DESCRIPTION
        Guarantees at least one upper, lower, digit and symbol. Ambiguous characters
        (0/O, 1/l/I) are excluded so it can be read over the phone by the help desk.
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param([ValidateRange(12, 128)][int]$Length = 16)

    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!@#$%^&*-_=+?'
    )
    $all = -join $sets
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $next = {
            param([int]$max)
            $bytes = New-Object byte[] 4
            $rng.GetBytes($bytes)
            [int]([BitConverter]::ToUInt32($bytes, 0) % [uint32]$max)
        }
        $chars = New-Object System.Collections.Generic.List[char]
        foreach ($set in $sets) { $chars.Add($set[(& $next $set.Length)]) }
        while ($chars.Count -lt $Length) { $chars.Add($all[(& $next $all.Length)]) }
        # Fisher-Yates shuffle so the guaranteed characters are not always first.
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $j = & $next ($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        $secure = New-Object System.Security.SecureString
        foreach ($c in $chars) { $secure.AppendChar($c) }
        $secure.MakeReadOnly()
        return $secure
    }
    finally {
        $rng.Dispose()
    }
}
