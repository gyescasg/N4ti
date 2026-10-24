$ErrorActionPreference = "Stop"
$packageRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path (Join-Path ([IO.Path]::GetTempPath()) "opencode") ("n4ti-memory-" + [guid]::NewGuid().ToString('N'))
$failures = @()

function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Run-Script([string]$Script, [string[]]$Arguments) {
    $quoted = @("'" + $Script.Replace("'", "''") + "'")
    $expectValue = $false
    foreach ($argument in $Arguments) {
        if (-not $expectValue -and $argument -match '^-[A-Za-z]+$') {
            $quoted += $argument
            $expectValue = $true
        } else {
            $quoted += "'" + $argument.Replace("'", "''") + "'"
            $expectValue = $false
        }
    }
    $command = "[Console]::OutputEncoding = [Text.UTF8Encoding]::new(`$false); & " + ($quoted -join ' ')
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = "powershell.exe"
    $info.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand " + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $process = [Diagnostics.Process]::Start($info)
    try {
        # Drain both streams concurrently: PowerShell's host records can fill stderr.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(20000)) {
            $process.Kill()
            throw "Test command timed out: $Script"
        }
        $text = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        return [pscustomobject]@{ Code = $process.ExitCode; Text = $text; Error = $errorText }
    } finally { $process.Dispose() }
}
function Run-Gy([string]$Root, [string[]]$Arguments) { Run-Script (Join-Path $Root 'gy.ps1') $Arguments }
function Hash-Files([string]$Root) {
    return ((Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName | ForEach-Object {
        $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash
    }) -join "`n")
}
function Fixture([string]$Name) {
    $root = Join-Path $testRoot $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $result = Run-Script (Join-Path $packageRoot 'Install-GY.ps1') @('-ProjectPath', $root)
    Assert-True ($result.Code -eq 0) $result.Error
    return $root
}
function Store([string]$Root) {
    if (Test-Path -LiteralPath (Join-Path $Root 'N4ti')) { return Join-Path $Root 'N4ti' }
    return Join-Path $Root 'GY'
}
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS: $Name" }
    catch { $script:failures += "$Name`: $($_.Exception.Message)"; Write-Host "FAIL: $($script:failures[-1])" }
}

