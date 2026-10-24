$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'opencode') ('n4ti-bench-' + [guid]::NewGuid().ToString('N'))
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
function Add-Document([string]$Root, [string]$Id, [string]$Content, [int]$Level = 3, [string]$Priority = 'normal') {
    $folder = if ($Level -ge 4) { 'archive' } else { 'knowledge' }
    $relativePath = "N4ti/$folder/$Id.md"
    [IO.Directory]::CreateDirectory((Split-Path -Parent (Join-Path $Root $relativePath))) | Out-Null
    [IO.File]::WriteAllText((Join-Path $Root $relativePath), $Content, [Text.UTF8Encoding]::new($false))
    $catalogPath = Join-Path $Root 'N4ti/catalog.json'
    $catalog = Get-Content $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $catalog.documents = @($catalog.documents) + [pscustomobject]@{
        id = $Id; level = $Level; type = 'knowledge'; status = 'active'; priority = $Priority
        tags = @(); affects = @(); path = $relativePath; alwaysLoad = $false
    }
    [IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
}
function Project-Hash([string]$Root) {
    return ((Get-ChildItem $Root -File -Recurse | Sort-Object FullName |
        ForEach-Object { $_.FullName + ':' + (Get-FileHash $_.FullName).Hash }) -join "`n")
}
function Row([string]$Text, [string]$Query) {
    $line = ($Text -split "`r?`n") | Where-Object { $_.StartsWith("| $Query |") } | Select-Object -First 1
    Assert-True $line "Missing bench row for $Query"
    return @($line.Trim('|').Split('|') | ForEach-Object { $_.Trim() })
}
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS: $Name" }
    catch { $script:failures += "$Name`: $($_.Exception.Message)"; Write-Host "FAIL: $($script:failures[-1])" }
}

try {
    Check 'bench measures the same pack as context and writes nothing' {
        $root = Fixture 'parity'
        Add-Document $root 'NEEDLE' "# needle`n`nNeedle evidence body."
        $before = Project-Hash $root
        $bench = Run-Cli $root @('bench', '-Query', 'needle', '-Budget', '4000')
        Assert-True ($bench.Code -eq 0) $bench.Text
        Assert-True ((Project-Hash $root) -eq $before) 'bench changed project files'
        $cells = Row $bench.Text 'needle'
        $context = Run-Cli $root @('context', '-Query', 'needle', '-Budget', '4000')
        $pack = Get-Content (Join-Path $root 'N4ti/.runtime/context-pack.md') -Raw -Encoding UTF8
        Assert-True ($context.Text.Contains("Estimated tokens: $($cells[1]) / 4000")) "Token mismatch: bench $($cells[1]) vs context $($context.Text)"
        Assert-True ([int]$cells[2] -eq $pack.Length) "Character mismatch: $($cells[2]) vs $($pack.Length)"
        $required = [regex]::Match($bench.Text, '- Required in every pack: ([^=]+) =').Groups[1].Value.Trim()
        Assert-True ($required.Contains('CORE') -and $required.Contains('STATE')) "Required list incomplete: $required"
        Assert-True ($cells[3] -eq "$required, NEEDLE") "Unexpected documents: $($cells[3])"
    }
    Check 'bench reports corpus, always-loaded cost, omissions and shared prefix deterministically' {
        $root = Fixture 'report'
        Add-Document $root 'SMALL' "# alpha`n`nShort alpha note."
        Add-Document $root 'LARGE' ("# alpha beta`n`n" + ('x' * 8000))
        $arguments = @('bench', '-Query', 'alpha;beta', '-Budget', '1500')
        $first = Run-Cli $root $arguments
        $second = Run-Cli $root $arguments
        Assert-True ($first.Code -eq 0) $first.Text
        Assert-True ($first.Text -eq $second.Text) 'bench output is not deterministic'
        Assert-True ($first.Text -match '- Estimator: characters / 4') 'Estimator is not disclosed'
        Assert-True ($first.Text -match '- Corpus: \d+ documents, \d+ estimated tokens \(archive excluded\)') 'Corpus line missing'
        $required = [regex]::Match($first.Text, '- Required in every pack: ([^=]+) = \d+ estimated tokens').Groups[1].Value.Trim()
        Assert-True $required 'Required line missing'
        Assert-True ($first.Text -match '- Shared pack prefix: \d+ characters across 2 packs') 'Shared prefix line missing'
        $alpha = Row $first.Text 'alpha'
        Assert-True ($alpha[3] -eq "$required, SMALL") "Budget selection differs: $($alpha[3])"
        $beta = Row $first.Text 'beta'
        Assert-True ($beta[3] -eq $required) "Unexpected beta documents: $($beta[3])"
        Assert-True ($alpha[4] -match '^LARGE \(\d+\)$') "Omitted LARGE not reported: $($alpha[4])"
        Assert-True ($beta[4] -match '^LARGE \(\d+\)$') "Omitted LARGE not reported for beta: $($beta[4])"
    }
    Check 'bench honors archive opt-in and rejects missing queries' {
        $root = Fixture 'archive'
        Add-Document $root 'HISTORIC' '# ancient evidence' -Level 4
        $default = Run-Cli $root @('bench', '-Query', 'ancient')
        Assert-True ($default.Code -eq 0 -and $default.Text.Contains('(archive excluded)') -and -not $default.Text.Contains('HISTORIC')) $default.Text
        $archive = Run-Cli $root @('bench', '-Query', 'ancient', '-IncludeArchive')
        Assert-True ($archive.Code -eq 0 -and $archive.Text.Contains('(archive included)') -and $archive.Text.Contains('HISTORIC')) $archive.Text
        $missing = Run-Cli $root @('bench', '-Query', ' ; ')
        Assert-True ($missing.Code -ne 0 -and $missing.Text.Contains('bench requires -Query')) $missing.Text
    }
    Check 'bench fails like context when required content exceeds the budget' {
        $root = Fixture 'overflow'
        $before = Project-Hash $root
        $result = Run-Cli $root @('bench', '-Query', 'anything', '-Budget', '10')
        Assert-True ($result.Code -ne 0 -and $result.Text.Contains('Required context needs')) $result.Text
        Assert-True ((Project-Hash $root) -eq $before) 'Failed bench changed files'
    }
} finally { if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force } }
if ($failures.Count) { throw "$($failures.Count) bench checks failed: $($failures -join '; ')" }
Write-Host 'All 4 N4ti bench checks passed'
