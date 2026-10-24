$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'opencode') ('n4ti-retrieval-' + [guid]::NewGuid().ToString('N'))
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
function Add-Document([string]$Root, [string]$Id, [string]$Content, [int]$Level = 3, [string[]]$Tags = @(), [string]$Priority = 'normal', [string]$Type = 'knowledge', [string]$RelativePath = '') {
    if (-not $RelativePath) {
        $folder = if ($Level -ge 4) { 'archive' } else { 'knowledge' }
        $RelativePath = "N4ti/$folder/$Id.md"
    }
    [IO.File]::WriteAllText((Join-Path $Root $RelativePath), $Content, [Text.UTF8Encoding]::new($false))
    $catalogPath = Join-Path $Root 'N4ti/catalog.json'
    $catalog = Get-Content $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $catalog.documents = @($catalog.documents) + [pscustomobject]@{
        id = $Id; level = $Level; type = $Type; status = 'active'; priority = $Priority
        tags = $Tags; affects = @(); path = $RelativePath; alwaysLoad = $false
    }
    [IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
}
function Pack([string]$Root) { Get-Content (Join-Path $Root 'N4ti/.runtime/context-pack.md') -Raw -Encoding UTF8 }
function Memory-Hash([string]$Root) {
    return ((Get-ChildItem (Join-Path $Root 'N4ti') -File -Recurse | Where-Object { $_.FullName -notmatch '[\\/]\.runtime[\\/]' } | Sort-Object FullName |
        ForEach-Object { $_.FullName + ':' + (Get-FileHash $_.FullName).Hash }) -join "`n")
}
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS: $Name" }
    catch { $script:failures += "$Name`: $($_.Exception.Message)"; Write-Host "FAIL: $($script:failures[-1])" }
}

