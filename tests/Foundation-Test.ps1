$ErrorActionPreference = "Stop"
$packageRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path (Join-Path ([System.IO.Path]::GetTempPath()) "opencode") ("n4ti-foundation-" + [guid]::NewGuid().ToString("N"))
$failures = @()

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-Fixture([string]$Name) {
    $root = Join-Path $testRoot $Name
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    # Keep the original foundation contract exercised against legacy GY storage.
    Copy-Item -LiteralPath (Join-Path $packageRoot 'template/GY') -Destination $root -Recurse
    & (Join-Path $packageRoot "Install-GY.ps1") -ProjectPath $root | Out-Null
    return $root
}

function Invoke-Gy([string]$Root, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "gy.ps1") @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($output | Out-String) }
    } finally { $ErrorActionPreference = $previous }
}

function Get-StateHash([string]$Root) {
    return ((Get-ChildItem -LiteralPath (Join-Path $Root "GY") -File -Recurse | Sort-Object FullName |
        ForEach-Object { $_.FullName + ":" + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join "`n")
}

function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS: $Name" }
    catch { $script:failures += "$Name`: $($_.Exception.Message)"; Write-Host "FAIL: $($script:failures[-1])" }
}

try {
    Check "context includes framing in its token count" {
        $root = New-Fixture "context"
        $result = Invoke-Gy $root @("context", "-Query", "project rules", "-Budget", "5000")
        Assert-True ($result.ExitCode -eq 0) $result.Text
        $text = Get-Content -LiteralPath (Join-Path $root "GY/.runtime/context-pack.md") -Raw
        $reported = [regex]::Match($text, 'Estimated tokens: (\d+) / 5000').Groups[1].Value
        Assert-True ($reported -ne "" -and [int]$reported -eq [math]::Ceiling($text.Length / 4.0)) "Count must include the entire output"
        Assert-True ([int]$reported -le 5000) "Output exceeds budget"
        Assert-True ($text.Contains("## CORE") -and $text.Contains("## STATE")) "Missing mandatory context"
        $custom = Invoke-Gy $root @("context", "-Query", "project rules", "-Output", "GY/.runtime/custom.md")
        Assert-True ($custom.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $root "GY/.runtime/custom.md"))) "Default budget/custom output regressed"
    }
    Check "impossible context budget preserves existing output and memory" {
        $root = New-Fixture "overflow"
        $output = Join-Path $root "GY/.runtime/context-pack.md"
        [IO.File]::WriteAllText($output, "previous pack")
        $before = Get-StateHash $root
        $result = Invoke-Gy $root @("context", "-Query", "project", "-Budget", "1")
        Assert-True ($result.ExitCode -ne 0 -and $result.Text.Contains("Required context")) "Expected explicit budget refusal"
        Assert-True ((Get-StateHash $root) -eq $before) "Rejected context changed project files"
    }
    Check "task packet never silently omits an oversized task" {
        $root = New-Fixture "oversized-task"
        $created = Invoke-Gy $root @("new-task", "-Title", "Large task")
        Assert-True ($created.ExitCode -eq 0) $created.Text
        Add-Content -LiteralPath (Join-Path $root "GY/tasks/TASK-001.md") -Value ("Acceptance requirement. " * 1500)
        $before = Get-StateHash $root
        $result = Invoke-Gy $root @("task-packet", "-Id", "TASK-001", "-Agent", "security", "-Budget", "4000")
        Assert-True ($result.ExitCode -ne 0 -and $result.Text.Contains("Required context")) "Expected refusal instead of missing task body"
        Assert-True ((Get-StateHash $root) -eq $before) "Rejected packet changed files"
    }
    Check "normal packet includes full task and accurately counts output" {
        $root = New-Fixture "packet"
        $created = Invoke-Gy $root @("new-task", "-Title", "Unique acceptance marker")
        Assert-True ($created.ExitCode -eq 0) $created.Text
        $result = Invoke-Gy $root @("task-packet", "-Id", "TASK-001", "-Agent", "security", "-Budget", "5000")
        Assert-True ($result.ExitCode -eq 0) $result.Text
        $text = Get-Content -LiteralPath (Join-Path $root "GY/.runtime/packets/TASK-001-security.md") -Raw
        $reported = [regex]::Match($text, 'Estimated context tokens: (\d+) / 5000').Groups[1].Value
        Assert-True ($text.Contains("Unique acceptance marker") -and $text.Contains("## Acceptance Checks")) "Missing full task"
        Assert-True ($reported -ne "" -and [int]$reported -eq [math]::Ceiling($text.Length / 4.0) -and [int]$reported -le 5000) "Incorrect packet count"
    }
    Check "record-result validates task and enabled agent before writing" {
        $root = New-Fixture "result-validation"
        $created = Invoke-Gy $root @("new-task", "-Title", "Result task")
        Assert-True ($created.ExitCode -eq 0) $created.Text
        foreach ($pair in @(@("MISSING", "security"), @("CORE", "security"), @("TASK-001", "missing-role"))) {
            $before = Get-StateHash $root
            $result = Invoke-Gy $root @("record-result", "-Id", $pair[0], "-Agent", $pair[1], "-Summary", "Reported result")
            Assert-True ($result.ExitCode -ne 0 -and $result.Text.Contains("not found")) "Invalid reference was accepted"
            Assert-True ((Get-StateHash $root) -eq $before) "Rejected result changed memory"
        }
        $staffPath = Join-Path $root "GY/agents/staff.json"
        $staff = Get-Content -LiteralPath $staffPath -Raw | ConvertFrom-Json
        ($staff.roles | Where-Object id -eq "security").enabled = $false
        [IO.File]::WriteAllText($staffPath, ($staff | ConvertTo-Json -Depth 10))
        $before = Get-StateHash $root
        $result = Invoke-Gy $root @("record-result", "-Id", "TASK-001", "-Agent", "security", "-Summary", "Disabled agent")
        Assert-True ($result.ExitCode -ne 0 -and $result.Text.Contains("Enabled agent role not found")) "Disabled role accepted"
        Assert-True ((Get-StateHash $root) -eq $before) "Disabled role changed memory"
    }
    Check "same-timestamp results remain distinct and reported" {
        $root = New-Fixture "result-collision"
        $created = Invoke-Gy $root @("new-task", "-Title", "Result task")
        Assert-True ($created.ExitCode -eq 0) $created.Text
        $scriptPath = (Join-Path $root "gy.ps1").Replace("'", "''")
        # Freeze only the clock to deterministically reproduce same-second calls.
        $command = "function global:Get-Date { param([string]`$Format) '20260101000000' }; & '$scriptPath' record-result -Id TASK-001 -Agent security -Summary first; & '$scriptPath' record-result -Id TASK-001 -Agent security -Summary second"
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command
        Assert-True ($LASTEXITCODE -eq 0) ($output | Out-String)
        $files = @(Get-ChildItem -LiteralPath (Join-Path $root "GY/results") -Filter "TASK-001-security-*.json")
        Assert-True ($files.Count -eq 2) "A result was overwritten"
        $results = @($files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
        Assert-True ((@($results.summary | Sort-Object) -join ',') -eq "first,second") "Result contents lost"
        Assert-True (@($results | Where-Object { $_.status -ne "reported" -or $_.integratedByOrchestrator }).Count -eq 0) "Results incorrectly marked verified"
    }
    Check "close-task rejects non-task documents without mutation" {
        $root = New-Fixture "invalid-close"
        $before = Get-StateHash $root
        $result = Invoke-Gy $root @("close-task", "-Id", "CORE", "-Summary", "Wrong type", "-Next", "None")
        Assert-True ($result.ExitCode -ne 0 -and $result.Text.Contains("Task not found")) "Non-task accepted"
        Assert-True ((Get-StateHash $root) -eq $before) "Invalid close changed memory"
    }
    Check "closing another task preserves current state; active closure still works" {
        $root = New-Fixture "active-state"
        foreach ($title in @("First task", "Second task")) {
            $created = Invoke-Gy $root @("new-task", "-Title", $title)
            Assert-True ($created.ExitCode -eq 0) $created.Text
        }
        $statePath = Join-Path $root "GY/current-state.md"
        $before = (Get-FileHash -LiteralPath $statePath).Hash
        $result = Invoke-Gy $root @("close-task", "-Id", "TASK-001", "-Summary", "First complete", "-Next", "Unrelated next step")
        Assert-True ($result.ExitCode -eq 0 -and $result.Text.Contains("Closed TASK-001")) $result.Text
        Assert-True ((Get-FileHash -LiteralPath $statePath).Hash -eq $before) "Unrelated close overwrote active state"
        $catalog = Get-Content -LiteralPath (Join-Path $root "GY/catalog.json") -Raw | ConvertFrom-Json
        Assert-True (($catalog.documents | Where-Object id -eq 'TASK-001').status -eq 'completed') "Task did not close"
        $result = Invoke-Gy $root @("close-task", "-Id", "TASK-002", "-Summary", "Second complete", "-Next", "Plan next task")
        Assert-True ($result.ExitCode -eq 0) $result.Text
        $state = Invoke-Gy $root @("status")
        Assert-True ($state.ExitCode -eq 0 -and $state.Text.Contains("- Active task: none") -and $state.Text.Contains("Plan next task")) "Active closure/status regressed"
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
if ($failures.Count -gt 0) { throw "$($failures.Count) foundation checks failed: $($failures -join '; ')" }
Write-Host "All 8 N4ti foundation checks passed"
