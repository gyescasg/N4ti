$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'opencode') ('n4ti-ranking-' + [guid]::NewGuid().ToString('N'))
$failures = @()
$filler = ('lorem ipsum dolor sit amet ' * 40).Trim()

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
function Add-Document([string]$Root, [string]$Id, [string]$Content) {
    $relativePath = "N4ti/knowledge/$Id.md"
    [IO.File]::WriteAllText((Join-Path $Root $relativePath), $Content, [Text.UTF8Encoding]::new($false))
    $catalogPath = Join-Path $Root 'N4ti/catalog.json'
    $catalog = Get-Content $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $catalog.documents = @($catalog.documents) + [pscustomobject]@{
        id = $Id; level = 3; type = 'knowledge'; status = 'active'; priority = 'normal'
        tags = @(); affects = @(); path = $relativePath; alwaysLoad = $false
    }
    [IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
}
function Context([string]$Root, [string]$Query) {
    $result = Run-Cli $Root @('context', '-Query', $Query)
    Assert-True ($result.Code -eq 0) $result.Text
    return Get-Content (Join-Path $Root 'N4ti/.runtime/context-pack.md') -Raw -Encoding UTF8
}
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS: $Name" }
    catch { $script:failures += "$Name`: $($_.Exception.Message)"; Write-Host "FAIL: $($script:failures[-1])" }
}

try {
    Check 'a term shared by every section does not admit the whole document' {
        $root = Fixture 'common'
        $sections = foreach ($name in @('Login', 'Facturacion', 'Reportes', 'Despliegue')) { "## $name`n`nReglas del modulo $($name.ToLower()). $filler" }
        Add-Document $root 'MANUAL' ("# Manual`n`n" + ($sections -join "`n`n"))
        $pack = Context $root 'reglas facturacion'
        Assert-True ($pack.Contains('## MANUAL#facturacion |')) 'Specific section missing'
        foreach ($other in @('login', 'reportes', 'despliegue')) {
            Assert-True (-not $pack.Contains("## MANUAL#$other |")) "Weak section admitted: $other"
            Assert-True ($pack -match "(?m)^- MANUAL#$other \| \d+ tokens") "Weak section not indexed: $other"
        }
    }
    Check 'rare terms outrank common terms in search' {
        $root = Fixture 'idf'
        Add-Document $root 'AAA_COMMON' "# One`n`nshared text."
        Add-Document $root 'BBB_COMMON' "# Two`n`nshared text."
        Add-Document $root 'CCC_COMMON' "# Three`n`nshared text."
        Add-Document $root 'ZZZ_RARE' "# Four`n`nunusual text."
        $result = Run-Cli $root @('search', '-Query', 'shared unusual')
        Assert-True ($result.Code -eq 0) $result.Text
        Assert-True ($result.Text.IndexOf('ZZZ_RARE') -lt $result.Text.IndexOf('AAA_COMMON')) 'Common term ranked above rare term'
    }
    Check 'equally relevant documents are all included' {
        $root = Fixture 'equal'
        Add-Document $root 'FIRST' "# First`n`nneedle evidence one."
        Add-Document $root 'SECOND' "# Second`n`nneedle evidence two."
        $pack = Context $root 'needle'
        Assert-True ($pack.Contains('## FIRST |') -and $pack.Contains('## SECOND |')) 'Equally relevant document dropped'
    }
} finally { if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force } }
if ($failures.Count) { throw "$($failures.Count) ranking checks failed: $($failures -join '; ')" }
Write-Host 'All 3 N4ti ranking checks passed'
