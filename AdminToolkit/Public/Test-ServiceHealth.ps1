function Test-ServiceHealth {
    <#
    .SYNOPSIS
        Checks services, TCP ports and URLs, optionally restarts failed services and sends an alert.

    .DESCRIPTION
        Runs three kinds of checks and returns one status row per target:

          * Service - Windows: Get-Service; Linux: systemctl is-active
          * Port    - TCP connect to host:port with a timeout (e.g. dc01:389, sql01:1433)
          * Url     - HTTP(S) GET; healthy when the status code is below 400

        Checks can be passed as parameters or in a JSON file (see samples/health-checks.json).
        With -RestartFailed, stopped services are restarted (honours -WhatIf/-Confirm) and
        re-checked. When anything is unhealthy an alert can be posted to a generic webhook
        (Teams/Slack/Discord-style JSON { "text": ... }) and/or Telegram. The Telegram bot
        token is read from an environment variable, never from a parameter, so it does not
        end up in shell history or scheduled task definitions.

    .PARAMETER Service
        Service names to check.

    .PARAMETER Port
        host:port targets.

    .PARAMETER Url
        URLs to request.

    .PARAMETER ConfigPath
        JSON file with "services", "ports" and "urls" arrays (merged with parameters).

    .PARAMETER TimeoutSeconds
        Port/URL timeout (default 5).

    .PARAMETER RestartFailed
        Restart services that are not running.

    .PARAMETER WebhookUrl
        POST a JSON alert here when a check fails.

    .PARAMETER TelegramChatId
        Telegram chat id for alerts. Requires the token in -TelegramTokenEnvVar.

    .PARAMETER TelegramTokenEnvVar
        Name of the env var holding the Telegram bot token (default ADMINTOOLKIT_TELEGRAM_TOKEN).

    .EXAMPLE
        Test-ServiceHealth -Service Spooler, W32Time -Port 'dc01:389' -Url 'https://intranet.contoso.com' | Format-Table

    .EXAMPLE
        $env:ADMINTOOLKIT_TELEGRAM_TOKEN = '<from your secret store>'
        Test-ServiceHealth -ConfigPath .\samples\health-checks.json -RestartFailed -TelegramChatId 123456789

    .OUTPUTS
        PSCustomObject: Type, Target, Status (Healthy / Unhealthy / Restarted), Detail, ResponseMs, CheckedAt.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [string[]]$Service = @(),
        [string[]]$Port = @(),
        [string[]]$Url = @(),
        [string]$ConfigPath,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 5,
        [switch]$RestartFailed,
        [string]$WebhookUrl,
        [string]$TelegramChatId,
        [string]$TelegramTokenEnvVar = 'ADMINTOOLKIT_TELEGRAM_TOKEN'
    )

    if ($ConfigPath) {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        if ($cfg.PSObject.Properties['services']) { $Service += @($cfg.services) }
        if ($cfg.PSObject.Properties['ports']) { $Port += @($cfg.ports) }
        if ($cfg.PSObject.Properties['urls']) { $Url += @($cfg.urls) }
    }
    if (-not ($Service.Count + $Port.Count + $Url.Count)) {
        throw 'Nothing to check. Pass -Service, -Port, -Url or -ConfigPath.'
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($name in $Service) {
        $check = Test-ServiceState -Name $name
        if (-not $check.Healthy -and $RestartFailed -and $check.Exists) {
            if ($PSCmdlet.ShouldProcess($name, 'Restart service')) {
                try {
                    Restart-ServiceCrossPlatform -Name $name -Confirm:$false
                    Start-Sleep -Seconds 2
                    $re = Test-ServiceState -Name $name
                    if ($re.Healthy) { $check = $re; $check.Detail = "Restarted; now $($re.Detail)"; $check.Restarted = $true }
                    else { $check.Detail = "Restart attempted; still $($re.Detail)" }
                }
                catch { $check.Detail = "Restart failed: $($_.Exception.Message)" }
            }
        }
        $status = if ($check.Restarted) { 'Restarted' } elseif ($check.Healthy) { 'Healthy' } else { 'Unhealthy' }
        $results.Add((ConvertTo-HealthRow -Type Service -Target $name -Status $status -Detail $check.Detail -Ms $null))
    }
    foreach ($p in $Port) {
        $hostName, $portNum = $p -split ':(?=\d+$)'
        $res = Test-TcpPort -ComputerName $hostName -Port ([int]$portNum) -TimeoutSeconds $TimeoutSeconds
        $results.Add((ConvertTo-HealthRow -Type Port -Target $p -Status $(if ($res.Open) { 'Healthy' } else { 'Unhealthy' }) -Detail $res.Detail -Ms $res.Ms))
    }
    foreach ($u in $Url) {
        $res = Test-HttpEndpoint -Uri $u -TimeoutSeconds $TimeoutSeconds
        $results.Add((ConvertTo-HealthRow -Type Url -Target $u -Status $(if ($res.Healthy) { 'Healthy' } else { 'Unhealthy' }) -Detail $res.Detail -Ms $res.Ms))
    }

    $bad = @($results | Where-Object Status -eq 'Unhealthy')
    $msgData = @{ total = $results.Count; unhealthy = $bad.Count }
    Write-AdminLog -Level $(if ($bad) { 'Warning' } else { 'Info' }) -Message "Health check: $($bad.Count) of $($results.Count) unhealthy" -Data $msgData -WarningAction SilentlyContinue

    if ($bad -and ($WebhookUrl -or $TelegramChatId)) {
        $lines = $bad | ForEach-Object { "- [$($_.Type)] $($_.Target): $($_.Detail)" }
        $text = "AdminToolkit health alert on $([Environment]::MachineName)`n$($bad.Count) of $($results.Count) checks unhealthy:`n$($lines -join "`n")"
        Send-HealthAlert -Text $text -WebhookUrl $WebhookUrl -TelegramChatId $TelegramChatId -TelegramTokenEnvVar $TelegramTokenEnvVar
    }
    $results.ToArray()
}
