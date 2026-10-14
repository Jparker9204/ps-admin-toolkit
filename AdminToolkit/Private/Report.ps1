function Export-ActionReport {
    <#
    .SYNOPSIS
        Writes result objects to CSV (default) or JSON based on the file extension.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
    }
    if ($Path -like '*.json') {
        ConvertTo-Json -InputObject @($InputObject) -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8 -WhatIf:$false
    }
    else {
        $InputObject | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    }
}

function ConvertTo-SafeAccountName {
    <#
    .SYNOPSIS
        Builds a lower-case sAMAccountName (first initial + last name, max 20 chars).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$FirstName, [Parameter(Mandatory)][string]$LastName)
    $raw = ($FirstName.Substring(0, 1) + $LastName).ToLowerInvariant()
    $clean = ($raw.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '') -replace '[^a-z0-9]', ''
    if ($clean.Length -gt 20) { $clean = $clean.Substring(0, 20) }
    return $clean
}
