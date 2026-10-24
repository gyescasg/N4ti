$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'opencode') ('n4ti-delta-' + [guid]::NewGuid().ToString('N'))
$failures = @()
$filler = ('lorem ipsum dolor sit amet ' * 40).Trim()
$query = 'kubernetes invoices'

function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Fixture([string]$Name) {
    $root = Join-Path $testRoot $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    & (Join-Path $packageRoot 'Install-N4ti.ps1') -ProjectPath $root | Out-Null
    Guide $root
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
function Guide([string]$Root, [string]$Billing = 'Invoices close monthly.') {
    $content = "# Operations guide`n`n## Deploy`n`nUse kubernetes rollouts. $filler`n`n## Billing`n`n$Billing $filler`n`n## Logging`n`nShip structured logs. $filler"
    $path = Join-Path $Root 'N4ti/knowledge/GUIDE.md'
    if (Test-Path -LiteralPath $path) { [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($false)) }
    else { Add-Document $Root 'GUIDE' $content }
}
function Context([string]$Root, [string[]]$Extra = @()) {
    $result = Run-Cli $Root (@('context', '-Query', $query) + $Extra)
    Assert-True ($result.Code -eq 0) $result.Text
    $text = Get-Content (Join-Path $Root 'N4ti/.runtime/context-pack.md') -Raw -Encoding UTF8
    Assert-True ($text -match '(?m)^- Pack id: ([0-9a-f]{12})\r?$') "Pack id line missing: $text"
    $id = $Matches[1]
    Assert-True ($result.Text.Contains("Pack id: $id")) "Console did not print the pack id: $($result.Text)"
    Assert-True ($text -match '- Estimated tokens: (\d+) /') 'Token line missing'
    return [pscustomobject]@{ Id = $id; Text = $text; Tokens = [int]$Matches[1]; Console = $result.Text }
}
function Manifests([string]$Root) {
    $dir = Join-Path $Root 'N4ti/.runtime/packs'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File)
}
function Runtime-Hash([string]$Root) {
    $dir = Join-Path $Root 'N4ti/.runtime'
    if (-not (Test-Path -LiteralPath $dir)) { return '' }
    return ((Get-ChildItem $dir -File -Recurse | Sort-Object FullName |
        ForEach-Object { $_.FullName + ':' + (Get-FileHash $_.FullName).Hash }) -join "`n")
}
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS: $Name" }
    catch { $script:failures += "$Name`: $($_.Exception.Message)"; Write-Host "FAIL: $($script:failures[-1])" }
}

