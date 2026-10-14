function Write-AdminLog {
    <#
    .SYNOPSIS
        Writes a structured (JSON Lines) log entry for auditing admin actions.

    .DESCRIPTION
        Each call appends one JSON object per line with a UTC timestamp, level, the
        calling function, host, user, message and optional data. JSON Lines files are
        easy to grep, ship to a SIEM, or load back with
        Get-Content log.jsonl | ConvertFrom-Json.

        The log path is resolved in this order: -Path, $env:ADMINTOOLKIT_LOG, then
        <temp>/AdminToolkit/AdminToolkit-<yyyyMMdd>.jsonl.

    .PARAMETER Message
        Human readable message.

    .PARAMETER Level
        Debug, Info, Warning or Error. Warning and Error are also sent to the
        matching PowerShell stream.

    .PARAMETER Data
        Optional hashtable of extra fields (never put passwords or tokens here).

    .PARAMETER Path
        Log file path override.

    .PARAMETER PassThru
        Return the log entry object.

    .EXAMPLE
        Write-AdminLog -Message 'Created user' -Data @{ SamAccountName = 'jdoe' }

    .EXAMPLE
        Get-Content $env:ADMINTOOLKIT_LOG | ConvertFrom-Json | Where-Object Level -eq 'Error'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')][string]$Level = 'Info',
        [hashtable]$Data,
        [string]$Path,
        [switch]$PassThru
    )

    if (-not $Path) { $Path = $env:ADMINTOOLKIT_LOG }
    if (-not $Path) {
        $Path = Join-Path ([IO.Path]::GetTempPath()) ("AdminToolkit/AdminToolkit-{0:yyyyMMdd}.jsonl" -f (Get-Date))
    }

    $caller = (Get-PSCallStack | Select-Object -Skip 1 -First 1).Command
    $entry = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        level     = $Level
        source    = $caller
        host      = [Environment]::MachineName
        user      = [Environment]::UserName
        message   = $Message
    }
    if ($Data) { $entry['data'] = $Data }

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
    }
    $line = $entry | ConvertTo-Json -Compress -Depth 5
    # -WhatIf must never suppress the audit trail.
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8 -WhatIf:$false

    switch ($Level) {
        'Warning' { Write-Warning $Message }
        'Error' { Write-Error -Message $Message -ErrorAction Continue }
        default { Write-Verbose "[$Level] $Message" }
    }
    if ($PassThru) { [pscustomobject]$entry }
}