try {
    Check 'fresh N4ti store, catalog paths and both aliases' {
        $root = Fixture 'fresh'
        Assert-True ((Test-Path (Join-Path $root 'N4ti/catalog.json')) -and -not (Test-Path (Join-Path $root 'GY'))) 'Fresh install must use only N4ti'
        foreach ($file in @('n4ti.cmd', 'n4ti.ps1', 'gy.cmd', 'gy.ps1')) { Assert-True (Test-Path (Join-Path $root $file)) "Missing $file" }
        $first = Run-Gy $root @('new-task', '-Title', 'Shared alias task')
        $second = Run-Script (Join-Path $root 'n4ti.ps1') @('status')
        Assert-True ($first.Code -eq 0 -and $second.Code -eq 0 -and $second.Text.Contains('TASK-001')) 'Aliases must use one task state'
        $catalog = Get-Content (Join-Path $root 'N4ti/catalog.json') -Raw | ConvertFrom-Json
        Assert-True (@($catalog.documents | Where-Object { -not $_.path.StartsWith('N4ti/') }).Count -eq 0) 'Catalog references old store'
        $context = Run-Gy $root @('context', '-Query', 'rules')
        Assert-True ($context.Code -eq 0 -and (Test-Path (Join-Path $root 'N4ti/.runtime/context-pack.md'))) 'Default context path wrong'
        $validation = Run-Gy $root @('validate')
        Assert-True ($validation.Code -eq 0) $validation.Error
        $init = Run-Gy $root @('init', '-Idea', 'A lightweight project')
        Assert-True ($init.Code -eq 0) $init.Error
        $request = Get-Content (Join-Path $root 'N4ti/.runtime/initialization-request.md') -Raw
        Assert-True ($request.Contains('n4ti.cmd complete-init') -and -not $request.Contains('GY/')) 'Initialization generated stale or escaped command'
    }
    Check 'legacy upgrades preserve memory and managed-block idempotence' {
        $root = Join-Path $testRoot 'legacy'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        Copy-Item (Join-Path $packageRoot 'template/GY') -Destination $root -Recurse
        $statePath = Join-Path $root 'GY/current-state.md'
        [IO.File]::WriteAllText($statePath, (Get-Content $statePath -Raw).Replace('INITIALIZED_AT', '2026-01-01'))
        Add-Content (Join-Path $root 'GY/core.md') 'User literal: $1 GY/ and original project notes.'
        [IO.File]::WriteAllText((Join-Path $root 'AGENTS.md'), 'User instructions: $& and $1 must survive.')
        $before = Hash-Files (Join-Path $root 'GY')
        $installed = Run-Script (Join-Path $packageRoot 'Install-GY.ps1') @('-ProjectPath', $root)
        Assert-True ($installed.Code -eq 0) $installed.Error
        Assert-True ((Hash-Files (Join-Path $root 'GY')) -eq $before) 'Upgrade changed existing memory'
        Assert-True (-not (Test-Path (Join-Path $root 'N4ti'))) 'Upgrade created a second store'
        $instructions = Get-Content (Join-Path $root 'AGENTS.md') -Raw
        $again = Run-Script (Join-Path $packageRoot 'Install-GY.ps1') @('-ProjectPath', $root)
        Assert-True ($again.Code -eq 0 -and (Get-Content (Join-Path $root 'AGENTS.md') -Raw) -eq $instructions) 'Managed block is not idempotent'
        Assert-True ($instructions.Contains('User instructions: $& and $1 must survive.') -and $instructions.Contains('n4ti.cmd')) 'User text or new command lost'
        $alias = Run-Script (Join-Path $root 'n4ti.ps1') @('save', '-Summary', 'Legacy checkpoint', '-Next', 'Continue')
        Assert-True ($alias.Code -eq 0 -and (Test-Path (Join-Path $root 'GY/checkpoints'))) 'New alias cannot save to legacy store'
    }
    Check 'dual or malformed stores refuse without changes' {
        $root = Fixture 'dual'
        $other = if ((Split-Path (Store $root) -Leaf) -eq 'GY') { 'N4ti' } else { 'GY' }
        Copy-Item (Store $root) (Join-Path $root $other) -Recurse
        $before = Hash-Files $root
        $installed = Run-Script (Join-Path $packageRoot 'Install-GY.ps1') @('-ProjectPath', $root)
        $status = Run-Gy $root @('status')
        Assert-True ($installed.Code -ne 0 -and $status.Code -ne 0) 'Ambiguous stores accepted'
        Assert-True ((Hash-Files $root) -eq $before) 'Ambiguity changed files'
        $bad = Join-Path $testRoot 'malformed'
        [IO.Directory]::CreateDirectory((Join-Path $bad 'N4ti')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $bad 'N4ti/catalog.json'), '{broken')
        $before = Hash-Files $bad
        $installed = Run-Script (Join-Path $packageRoot 'Install-GY.ps1') @('-ProjectPath', $bad)
        Assert-True ($installed.Code -ne 0 -and (Hash-Files $bad) -eq $before) 'Malformed store was replaced'
    }
    Check 'save and resume preserve literal Unicode multiline progress without changing state' {
        $root = Fixture 'literal'
        $summary = 'Literal $1 $& price $5, quote '' and ' + [char]0x00F1 + "`nSecond line"
        $before = Hash-Files (Store $root)
        $save = Run-Gy $root @('save', '-Summary', $summary, '-Next', 'Review $1', '-Files', 'src/a.ps1', '-Tests', 'reported only', '-Risks', 'pending review')
        Assert-True ($save.Code -eq 0) $save.Error
        $files = @(Get-ChildItem (Join-Path (Store $root) 'checkpoints') -Filter '*.json')
        Assert-True ($files.Count -eq 1) 'Checkpoint missing'
        $record = Get-Content $files[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($record.summary -ceq $summary -and $record.next -ceq 'Review $1') 'Literal content changed'
        Assert-True ($record.status -eq 'reported' -and $record.verified -eq $false) 'Claimed verification'
        $withoutCheckpoints = ((Get-ChildItem (Store $root) -File -Recurse | Where-Object { $_.Directory.Name -ne 'checkpoints' } | Sort-Object FullName | ForEach-Object { $_.FullName + ':' + (Get-FileHash $_.FullName).Hash }) -join "`n")
        Assert-True ($withoutCheckpoints -eq $before) 'Save modified canonical state'
        $beforeResume = Hash-Files $root
        $resume = Run-Gy $root @('resume')
        Assert-True ($resume.Code -eq 0 -and $resume.Text.Contains($summary) -and $resume.Text.Contains('Review $1')) 'Resume lost progress'
        Assert-True ((Hash-Files $root) -eq $beforeResume) 'Resume wrote files'
    }
    Check 'unique saves, task filtering and project isolation' {
        $root = Fixture 'filter'
        $created = Run-Gy $root @('new-task', '-Title', 'Checkpoint task')
        Assert-True ($created.Code -eq 0) $created.Error
        foreach ($summary in @('task-first', 'task-second')) {
            $save = Run-Gy $root @('save', '-Id', 'TASK-001', '-Summary', $summary, '-Next', 'next-task')
            Assert-True ($save.Code -eq 0) $save.Error
        }
        $save = Run-Gy $root @('save', '-Summary', 'project-latest', '-Next', 'next-project')
        Assert-True ($save.Code -eq 0) $save.Error
        Assert-True (@(Get-ChildItem (Join-Path (Store $root) 'checkpoints') -Filter '*.json').Count -eq 3) 'Saves collided'
        $task = Run-Gy $root @('resume', '-Id', 'TASK-001')
        $project = Run-Gy $root @('resume')
        Assert-True ($task.Code -eq 0 -and $task.Text.Contains('task-second') -and -not $task.Text.Contains('project-latest')) 'Task filter wrong'
        Assert-True ($project.Code -eq 0 -and $project.Text.Contains('project-latest')) 'Latest project checkpoint wrong'
        $other = Fixture 'isolated'
        $empty = Run-Gy $other @('resume')
        Assert-True ($empty.Code -eq 0 -and $empty.Text.Contains('No checkpoints') -and -not $empty.Text.Contains('project-latest')) 'Cross-project leakage'
    }
    Check 'invalid save and insufficient resume budget preserve all files' {
        $root = Fixture 'rejections'
        foreach ($arguments in @(@('save', '-Summary', 'missing next'), @('save', '-Id', 'CORE', '-Summary', 'invalid task', '-Next', 'next'))) {
            $before = Hash-Files $root
            $result = Run-Gy $root $arguments
            Assert-True ($result.Code -ne 0 -and (Hash-Files $root) -eq $before) 'Invalid save changed files'
        }
        $save = Run-Gy $root @('save', '-Summary', ('long progress ' * 100), '-Next', 'next')
        Assert-True ($save.Code -eq 0) $save.Error
        $before = Hash-Files $root
        $result = Run-Gy $root @('resume', '-Budget', '1')
        Assert-True ($result.Code -ne 0 -and $result.Error.Contains('Required context') -and (Hash-Files $root) -eq $before) 'Insufficient resume budget accepted or mutated files'
        $result = Run-Gy $root @('resume', '-Budget', '5000')
        $count = [regex]::Match($result.Text, 'Estimated tokens: (\d+) / 5000').Groups[1].Value
        Assert-True ($result.Code -eq 0 -and $count -ne '' -and [int]$count -eq [math]::Ceiling($result.Text.Length / 4.0)) 'Resume count excludes output framing'
        $negative = Run-Gy $root @('resume', '-Budget', '-1')
        Assert-True ($negative.Code -ne 0 -and (Hash-Files $root) -eq $before) 'Negative budget silently ignored'
    }
    Check 'failed checkpoint publication leaves no partial JSON' {
        $root = Fixture 'publication'
        $checkpoints = Join-Path (Store $root) 'checkpoints'
        if (Test-Path $checkpoints) { Remove-Item $checkpoints -Recurse -Force }
        [IO.File]::WriteAllText($checkpoints, 'blocked directory')
        $before = Hash-Files $root
        $result = Run-Gy $root @('save', '-Summary', 'cannot publish', '-Next', 'retry later')
        Assert-True ($result.Code -ne 0 -and (Hash-Files $root) -eq $before) 'Failed save left partial data'
    }
    Check 'repeated decisions retain unique IDs' {
        $root = Fixture 'decisions'
        foreach ($title in @('First', 'Second')) {
            $result = Run-Gy $root @('new-decision', '-Title', $title, '-Summary', 'Evidence')
            Assert-True ($result.Code -eq 0) $result.Error
        }
        Assert-True ((Test-Path (Join-Path (Store $root) 'decisions/DEC-001.md')) -and (Test-Path (Join-Path (Store $root) 'decisions/DEC-002.md'))) 'Decision IDs incorrect'
    }
} finally { if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force } }
if ($failures.Count) { throw "$($failures.Count) memory checks failed: $($failures -join '; ')" }
Write-Host 'All 8 N4ti memory checks passed'