try {
    Check 'accented UTF8 text matches plain and decomposed queries without changing sources' {
        $root = Fixture 'unicode'
        $word = 'configuraci' + [char]0x00F3 + 'n'
        $content = "# $word`r`n`r`nPreserve this original UTF8 document."
        Add-Document $root 'UNICODE' $content
        $before = Memory-Hash $root
        foreach ($query in @('configuracion', $word.Normalize([Text.NormalizationForm]::FormD))) {
            $result = Run-Cli $root @('context', '-Query', $query)
            Assert-True ($result.Code -eq 0 -and (Pack $root).Contains($content)) 'Accent-insensitive lookup lost original text'
        }
        Assert-True ((Memory-Hash $root) -eq $before) 'Search changed memory'
    }
    Check 'tags titles and paths outrank incidental body matches' {
        $root = Fixture 'ranking'
        Add-Document $root 'A_BODY' "# Notes`nAn incidental needle mention."
        Add-Document $root 'Z_META' '# Tagged document' -Tags @('needle')
        Add-Document $root 'Y_TITLE' "# needle`nTitle-focused details."
        Add-Document $root 'X_PATH' '# Path-focused details' -RelativePath 'N4ti/knowledge/needle.md'
        $result = Run-Cli $root @('search', '-Query', 'needle')
        Assert-True ($result.Code -eq 0) $result.Text
        foreach ($id in @('Z_META', 'Y_TITLE', 'X_PATH')) {
            Assert-True ($result.Text.Contains($id) -and $result.Text.IndexOf($id) -lt $result.Text.IndexOf('A_BODY')) "Weak metadata relevance: $id"
        }
    }
    Check 'archive is opt-in for search and context without changing history' {
        $root = Fixture 'archive'
        Add-Document $root 'HISTORIC' '# ancient archival evidence' -Level 4
        $before = Memory-Hash $root
        $search = Run-Cli $root @('search', '-Query', 'ancient')
        $context = Run-Cli $root @('context', '-Query', 'ancient')
        Assert-True ($search.Code -eq 0 -and $context.Code -eq 0 -and -not $search.Text.Contains('HISTORIC') -and -not (Pack $root).Contains('HISTORIC')) 'Archive loaded without permission'
        $search = Run-Cli $root @('search', '-Query', 'ancient', '-IncludeArchive')
        $context = Run-Cli $root @('context', '-Query', 'ancient', '-IncludeArchive')
        Assert-True ($search.Code -eq 0 -and $context.Code -eq 0 -and $search.Text.Contains('HISTORIC') -and (Pack $root).Contains('ancient archival evidence')) 'Explicit history is unavailable'
        Assert-True ((Memory-Hash $root) -eq $before) 'History changed during retrieval'
        $invalid = Run-Cli $root @('save', '-Summary', 'Invalid flag', '-Next', 'None', '-IncludeArchive')
        Assert-True ($invalid.Code -ne 0 -and (Memory-Hash $root) -eq $before) 'Unsupported archive option silently accepted'
    }
    Check 'explicit archived tasks remain required without admitting unrelated history' {
        $root = Fixture 'archived-task'
        Add-Document $root 'TASK-900' '# Historical task acceptance marker' -Level 4 -Type 'task'
        Add-Document $root 'OTHER-HISTORY' '# Historical task related but optional' -Level 4
        $result = Run-Cli $root @('task-packet', '-Id', 'TASK-900', '-Agent', 'security', '-Budget', '5000')
        Assert-True ($result.Code -eq 0) $result.Text
        $text = Get-Content (Join-Path $root 'N4ti/.runtime/packets/TASK-900-security.md') -Raw -Encoding UTF8
        Assert-True ($text.Contains('Historical task acceptance marker') -and -not $text.Contains('OTHER-HISTORY')) 'Assigned archive task missing or unrelated history admitted'
    }
    Check 'optional identical content is emitted once but remains searchable' {
        $root = Fixture 'dedup'
        $body = '# needle duplicate reference' + "`n" + ('Repeated evidence. ' * 60)
        Add-Document $root 'DUPA' $body
        Add-Document $root 'DUPB' $body
        $result = Run-Cli $root @('context', '-Query', 'needle')
        Assert-True ($result.Code -eq 0) $result.Text
        $text = Pack $root
        Assert-True ([regex]::Matches($text, [regex]::Escape($body.Trim())).Count -eq 1) 'Repeated document consumes context twice'
        $search = Run-Cli $root @('search', '-Query', 'needle')
        Assert-True ($search.Code -eq 0 -and $search.Text.Contains('DUPA') -and $search.Text.Contains('DUPB')) 'Dedup hid original search sources'
        $reported = [int][regex]::Match($text, 'Estimated tokens: (\d+)').Groups[1].Value
        Assert-True ($reported -eq [math]::Ceiling($text.Length / 4.0) -and $reported -le 5000) 'Dedup broke complete-output budget'
    }
    Check 'mandatory duplicates and case-sensitive differences are preserved' {
        $root = Fixture 'required'
        $body = '# needle mandatory constraint'
        Add-Document $root 'REQA' $body -Priority 'critical'
        Add-Document $root 'REQB' $body -Priority 'critical'
        Add-Document $root 'OPTCOPY' $body
        Add-Document $root 'CASEA' '# needle return Value'
        Add-Document $root 'CASEB' '# needle return value'
        $result = Run-Cli $root @('context', '-Query', 'needle')
        $text = Pack $root
        Assert-True ($result.Code -eq 0 -and [regex]::Matches($text, [regex]::Escape($body)).Count -eq 2) 'Mandatory sources lost or optional copy repeated'
        Assert-True ($text.Contains('return Value') -and $text.Contains('return value')) 'Case-sensitive evidence merged'
    }
    Check 'mandatory archive conflict refuses rather than discarding constraints' {
        $root = Fixture 'invalid-archive'
        Add-Document $root 'BADARCHIVE' '# needle mandatory archived rule' -Level 4 -Priority 'critical'
        $before = Memory-Hash $root
        $result = Run-Cli $root @('context', '-Query', 'needle')
        Assert-True ($result.Code -ne 0 -and $result.Text.Contains('Archive document cannot be mandatory')) 'Invalid mandatory history accepted'
        Assert-True ((Memory-Hash $root) -eq $before -and -not (Test-Path (Join-Path $root 'N4ti/.runtime/context-pack.md'))) 'Rejected retrieval changed files'
    }
} finally { if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force } }
if ($failures.Count) { throw "$($failures.Count) retrieval checks failed: $($failures -join '; ')" }
Write-Host 'All 7 N4ti retrieval checks passed'
