function ConvertTo-HealthRow {
    [CmdletBinding()]
    param($Type, $Target, $Status, $Detail, $Ms)
    [pscustomobject]@{
        Type = $Type; Target = $Target; Status = $Status; Detail = $Detail
        ResponseMs = $Ms; CheckedAt = (Get-Date).ToString('s')
    }
}

function Test-ServiceState {
    <#
    .SYNOPSIS
        Returns @{ Exists; Healthy; Detail } for a service on Windows (Get-Service) or Linux (systemctl).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $out = @{ Exists = $false; Healthy = $false; Detail = $null; Restarted = $false }
    if (Test-IsWindowsHost) {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if (-not $svc) { $out.Detail = 'Service not found'; return $out }
        $out.Exists = $true
        $out.Healthy = ($svc.Status -eq 'Running')
        $out.Detail = "$($svc.Status) (StartType: $($svc.StartType))"
        return $out
    }
    if (-not (Get-Command systemctl -ErrorAction SilentlyContinue)) {
        $out.Detail = 'systemctl not available on this host'; return $out
    }
    $state = (& systemctl is-active $Name 2>$null | Select-Object -First 1)
    if (-not $state) { $state = 'unknown' }
    & systemctl cat $Name *> $null
    $out.Exists = ($LASTEXITCODE -eq 0)
    if (-not $out.Exists) { $state = 'not-found' }
    $out.Healthy = ($state -eq 'active')
    $out.Detail = "systemd: $state"
    return $out
}

function Restart-ServiceCrossPlatform {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name)
    if (-not $PSCmdlet.ShouldProcess($Name, 'Restart')) { return }
    if (Test-IsWindowsHost) { Restart-Service -Name $Name -Force -ErrorAction Stop -Confirm:$false }
    else {
        & sudo -n systemctl restart $Name 2>&1 | Out-Null
        if ($LASTEXITCODE) { throw "systemctl restart $Name exited $LASTEXITCODE" }
    }
}

function Test-TcpPort {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ComputerName, [Parameter(Mandatory)][int]$Port, [int]$TimeoutSeconds = 5)
    $client = New-Object System.Net.Sockets.TcpClient
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $task = $client.ConnectAsync($ComputerName, $Port)
        $done = $task.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))
        $sw.Stop()
        if ($done -and $client.Connected) { return @{ Open = $true; Detail = 'TCP connect OK'; Ms = $sw.ElapsedMilliseconds } }
        return @{ Open = $false; Detail = "Timed out after ${TimeoutSeconds}s"; Ms = $null }
    }
    catch {
        $msg = $_.Exception.GetBaseException().Message
        return @{ Open = $false; Detail = $msg; Ms = $null }
    }
    finally { $client.Dispose() }
}

function Test-HttpEndpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri, [int]$TimeoutSeconds = 5)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSeconds -MaximumRedirection 5 -ErrorAction Stop
        $sw.Stop()
        $code = [int]$resp.StatusCode
        return @{ Healthy = ($code -lt 400); Detail = "HTTP $code"; Ms = $sw.ElapsedMilliseconds }
    }
    catch {
        $sw.Stop()
        $code = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        $detail = if ($code) { "HTTP $code" } else { $_.Exception.GetBaseException().Message }
        return @{ Healthy = $false; Detail = $detail; Ms = $sw.ElapsedMilliseconds }
    }
}

function Send-HealthAlert {
    <#
    .SYNOPSIS
        Posts an alert to a webhook and/or Telegram. Failures are logged, never thrown.
    #>
    [CmdletBinding()]
    param([string]$Text, [string]$WebhookUrl, [string]$TelegramChatId, [string]$TelegramTokenEnvVar = 'ADMINTOOLKIT_TELEGRAM_TOKEN')
    if ($WebhookUrl) {
        try {
            $body = @{ text = $Text; content = $Text } | ConvertTo-Json
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType 'application/json' -Body $body -ErrorAction Stop | Out-Null
            Write-AdminLog -Message 'Webhook alert sent'
        }
        catch { Write-AdminLog -Level Warning -Message "Webhook alert failed: $($_.Exception.Message)" }
    }
    if ($TelegramChatId) {
        $token = [Environment]::GetEnvironmentVariable($TelegramTokenEnvVar)
        if (-not $token) {
            Write-AdminLog -Level Warning -Message "Telegram alert skipped: env var $TelegramTokenEnvVar is not set"
            return
        }
        try {
            $body = @{ chat_id = $TelegramChatId; text = $Text; disable_web_page_preview = $true } | ConvertTo-Json
            Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post -ContentType 'application/json' -Body $body -ErrorAction Stop | Out-Null
            Write-AdminLog -Message 'Telegram alert sent' -Data @{ chatId = $TelegramChatId }
        }
        catch {
            # Never log the URL: it contains the token.
            Write-AdminLog -Level Warning -Message 'Telegram alert failed (check token/chat id)'
        }
    }
}
