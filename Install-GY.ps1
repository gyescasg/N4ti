[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ProjectPath,

    [switch]$ForceTemplates
)

$ErrorActionPreference = "Stop"
$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$templateRoot = Join-Path $sourceRoot "template"
$project = [System.IO.Path]::GetFullPath($ProjectPath)

if (-not (Test-Path -LiteralPath $project -PathType Container)) {
    throw "ProjectPath does not exist: $project"
}

. (Join-Path $templateRoot 'n4ti-store.ps1')
$storeName = Get-N4tiStoreName $project -AllowNew
$gyRoot = Join-Path $project $storeName
$directories = @(
    $gyRoot,
    (Join-Path $gyRoot "tasks"),
    (Join-Path $gyRoot "decisions"),
    (Join-Path $gyRoot "knowledge"),
    (Join-Path $gyRoot "agents"),
    (Join-Path $gyRoot "policies"),
    (Join-Path $gyRoot "integrations"),
    (Join-Path $gyRoot "results"),
    (Join-Path $gyRoot "checkpoints"),
    (Join-Path $gyRoot "archive"),
    (Join-Path $gyRoot ".runtime")
)

foreach ($directory in $directories) {
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
}

$templateFiles = @(
    "GY\catalog.json",
    "GY\README.md",
    "GY\core.md",
    "GY\current-state.md",
    "GY\commands.md",
    "GY\project-profile.json",
    "GY\technology-strategy.md",
    "GY\agents\staff.json",
    "GY\policies\autonomy.json",
    "GY\policies\model-routing.json",
    "GY\policies\orchestration.json",
    "GY\integrations\openspec.json",
    "GY\results\README.md",
    "GY\knowledge\architecture.md",
    "GY\decisions\DEC-000-template.md"
)

foreach ($relativePath in $templateFiles) {
    $source = Join-Path $templateRoot $relativePath
    $destination = Join-Path $gyRoot $relativePath.Substring(3)
    if ($ForceTemplates -or -not (Test-Path -LiteralPath $destination)) {
        # Render only package-owned templates, never existing user memory.
        $text = Get-Content -LiteralPath $source -Raw -Encoding UTF8
        if ($relativePath -eq 'GY\catalog.json') {
            $catalog = $text | ConvertFrom-Json
            foreach ($document in $catalog.documents) { $document.path = $storeName + $document.path.Substring(2) }
            $text = ($catalog | ConvertTo-Json -Depth 10) + "`r`n"
        } else {
            $text = $text.Replace('GY/', "$storeName/").Replace('gy.cmd', 'n4ti.cmd').Replace('GY V2', 'N4ti')
        }
        [IO.File]::WriteAllText($destination, $text, [Text.UTF8Encoding]::new($false))
    }
}

Copy-Item -LiteralPath (Join-Path $templateRoot "gy.ps1") -Destination (Join-Path $project "gy.ps1") -Force
Copy-Item -LiteralPath (Join-Path $templateRoot "gy.cmd") -Destination (Join-Path $project "gy.cmd") -Force
foreach ($entrypoint in @('n4ti-store.ps1', 'n4ti.cmd', 'n4ti.ps1')) {
    Copy-Item -LiteralPath (Join-Path $templateRoot $entrypoint) -Destination (Join-Path $project $entrypoint) -Force
}

$statePath = Join-Path $gyRoot "current-state.md"
$state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8
if ($state.Contains("INITIALIZED_AT")) {
    $state = $state.Replace("INITIALIZED_AT", (Get-Date -Format "yyyy-MM-dd HH:mm"))
    [System.IO.File]::WriteAllText($statePath, $state, [System.Text.UTF8Encoding]::new($false))
}

