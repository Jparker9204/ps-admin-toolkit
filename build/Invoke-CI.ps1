<#
.SYNOPSIS
    Runs PSScriptAnalyzer and Pester exactly like CI does. Usage: ./build/Invoke-CI.ps1
#>
[CmdletBinding()]
param([switch]$SkipAnalyzer, [string]$TestResultPath = (Join-Path $PSScriptRoot '../testResults.xml'))
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

if (-not $SkipAnalyzer) {
    Import-Module PSScriptAnalyzer
    $issues = Invoke-ScriptAnalyzer -Path (Join-Path $root 'AdminToolkit') -Recurse -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1')
    $issues | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap
    "PSScriptAnalyzer: $(@($issues).Count) issue(s)"
    if ($issues) { throw 'PSScriptAnalyzer found issues' }
}

Import-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99
$config = New-PesterConfiguration
$config.Run.Path = Join-Path $root 'tests'
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath = $TestResultPath
Invoke-Pester -Configuration $config
