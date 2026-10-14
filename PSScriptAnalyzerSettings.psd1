@{
    Severity     = @('Error', 'Warning')
    IncludeDefaultRules = $true
    ExcludeRules = @(
        # Console output in examples/scripts is intentional; the module itself does not use Write-Host.
        'PSAvoidUsingWriteHost'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
        PSPlaceOpenBrace      = @{ Enable = $true; OnSameLine = $true; NewLineAfter = $true; IgnoreOneLineBlock = $true }
        PSUseConsistentIndentation = @{ Enable = $true; IndentationSize = 4; Kind = 'space' }
    }
}
