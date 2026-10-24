[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ProjectPath,
    [switch]$ForceTemplates
)
& (Join-Path $PSScriptRoot 'Install-GY.ps1') @PSBoundParameters
