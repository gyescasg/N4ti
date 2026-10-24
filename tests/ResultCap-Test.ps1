$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'opencode') ('n4ti-resultcap-' + [guid]::NewGuid().ToString('N'))
$failures = @()
# Summaries of repeated 'x' serialize without escaping, so their size is predictable.
$small = 'x' * 100
$large = 'x' * 4000
$medium = 'x' * 1200

function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Fixture([string]$Name) {
    $root = Join-Path $testRoot $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    & (Join-Path $packageRoot 'Install-N4ti.ps1') -ProjectPath $root | Out-Null
    $created = Run-Cli $root @('new-task', '-Title', 'Result cap task')
    Assert-True ($created.Code -eq 0) $created.Text
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
function Record([string]$Root, [string]$Summary) {
    return Run-Cli $Root @('record-result', '-Id', 'TASK-001', '-Agent', 'implementer', '-Summary', $Summary)
}
function Result-Count([string]$Root) { return @(Get-ChildItem -LiteralPath (Join-Path $Root 'N4ti/results') -Filter '*.json' -File).Count }
function Set-Cap([string]$Root, $Value, [switch]$Remove) {
    $path = Join-Path $Root 'N4ti/policies/orchestration.json'
    $policy = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $policy.PSObject.Properties.Remove('resultTokenCap')
    if (-not $Remove) { $policy | Add-Member -NotePropertyName 'resultTokenCap' -NotePropertyValue $Value }
    [IO.File]::WriteAllText($path, ($policy | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
}
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS: $Name" }
    catch { $script:failures += "$Name`: $($_.Exception.Message)"; Write-Host "FAIL: $($script:failures[-1])" }
}

try {
    Check 'an over-cap result is rejected and nothing is written' {
        $root = Fixture 'over'
        $result = Record $root $large
        Assert-True ($result.Code -ne 0) "Over-cap result was accepted: $($result.Text)"
        Assert-True ($result.Text -match 'about (\d+) est\. tokens exceeds resultTokenCap 800\. No result was written\.' -and [int]$Matches[1] -gt 800) $result.Text
        Assert-True ((Result-Count $root) -eq 0) 'A rejected result left a file'
    }
    Check 'an under-cap result is saved' {
        $root = Fixture 'under'
        $result = Record $root $small
        Assert-True ($result.Code -eq 0 -and $result.Text.Contains('Result recorded')) $result.Text
        Assert-True ((Result-Count $root) -eq 1) 'The result was not saved'
    }
    Check 'a configured resultTokenCap is honored' {
        $root = Fixture 'custom'
        $accepted = Record $root $medium
        Assert-True ($accepted.Code -eq 0) "Default cap rejected a medium result: $($accepted.Text)"
        Set-Cap $root 200
        $rejected = Record $root $medium
        Assert-True ($rejected.Code -ne 0 -and $rejected.Text.Contains('exceeds resultTokenCap 200')) $rejected.Text
        Assert-True ((Result-Count $root) -eq 1) 'The lower cap still wrote a result'
    }
    Check 'a policy without resultTokenCap defaults to 800' {
        $root = Fixture 'legacy'
        Set-Cap $root $null -Remove
        Assert-True ((Record $root $small).Code -eq 0) 'Legacy policy rejected a small result'
        $rejected = Record $root $large
        Assert-True ($rejected.Code -ne 0 -and $rejected.Text.Contains('exceeds resultTokenCap 800')) $rejected.Text
        Assert-True ((Result-Count $root) -eq 1) 'Legacy policy wrote an over-cap result'
    }
    Check 'an invalid resultTokenCap fails record-result and validate' {
        $root = Fixture 'invalid'
        foreach ($value in @(0, -5, 1.5, 'many')) {
            Set-Cap $root $value
            $result = Record $root $small
            Assert-True ($result.Code -ne 0 -and $result.Text.Contains('resultTokenCap must be a positive integer')) "record-result accepted cap '$value': $($result.Text)"
            $validation = Run-Cli $root @('validate')
            Assert-True ($validation.Code -ne 0 -and $validation.Text.Contains('resultTokenCap must be a positive integer')) "validate accepted cap '$value': $($validation.Text)"
        }
        Assert-True ((Result-Count $root) -eq 0) 'An invalid cap wrote a result'
    }
    Check 'validate only warns for an existing over-cap result file' {
        $root = Fixture 'validate'
        Set-Cap $root 200
        [IO.File]::WriteAllText((Join-Path $root 'N4ti/results/TASK-001-old.json'), "{ `"summary`": `"$medium`" }", [Text.UTF8Encoding]::new($false))
        $validation = Run-Cli $root @('validate')
        Assert-True ($validation.Code -eq 0) $validation.Text
        Assert-True ($validation.Text -match 'WARNING: TASK-001-old\.json is about \d+ tokens; resultTokenCap is 200') $validation.Text
    }
    Check 'task-packet contract and host protocol state the cap' {
        $root = Fixture 'packet'
        Assert-True ((Get-Content (Join-Path $root 'AGENTS.md') -Raw) -match '6\. [^\r\n]*800 estimated tokens') 'Host protocol step 6 lacks the cap'
        Set-Cap $root 640
        $packet = Run-Cli $root @('task-packet', '-Id', 'TASK-001', '-Agent', 'implementer', '-Budget', '5000')
        Assert-True ($packet.Code -eq 0) $packet.Text
        $text = Get-Content (Join-Path $root 'N4ti/.runtime/packets/TASK-001-implementer.md') -Raw -Encoding UTF8
        Assert-True ($text -match '## Contract[\s\S]*640 estimated tokens') 'Task packet contract lacks the configured cap'
    }
} finally { if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force } }
if ($failures.Count) { throw "$($failures.Count) result cap checks failed: $($failures -join '; ')" }
Write-Host 'All 7 N4ti result cap checks passed'
