# Compatibility entrypoint: both names use one implementation and memory store.
& (Join-Path $PSScriptRoot 'gy.ps1') @args
if (-not $?) { exit 1 }