function Add-ManagedBlock {
    param(
        [string]$Path,
        [string]$Content
    )

    $start = "<!-- GY-CONTEXT:START -->"
    $end = "<!-- GY-CONTEXT:END -->"
    $block = "$start`r`n$Content`r`n$end"

    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $pattern = [regex]::Escape($start) + ".*?" + [regex]::Escape($end)
        if ([regex]::IsMatch($existing, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
            $updated = [regex]::Replace($existing, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $block }, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        } else {
            $updated = $existing.TrimEnd() + "`r`n`r`n" + $block + "`r`n"
        }
    } else {
        $updated = "# Agent instructions`r`n`r`n" + $block + "`r`n"
    }

    [System.IO.File]::WriteAllText($Path, $updated, [System.Text.UTF8Encoding]::new($false))
}

$agentInstructions = @'
## N4ti orchestration protocol

1. The main agent is the orchestrator and the only canonical writer to `GY/`.
2. If `GY/project-profile.json` says semantic analysis is pending, execute `GY/.runtime/initialization-request.md` and `./gy.cmd complete-init` before product work.
3. Before changing code, run `./gy.cmd context -Query "<current request>"` and use `GY/.runtime/context-pack.md`. The pack already contains core, current state and mandatory policies; do not read those files separately. In later turns of the same conversation, add `-Since <pack id>` (printed at the end of the previous pack) to receive only new or changed content.
4. Treat OpenSpec as the requirement source when `GY/integrations/openspec.json` says it is present.
5. Delegate only when specialization, risk, or parallelism justifies a subagent.
6. Subagents must not edit `GY/`; they return concise evidence to the orchestrator, at most RESULT_TOKEN_CAP estimated tokens per result (`resultTokenCap`; `record-result` rejects larger results).
7. Ask the user only for decisions covered by `GY/policies/autonomy.json`.
8. Run relevant tests, update task/state/decisions, then run `./gy.cmd validate`.
9. Never deploy to production or merge without the configured approval.
10. Do not load `GY/archive/` unless historical evidence is necessary.
11. When requested, use `./n4ti.cmd save -Summary "progress" -Next "next step"` to record a manual checkpoint. Never include credentials or personal data. Tests and files are reported metadata, not verified evidence.
12. Use `./n4ti.cmd resume` for the latest checkpoint, or `resume -Id TASK-001` for one task. Resume is read-only; no conversation is captured automatically.
'@
# Step 6 states the cap the installed policy enforces; legacy policies without the key use 800.
$resultTokenCap = 800
$orchestrationPolicy = Get-Content -LiteralPath (Join-Path $gyRoot "policies\orchestration.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$capProperty = $orchestrationPolicy.PSObject.Properties['resultTokenCap']
if ($capProperty) {
    $capValue = $capProperty.Value
    if (-not ($capValue -is [int] -or $capValue -is [long]) -or $capValue -le 0 -or $capValue -gt [int]::MaxValue) {
        throw "$storeName/policies/orchestration.json resultTokenCap must be a positive integer; found '$capValue'."
    }
    $resultTokenCap = [int]$capValue
}
$agentInstructions = $agentInstructions.Replace('GY/', "$storeName/").Replace('gy.cmd', 'n4ti.cmd').Replace('RESULT_TOKEN_CAP', [string]$resultTokenCap)

Add-ManagedBlock -Path (Join-Path $project "AGENTS.md") -Content $agentInstructions
Add-ManagedBlock -Path (Join-Path $project "CLAUDE.md") -Content $agentInstructions

$gitignorePath = Join-Path $project ".gitignore"
$ignoreLine = "$storeName/.runtime/"
if (Test-Path -LiteralPath $gitignorePath) {
    $ignore = Get-Content -LiteralPath $gitignorePath
    if ($ignoreLine -notin $ignore) {
        Add-Content -LiteralPath $gitignorePath -Value "`r`n# Generated N4ti context packs`r`n$ignoreLine"
    }
} else {
    [System.IO.File]::WriteAllText($gitignorePath, "# Generated N4ti context packs`r`n$ignoreLine`r`n", [System.Text.UTF8Encoding]::new($false))
}

Write-Host "N4ti installed in $project (memory: $storeName/)" -ForegroundColor Green
Write-Host 'Next: run .\n4ti.cmd init -Idea "what you want to build"'
