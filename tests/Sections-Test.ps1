$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'opencode') ('n4ti-sections-' + [guid]::NewGuid().ToString('N'))
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
function Add-Document([string]$Root, [string]$Id, [string]$Content, [string[]]$Tags = @()) {
    $relativePath = "N4ti/knowledge/$Id.md"
    [IO.File]::WriteAllText((Join-Path $Root $relativePath), $Content, [Text.UTF8Encoding]::new($false))
    $catalogPath = Join-Path $Root 'N4ti/catalog.json'
    $catalog = Get-Content $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $catalog.documents = @($catalog.documents) + [pscustomobject]@{
        id = $Id; level = 3; type = 'knowledge'; status = 'active'; priority = 'normal'
        tags = $Tags; affects = @(); path = $relativePath; alwaysLoad = $false
    }
    [IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
}
function Guide([string]$Root, [string[]]$Tags = @()) {
    $content = "# Operations guide`n`n## Deploy`n`nUse kubernetes rollouts. $filler`n`n## Billing`n`nInvoices close monthly. $filler`n`n## Logging`n`nShip structured logs. $filler"
    Add-Document $Root 'GUIDE' $content $Tags
}
function Context([string]$Root, [string[]]$Extra) {
    $result = Run-Cli $Root (@('context') + $Extra)
    Assert-True ($result.Code -eq 0) $result.Text
    return Get-Content (Join-Path $Root 'N4ti/.runtime/context-pack.md') -Raw -Encoding UTF8
}
function Project-Hash([string]$Root) {
    return ((Get-ChildItem (Join-Path $Root 'N4ti') -File -Recurse | Sort-Object FullName |
        ForEach-Object { $_.FullName + ':' + (Get-FileHash $_.FullName).Hash }) -join "`n")
}
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS: $Name" }
    catch { $script:failures += "$Name`: $($_.Exception.Message)"; Write-Host "FAIL: $($script:failures[-1])" }
}

try {
    Check 'optional documents contribute only their matching sections' {
        $root = Fixture 'partial'
        Guide $root
        $pack = Context $root @('-Query', 'kubernetes')
        Assert-True ($pack.Contains('## GUIDE#deploy | L3 | N4ti/knowledge/GUIDE.md')) 'Deploy section missing'
        Assert-True (-not $pack.Contains('Invoices close monthly') -and -not $pack.Contains('Ship structured logs')) 'Unrelated sections loaded'
        Assert-True ($pack -match '- Documents: [^\r\n]*GUIDE#deploy') 'Section ID missing from document list'
    }
    Check 'documents matched by metadata stay one whole block' {
        $root = Fixture 'whole'
        Guide $root @('operations')
        $pack = Context $root @('-Query', 'operations')
        Assert-True ($pack.Contains('## GUIDE | L3 | N4ti/knowledge/GUIDE.md') -and -not $pack.Contains('GUIDE#')) 'Whole document was split'
        Assert-True ($pack.Contains('Invoices close monthly') -and $pack.Contains('Ship structured logs')) 'Whole document lost content'
    }
    Check 'omitted matches are indexed within the budget' {
        $root = Fixture 'index'
        Add-Document $root 'FIRST' "# First`n`n## Rollout`n`nkubernetes canary steps. $filler`n`n## Notes`n`n$filler"
        Add-Document $root 'SECOND' "# Second`n`n## Rollback`n`nkubernetes rollback steps. $filler`n`n## Notes`n`n$filler"
        $required = Run-Cli $root @('bench', '-Query', 'kubernetes')
        $base = [int][regex]::Match($required.Text, '= (\d+) estimated tokens').Groups[1].Value
        $budget = $base + 500
        $pack = Context $root @('-Query', 'kubernetes', '-Budget', "$budget")
        $tokens = [int][regex]::Match($pack, 'Estimated tokens: (\d+) / ').Groups[1].Value
        Assert-True ($tokens -le $budget -and [math]::Ceiling($pack.Length / 4.0) -eq $tokens) "Budget not honored: $tokens / $budget"
        Assert-True ($pack.Contains('## Not included')) 'Index missing'
        $included = @('FIRST#rollout', 'SECOND#rollback' | Where-Object { $pack.Contains("## $_ |") })
        Assert-True ($included.Count -eq 1) "Expected one included section: $($included -join ', ')"
        $other = @('FIRST#rollout', 'SECOND#rollback' | Where-Object { $_ -notin $included })[0]
        Assert-True ($pack -match "(?m)^- $([regex]::Escape($other)) \| \d+ tokens \| Roll") "Omitted section not indexed: $other"
        Assert-True ($pack.IndexOf('## Not included') -lt $pack.IndexOf('- Query:')) 'Index placed after request details'
    }
    Check 'get returns a document or one section without changing files' {
        $root = Fixture 'get'
        Guide $root
        $before = Project-Hash $root
        $section = Run-Cli $root @('get', '-Id', 'GUIDE#billing')
        Assert-True ($section.Code -eq 0 -and $section.Text.Contains('Invoices close monthly') -and -not $section.Text.Contains('kubernetes')) $section.Text
        $whole = Run-Cli $root @('get', '-Id', 'GUIDE')
        Assert-True ($whole.Code -eq 0 -and $whole.Text.Contains('kubernetes') -and $whole.Text.Contains('Ship structured logs')) $whole.Text
        $missingSection = Run-Cli $root @('get', '-Id', 'GUIDE#nope')
        Assert-True ($missingSection.Code -ne 0 -and $missingSection.Text.Contains('Section not found: GUIDE#nope') -and $missingSection.Text.Contains('deploy, billing, logging')) $missingSection.Text
        $missingDocument = Run-Cli $root @('get', '-Id', 'NOPE')
        Assert-True ($missingDocument.Code -ne 0 -and $missingDocument.Text.Contains('Document not found: NOPE')) $missingDocument.Text
        Assert-True ((Project-Hash $root) -eq $before) 'get changed memory files'
    }
    Check 'small documents and fenced headings are not split' {
        $root = Fixture 'boundaries'
        Add-Document $root 'SMALL' "# Small`n`n## One`n`nkubernetes note.`n`n## Two`n`nOther note."
        $fence = '```'
        Add-Document $root 'FENCED' "# Fenced`n`n## Real`n`n$filler`n`n$fence`n## not a heading`n$fence`n`n## Other`n`n$filler"
        $pack = Context $root @('-Query', 'kubernetes')
        Assert-True ($pack.Contains('## SMALL | L3') -and $pack.Contains('Other note.')) 'Small document was split'
        $result = Run-Cli $root @('get', '-Id', 'FENCED#not-a-heading')
        Assert-True ($result.Code -ne 0 -and $result.Text.Contains('real, other')) $result.Text
    }
} finally { if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force } }
if ($failures.Count) { throw "$($failures.Count) section checks failed: $($failures -join '; ')" }
Write-Host 'All 5 N4ti section checks passed'
