$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'opencode') ('n4ti-supersede-' + [guid]::NewGuid().ToString('N'))
$failures = @()
# Dates far from today keep expiry checks independent of the clock.
$past = '2000-01-01'
$future = '2999-12-31'

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
function Read-Catalog([string]$Root) { return Get-Content (Join-Path $Root 'N4ti/catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
function Add-Document([string]$Root, [string]$Id, [hashtable]$Extra = @{}) {
    $relativePath = "N4ti/knowledge/$Id.md"
    [IO.File]::WriteAllText((Join-Path $Root $relativePath), "# $Id`n`nNeedle notes for $Id.", [Text.UTF8Encoding]::new($false))
    Edit-Catalog $Root {
        param($catalog)
        $entry = [pscustomobject]@{
            id = $Id; level = 3; type = 'knowledge'; status = 'active'; priority = 'normal'
            tags = @(); affects = @(); path = $relativePath; alwaysLoad = $false
        }
        foreach ($key in $Extra.Keys) { $entry | Add-Member -NotePropertyName $key -NotePropertyValue $Extra[$key] }
        $catalog.documents = @($catalog.documents) + $entry
    }
}
function Set-Field([string]$Root, [string]$Id, [string]$Name, $Value) {
    Edit-Catalog $Root {
        param($catalog)
        $document = $catalog.documents | Where-Object { $_.id -eq $Id }
        $document | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}
function Pack-Documents([string]$Text) { return @([regex]::Match($Text, 'Documents: ([^\r\n]+)').Groups[1].Value -split ',\s*') }
function Search-Ids([string]$Text) { return @(($Text -split "`r?`n") | ForEach-Object { ($_.Trim() -split '\s+')[0] }) }
function Output-Lines([string]$Text) { return @($Text -split "`r?`n") }
function Store-Hash([string]$Root) {
    return ((Get-ChildItem (Join-Path $Root 'N4ti') -File -Recurse | Sort-Object FullName |
        ForEach-Object { $_.FullName + ':' + (Get-FileHash $_.FullName).Hash }) -join "`n")
}
function Pack-Text([string]$Root) { return Get-Content (Join-Path $Root 'N4ti/.runtime/context-pack.md') -Raw -Encoding UTF8 }
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS: $Name" }
    catch { $script:failures += "$Name`: $($_.Exception.Message)"; Write-Host "FAIL: $($script:failures[-1])" }
}

try {
    Check 'superseded documents leave context, search and the not-included index' {
        $root = Fixture 'superseded'
        Add-Document $root 'OLDRULE'
        Add-Document $root 'NEWRULE' @{ supersedes = @('OLDRULE') }
        $context = Run-Cli $root @('context', '-Query', 'needle')
        $documents = Pack-Documents $context.Text
        Assert-True ($context.Code -eq 0 -and 'NEWRULE' -in $documents -and 'OLDRULE' -notin $documents) $context.Text
        Assert-True (-not (Pack-Text $root).Contains('OLDRULE')) 'Superseded document listed in the pack'
        $search = Run-Cli $root @('search', '-Query', 'needle')
        $ids = Search-Ids $search.Text
        Assert-True ($search.Code -eq 0 -and 'NEWRULE' -in $ids -and 'OLDRULE' -notin $ids) $search.Text
    }
    Check 'expired documents are excluded' {
        $root = Fixture 'expired'
        Add-Document $root 'STALE' @{ expires = $past }
        $context = Run-Cli $root @('context', '-Query', 'needle')
        Assert-True ($context.Code -eq 0 -and 'STALE' -notin (Pack-Documents $context.Text)) $context.Text
        $search = Run-Cli $root @('search', '-Query', 'needle')
        Assert-True ($search.Code -eq 0 -and 'STALE' -notin (Search-Ids $search.Text)) $search.Text
    }
    Check 'documents expiring in the future are included' {
        $root = Fixture 'future'
        Add-Document $root 'FRESH' @{ expires = $future }
        $context = Run-Cli $root @('context', '-Query', 'needle')
        Assert-True ($context.Code -eq 0 -and 'FRESH' -in (Pack-Documents $context.Text)) $context.Text
    }
    Check 'IncludeArchive brings back superseded and expired documents' {
        $root = Fixture 'include'
        Add-Document $root 'OLDRULE'
        Add-Document $root 'NEWRULE' @{ supersedes = @('OLDRULE') }
        Add-Document $root 'STALE' @{ expires = $past }
        $context = Run-Cli $root @('context', '-Query', 'needle', '-IncludeArchive')
        $documents = Pack-Documents $context.Text
        Assert-True ($context.Code -eq 0 -and 'OLDRULE' -in $documents -and 'STALE' -in $documents) $context.Text
    }
    Check 'get still returns a superseded document and warns which document replaces it' {
        $root = Fixture 'get'
        Add-Document $root 'OLDRULE'
        Add-Document $root 'NEWRULE' @{ supersedes = @('OLDRULE') }
        $result = Run-Cli $root @('get', '-Id', 'OLDRULE')
        Assert-True ($result.Code -eq 0 -and $result.Text.Contains('Needle notes for OLDRULE')) $result.Text
        $lines = Output-Lines $result.Text
        Assert-True ($lines[0].StartsWith('## OLDRULE |') -and $lines[1] -eq '> Warning: superseded by NEWRULE') $result.Text
    }
    Check 'get on an expired document warns with its date' {
        $root = Fixture 'get-expired'
        Add-Document $root 'STALE' @{ expires = $past }
        $result = Run-Cli $root @('get', '-Id', 'STALE')
        Assert-True ($result.Code -eq 0 -and $result.Text.Contains('Needle notes for STALE')) $result.Text
        Assert-True ((Output-Lines $result.Text)[1] -eq "> Warning: expired $past") $result.Text
    }
    Check 'get on a normal document prints no warning' {
        $root = Fixture 'get-normal'
        Add-Document $root 'PLAIN' @{ expires = $future }
        Add-Document $root 'OTHER' @{ supersedes = @('MISSING') }
        $result = Run-Cli $root @('get', '-Id', 'PLAIN')
        $lines = Output-Lines $result.Text
        Assert-True ($result.Code -eq 0 -and -not $result.Text.Contains('Warning')) $result.Text
        Assert-True ($lines[0] -eq '## PLAIN | L3 | N4ti/knowledge/PLAIN.md' -and $lines[1] -eq '' -and $lines[2] -eq '# PLAIN') $result.Text
    }
    Check 'get warns when the catalog has invalid supersedes or expires values' {
        $root = Fixture 'get-invalid'
        Add-Document $root 'PLAIN'
        Add-Document $root 'WRONG' @{ expires = '31/12/2999' }
        $result = Run-Cli $root @('get', '-Id', 'PLAIN')
        Assert-True ($result.Code -eq 0 -and $result.Text.Contains('Needle notes for PLAIN')) $result.Text
        Assert-True ((Output-Lines $result.Text)[1] -eq '> Warning: catalog has invalid supersedes/expires values; run validate') $result.Text
    }
    Check 'supersedes cycles fail context and search naming the cycle and write nothing' {
        $root = Fixture 'cycle-retrieval'
        Add-Document $root 'ALPHA' @{ supersedes = @('BETA') }
        Add-Document $root 'BETA' @{ supersedes = @('ALPHA') }
        $before = Store-Hash $root
        foreach ($command in @('context', 'search')) {
            $result = Run-Cli $root @($command, '-Query', 'needle')
            Assert-True ($result.Code -ne 0 -and $result.Text.Contains('Supersedes cycle: ALPHA -> BETA -> ALPHA')) "$command`: $($result.Text)"
        }
        Assert-True ((Store-Hash $root) -eq $before) 'A failed retrieval wrote files'
        $get = Run-Cli $root @('get', '-Id', 'ALPHA')
        Assert-True ($get.Code -eq 0 -and $get.Text.Contains('Needle notes for ALPHA') -and $get.Text.Contains('> Warning: catalog has invalid')) $get.Text
    }
    Check 'superseded or expired mandatory documents are errors' {
        $root = Fixture 'mandatory'
        Add-Document $root 'NEWCORE' @{ supersedes = @('CORE') }
        $result = Run-Cli $root @('context', '-Query', 'needle')
        Assert-True ($result.Code -ne 0 -and $result.Text.Contains('Superseded document cannot be mandatory: CORE')) $result.Text
        $root = Fixture 'mandatory-expired'
        Set-Field $root 'STATE' 'expires' $past
        $result = Run-Cli $root @('context', '-Query', 'needle')
        Assert-True ($result.Code -ne 0 -and $result.Text.Contains('Expired document cannot be mandatory: STATE')) $result.Text
    }
    Check 'validate reports unknown supersedes targets' {
        $root = Fixture 'unknown'
        Add-Document $root 'NEWRULE' @{ supersedes = @('MISSING') }
        $result = Run-Cli $root @('validate')
        Assert-True ($result.Code -ne 0 -and $result.Text.Contains('Unknown supersedes target in NEWRULE: MISSING')) $result.Text
    }
    Check 'validate reports self-supersession' {
        $root = Fixture 'self'
        Add-Document $root 'LOOP' @{ supersedes = @('LOOP') }
        $result = Run-Cli $root @('validate')
        Assert-True ($result.Code -ne 0 -and $result.Text.Contains('Document cannot supersede itself: LOOP')) $result.Text
    }
    Check 'validate reports supersedes cycles' {
        $root = Fixture 'cycle'
        Add-Document $root 'ALPHA' @{ supersedes = @('BETA') }
        Add-Document $root 'BETA' @{ supersedes = @('ALPHA') }
        $result = Run-Cli $root @('validate')
        Assert-True ($result.Code -ne 0 -and $result.Text.Contains('Supersedes cycle:') -and $result.Text.Contains('ALPHA')) $result.Text
    }
    Check 'validate reports bad expiry dates' {
        $root = Fixture 'baddate'
        Add-Document $root 'WRONG' @{ expires = '31/12/2999' }
        $result = Run-Cli $root @('validate')
        Assert-True ($result.Code -ne 0 -and $result.Text.Contains('Invalid expires date for WRONG: 31/12/2999')) $result.Text
    }
    Check 'new-decision -Supersedes records the field and hides the old decision' {
        $root = Fixture 'decision'
        $first = Run-Cli $root @('new-decision', '-Title', 'Needle storage', '-Summary', 'Use needle files.')
        Assert-True ($first.Code -eq 0) $first.Text
        $second = Run-Cli $root @('new-decision', '-Title', 'Needle database', '-Summary', 'Use a needle database.', '-Supersedes', 'DEC-001')
        Assert-True ($second.Code -eq 0) $second.Text
        $entry = (Read-Catalog $root).documents | Where-Object { $_.id -eq 'DEC-002' }
        Assert-True ((@($entry.supersedes) -join ',') -eq 'DEC-001') "supersedes field: $(@($entry.supersedes) -join ',')"
        $body = Get-Content (Join-Path $root 'N4ti/decisions/DEC-002.md') -Raw -Encoding UTF8
        Assert-True ($body.Contains('- Supersedes: DEC-001')) $body
        $context = Run-Cli $root @('context', '-Query', 'needle')
        $documents = Pack-Documents $context.Text
        Assert-True ($context.Code -eq 0 -and 'DEC-002' -in $documents -and 'DEC-001' -notin $documents) $context.Text
        $validate = Run-Cli $root @('validate')
        Assert-True ($validate.Code -eq 0) $validate.Text
    }
    Check 'new-decision -Supersedes rejects a mandatory document without writing' {
        $root = Fixture 'decision-mandatory'
        $catalogPath = Join-Path $root 'N4ti/catalog.json'
        $decisionsPath = Join-Path $root 'N4ti/decisions'
        $before = (Get-FileHash $catalogPath).Hash
        $filesBefore = @(Get-ChildItem $decisionsPath -Name) -join ','
        $result = Run-Cli $root @('new-decision', '-Title', 'Z', '-Summary', 'W', '-Supersedes', 'CORE')
        Assert-True ($result.Code -ne 0 -and $result.Text.Contains('CORE')) $result.Text
        Assert-True ((Get-FileHash $catalogPath).Hash -eq $before) 'Catalog changed after a rejected new-decision'
        Assert-True ((@(Get-ChildItem $decisionsPath -Name) -join ',') -eq $filesBefore) 'Decision file written after a rejected new-decision'
        $context = Run-Cli $root @('context', '-Query', 'needle')
        Assert-True ($context.Code -eq 0) $context.Text
    }
    Check 'catalogs without the fields keep the same context output' {
        $root = Fixture 'legacy'
        Add-Document $root 'LEGACY'
        $before = Run-Cli $root @('context', '-Query', 'needle')
        $beforePack = Pack-Text $root
        Set-Field $root 'LEGACY' 'supersedes' @()
        Set-Field $root 'LEGACY' 'expires' $future
        $after = Run-Cli $root @('context', '-Query', 'needle')
        Assert-True ($before.Code -eq 0 -and $after.Code -eq 0 -and 'LEGACY' -in (Pack-Documents $before.Text)) $before.Text
        Assert-True ($beforePack -eq (Pack-Text $root)) 'Inert fields changed the pack'
    }
} finally { if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force } }
if ($failures.Count) { throw "$($failures.Count) supersede checks failed: $($failures -join '; ')" }
Write-Host 'All 17 N4ti supersede checks passed'