try {
    Check 'context prints a pack id and writes its manifest' {
        $root = Fixture 'manifest'
        $pack = Context $root
        $file = Join-Path $root "N4ti/.runtime/packs/$($pack.Id).json"
        Assert-True (Test-Path -LiteralPath $file) 'Manifest missing'
        $manifest = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        $ids = @($manifest.units | ForEach-Object { $_.id })
        foreach ($unit in @('CORE', 'STATE', 'GUIDE#deploy', 'GUIDE#billing')) { Assert-True ($unit -in $ids) "Unit $unit missing from manifest" }
        Assert-True (@($manifest.units | Where-Object { $_.hash -notmatch '^[0-9a-f]{64}$' }).Count -eq 0) 'Unit without SHA-256 hash'
    }
    Check 'the same input gives the same pack id' {
        $root = Fixture 'same'
        $first = Context $root
        $second = Context $root
        Assert-True ($first.Id -eq $second.Id -and $first.Text -eq $second.Text) 'Pack id or pack changed without input changes'
        Assert-True ((Manifests $root).Count -eq 1) 'Same pack wrote two manifests'
    }
    Check '-Since without changes delivers no document content' {
        $root = Fixture 'unchanged'
        $base = Context $root
        $delta = Context $root @('-Since', $base.Id)
        Assert-True (-not $delta.Text.Contains('Use kubernetes rollouts') -and -not $delta.Text.Contains('## CORE |')) 'Delta repeated delivered content'
        Assert-True ($delta.Text -match '(?m)^- Already delivered: [^\r\n]*CORE[^\r\n]*GUIDE#deploy') "Already delivered line missing: $($delta.Text)"
        Assert-True ($delta.Tokens * 4 -lt $base.Tokens) "Delta not much smaller: $($delta.Tokens) vs $($base.Tokens)"
        Assert-True ($delta.Tokens -eq [math]::Ceiling($delta.Text.Length / 4.0)) 'Delta count does not cover its whole output'
        Assert-True ($delta.Id -eq $base.Id) 'Unchanged delta changed the cumulative pack id'
    }
    Check 'an unchanged delta says no documents were sent' {
        $root = Fixture 'none'
        $base = Context $root
        $delta = Context $root @('-Since', $base.Id)
        Assert-True ($delta.Text -match '(?m)^- Documents: none\r?$') "Documents line: $($delta.Text)"
        Assert-True ($delta.Tokens -eq [math]::Ceiling($delta.Text.Length / 4.0)) 'Delta count does not cover its whole output'
    }
    Check 'an edited section is the only delivered unit' {
        $root = Fixture 'edited'
        $base = Context $root
        Guide $root 'Invoices close weekly.'
        $delta = Context $root @('-Since', $base.Id)
        Assert-True ($delta.Text.Contains('Invoices close weekly') -and $delta.Text.Contains('## GUIDE#billing |')) 'Changed section missing'
        Assert-True (-not $delta.Text.Contains('Use kubernetes rollouts') -and -not $delta.Text.Contains('## STATE |')) 'Unchanged units repeated'
        Assert-True ($delta.Id -ne $base.Id) 'Changed content kept the pack id'
        $again = Context $root @('-Since', $delta.Id)
        Assert-True (-not $again.Text.Contains('Invoices close weekly')) 'Chained delta repeated the changed section'
    }
    Check 'a new document is delivered and mandatory documents are not repeated' {
        $root = Fixture 'new'
        $base = Context $root
        Add-Document $root 'KUBE' "# Cluster notes`n`nkubernetes nodes autoscale."
        $delta = Context $root @('-Since', $base.Id)
        Assert-True ($delta.Text.Contains('## KUBE |') -and $delta.Text.Contains('nodes autoscale')) 'New document missing'
        foreach ($mandatory in @('AUTONOMY', 'CORE', 'ORCHESTRATION', 'STATE')) { Assert-True (-not $delta.Text.Contains("## $mandatory |")) "Mandatory $mandatory repeated" }
        $manifest = Get-Content (Join-Path $root "N4ti/.runtime/packs/$($delta.Id).json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $ids = @($manifest.units | ForEach-Object { $_.id })
        Assert-True ('KUBE' -in $ids -and 'CORE' -in $ids -and 'GUIDE#deploy' -in $ids) 'Delta manifest is not cumulative'
    }
    Check 'an unknown -Since id fails and writes nothing' {
        $root = Fixture 'unknown'
        $before = Runtime-Hash $root
        foreach ($bad in @('0123456789ab', '..\..\x')) {
            $result = Run-Cli $root @('context', '-Query', $query, '-Since', $bad)
            Assert-True ($result.Code -ne 0 -and $result.Text.Contains('Unknown pack id')) "Unknown id accepted: $($result.Text)"
        }
        Assert-True ((Runtime-Hash $root) -eq $before) 'A failed -Since wrote files'
    }
    Check '-Since is rejected by other commands' {
        $root = Fixture 'other'
        $result = Run-Cli $root @('bench', '-Query', $query, '-Since', '0123456789ab')
        Assert-True ($result.Code -ne 0 -and $result.Text.Contains('-Since is supported only by context')) $result.Text
    }
    Check 'only the last 20 manifests are kept' {
        $root = Fixture 'prune'
        $first = Context $root
        for ($i = 1; $i -le 21; $i++) {
            Guide $root "Invoices close on day $i."
            Context $root | Out-Null
        }
        Assert-True ((Manifests $root).Count -eq 20) "Manifest count: $((Manifests $root).Count)"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root "N4ti/.runtime/packs/$($first.Id).json"))) 'Oldest manifest was kept'
    }
    Check 'pruning tolerates a manifest it cannot remove' {
        # A concurrent run may delete or hold an old manifest; a locked file makes that failure deterministic.
        $root = Fixture 'prune-race'
        Context $root | Out-Null
        $dir = Join-Path $root 'N4ti/.runtime/packs'
        for ($i = 0; $i -lt 21; $i++) {
            $path = Join-Path $dir ('{0:x12}.json' -f $i)
            [IO.File]::WriteAllText($path, '{"id":"old","units":[]}', [Text.UTF8Encoding]::new($false))
            (Get-Item -LiteralPath $path).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-10 - $i)
        }
        $oldest = Join-Path $dir ('{0:x12}.json' -f 20)
        $lock = [IO.File]::Open($oldest, 'Open', 'Read', 'None')
        try {
            Guide $root 'Invoices close quarterly.'
            $result = Run-Cli $root @('context', '-Query', $query)
        } finally { $lock.Dispose() }
        Assert-True ($result.Code -eq 0 -and $result.Text.Contains('Pack id:')) $result.Text
        Assert-True (Test-Path -LiteralPath $oldest) 'Locked manifest disappeared'
        Assert-True ((Manifests $root).Count -le 21) "Manifest count: $((Manifests $root).Count)"
    }
    Check 'bench writes no manifest' {
        $root = Fixture 'bench'
        $result = Run-Cli $root @('bench', '-Query', $query)
        Assert-True ($result.Code -eq 0) $result.Text
        Assert-True ((Manifests $root).Count -eq 0) 'bench wrote a manifest'
    }
    Check 'a normal context pack only gains the counted trailing pack id line' {
        $root = Fixture 'legacy'
        $pack = Context $root
        $body = $pack.Text -replace '- Pack id: [0-9a-f]{12}\r\n$', ''
        Assert-True ($body -match '- Documents: [^\r\n]*\r\n$') 'Pack id is not the trailing line'
        Assert-True ($pack.Tokens -eq [math]::Ceiling($pack.Text.Length / 4.0)) 'Count does not cover the pack id line'
        $bench = Run-Cli $root @('bench', '-Query', $query)
        Assert-True ($bench.Text -match "\| $query \| (\d+) \| (\d+) \|") $bench.Text
        Assert-True ([int]$Matches[1] -eq $pack.Tokens -and [int]$Matches[2] -eq $pack.Text.Length) "context differs from bench: $($Matches[1])/$($Matches[2]) vs $($pack.Tokens)/$($pack.Text.Length)"
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

if ($failures.Count) { throw "Delta test failed ($($failures.Count)): $($failures -join '; ')" }
Write-Host 'All 12 N4ti delta checks passed'
