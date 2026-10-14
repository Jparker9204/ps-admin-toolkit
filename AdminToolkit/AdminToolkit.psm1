#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:ModuleRoot = $PSScriptRoot
$script:SampleRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'samples'

foreach ($folder in 'Private', 'Public') {
    $path = Join-Path $PSScriptRoot $folder
    foreach ($file in (Get-ChildItem -Path $path -Filter '*.ps1' -File | Sort-Object Name)) {
        . $file.FullName
    }
}

$public = Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File |
    ForEach-Object { $_.BaseName }
Export-ModuleMember -Function $public
