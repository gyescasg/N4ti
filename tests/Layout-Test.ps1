$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'opencode') ('n4ti-layout-' + [guid]::NewGuid().ToString('N'))
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
function Context-Pack([string]$Root, [string]$Query) {
    $result = Run-Cli $Root @('context', '-Query', $Query)
    Assert-True ($result.Code -eq 0) $result.Text
    return Get-Content (Join-Path $Root 'N4ti/.runtime/context-pack.md') -Raw -Encoding UTF8
}
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS: $Name" }
    catch { $script:failures += "$Name`: $($_.Exception.Message)"; Write-Host "FAIL: $($script:failures[-1])" }
}

try {
    Check 'installed protocol does not load mandatory documents twice' {
        $root = Fixture 'protocol'
        foreach ($file in @('AGENTS.md', 'CLAUDE.md')) {
            $text = Get-Content (Join-Path $root $file) -Raw -Encoding UTF8
            Assert-True (-not $text.Contains('Read `N4ti/core.md`')) "$file still asks to read core.md separately"
            Assert-True ($text.Contains('already contains core, current state and mandatory policies')) "$file does not state the pack is sufficient"
        }
    }
    Check 'packs for different requests share every mandatory document as a stable prefix' {
        $root = Fixture 'prefix'
        Add-Document $root 'ALPHA' "# alpha`n`nAlpha details."
        Add-Document $root 'BETA' "# beta`n`nBeta details."
        $alpha = Context-Pack $root 'alpha'
        $beta = Context-Pack $root 'beta'
        $lastRequired = $alpha.IndexOf('## STATE |')
        Assert-True ($lastRequired -gt 0) 'STATE missing from pack'
        $end = $alpha.IndexOf("`r`n---", $lastRequired)
        Assert-True ($end -gt 0 -and $alpha.Substring(0, $end) -eq $beta.Substring(0, $end)) 'Mandatory section differs between requests'
        foreach ($volatile in @('- Query:', 'Estimated tokens:', '- Documents:')) {
            Assert-True ($alpha.IndexOf($volatile) -gt $alpha.IndexOf('## ALPHA |')) "$volatile appears before request content"
        }
        Assert-True (-not $alpha.Contains('- Generated:')) 'Timestamp still present'
    }
    Check 'assigned task follows mandatory documents in task packets' {
        $root = Fixture 'task'
        $created = Run-Cli $root @('new-task', '-Title', 'Layout task', '-Tags', 'layout')
        Assert-True ($created.Code -eq 0) $created.Text
        $result = Run-Cli $root @('task-packet', '-Id', 'TASK-001', '-Agent', 'implementer')
        Assert-True ($result.Code -eq 0) $result.Text
        $packet = Get-Content (Join-Path $root 'N4ti/.runtime/packets/TASK-001-implementer.md') -Raw -Encoding UTF8
        Assert-True ($packet.StartsWith('# N4ti Subagent Task Packet')) 'Packet title changed'
        $task = $packet.IndexOf('## TASK-001 |')
        Assert-True ($task -gt $packet.IndexOf('## STATE |') -and $task -lt $packet.IndexOf('## Contract')) 'Task is not between mandatory documents and contract'
    }
} finally { if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force } }
if ($failures.Count) { throw "$($failures.Count) layout checks failed: $($failures -join '; ')" }
Write-Host 'All 3 N4ti layout checks passed'
