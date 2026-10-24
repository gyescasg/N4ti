$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'opencode') ('n4ti-alias-' + [guid]::NewGuid().ToString('N'))
$failures = @()

function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Fixture([string]$Name) {
    $root = Join-Path $testRoot $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    & (Join-Path $packageRoot 'Install-N4ti.ps1') -ProjectPath $root | Out-Null
    return $root
}
function Run-Cli([string]$Root, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'gy.ps1') @Arguments 2>&1
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($output | Out-String) }
    } finally { $ErrorActionPreference = $previous }
}
function Edit-Catalog([string]$Root, [scriptblock]$Change) {
    $catalogPath = Join-Path $Root 'N4ti/catalog.json'
    $catalog = Get-Content $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    & $Change $catalog
    [IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
}
function Add-Document([string]$Root, [string]$Id, [string]$Content, [string[]]$Tags = @()) {
    $relativePath = "N4ti/knowledge/$Id.md"
    [IO.File]::WriteAllText((Join-Path $Root $relativePath), $Content, [Text.UTF8Encoding]::new($false))
    Edit-Catalog $Root {
        param($catalog)
        $catalog.documents = @($catalog.documents) + [pscustomobject]@{
            id = $Id; level = 3; type = 'knowledge'; status = 'active'; priority = 'normal'
            tags = $Tags; affects = @(); path = $relativePath; alwaysLoad = $false
        }
    }
}
function Pack-Documents([string]$Text) { return [regex]::Match($Text, 'Documents: ([^\r\n]+)').Groups[1].Value }
function Score([string]$Text, [string]$Id) {
    $line = ($Text -split "`r?`n") | Where-Object { $_ -match "^$([regex]::Escape($Id))\s" } | Select-Object -First 1
    Assert-True $line "Missing search row for $Id"
    return [int](($line -split '\s+')[4])
}
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS: $Name" }
    catch { $script:failures += "$Name`: $($_.Exception.Message)"; Write-Host "FAIL: $($script:failures[-1])" }
}

try {
    Check 'spanish queries reach english template tags through default aliases' {
        $root = Fixture 'template'
        $result = Run-Cli $root @('context', '-Query', 'arquitectura componentes')
        Assert-True ($result.Code -eq 0 -and (Pack-Documents $result.Text).Contains('ARCHITECTURE')) $result.Text
    }
    Check 'custom alias groups work both ways without extra score' {
        $root = Fixture 'custom'
        Add-Document $root 'BILLING' "# Billing`n`nMonthly totals." -Tags @('invoice')
        Edit-Catalog $root { param($catalog) $catalog | Add-Member -NotePropertyName aliases -NotePropertyValue @(, @('invoice', 'factura')) -Force }
        $spanish = Run-Cli $root @('search', '-Query', 'factura')
        $english = Run-Cli $root @('search', '-Query', 'invoice')
        Assert-True ($spanish.Code -eq 0 -and $english.Code -eq 0) "$($spanish.Text)$($english.Text)"
        Assert-True ((Score $spanish.Text 'BILLING') -eq (Score $english.Text 'BILLING')) 'Alias changed the score'
        $both = Run-Cli $root @('search', '-Query', 'invoice factura')
        Assert-True ((Score $both.Text 'BILLING') -eq (Score $english.Text 'BILLING')) 'Alias and original counted twice'
    }
    Check 'catalogs without aliases keep exact matching' {
        $root = Fixture 'legacy'
        Add-Document $root 'LEGACY' "# Legacy`n`nNeedle content."
        Edit-Catalog $root { param($catalog) $catalog.PSObject.Properties.Remove('aliases') }
        $result = Run-Cli $root @('context', '-Query', 'needle')
        Assert-True ($result.Code -eq 0 -and (Pack-Documents $result.Text).Contains('LEGACY')) $result.Text
    }
    Check 'invalid aliases fail before writing a pack' {
        $root = Fixture 'invalid'
        Edit-Catalog $root { param($catalog) $catalog | Add-Member -NotePropertyName aliases -NotePropertyValue 'bad' -Force }
        $result = Run-Cli $root @('context', '-Query', 'anything')
        Assert-True ($result.Code -ne 0 -and $result.Text.Contains('Invalid catalog aliases')) $result.Text
        Assert-True (-not (Test-Path (Join-Path $root 'N4ti/.runtime/context-pack.md'))) 'Pack written despite invalid aliases'
        $validate = Run-Cli $root @('validate')
        Assert-True ($validate.Code -ne 0 -and $validate.Text.Contains('Invalid catalog aliases')) $validate.Text
    }
} finally { if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force } }
if ($failures.Count) { throw "$($failures.Count) alias checks failed: $($failures -join '; ')" }
Write-Host 'All 4 N4ti alias checks passed'
