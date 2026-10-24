$ErrorActionPreference = "Stop"
$packageRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("GY-smoke-" + [guid]::NewGuid().ToString("N"))

try {
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
    # Explicit legacy fixture: fresh N4ti storage is exercised by Memory-Test.ps1.
    Copy-Item -LiteralPath (Join-Path $packageRoot 'template/GY') -Destination $testRoot -Recurse
    [System.IO.Directory]::CreateDirectory((Join-Path $testRoot "openspec")) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $testRoot "package.json"), '{"name":"gy-smoke"}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $testRoot "CHECKPOINT.md"), "# Checkpoint`r`n`r`nExisting project state.", [System.Text.UTF8Encoding]::new($false))

    & (Join-Path $packageRoot "Install-GY.ps1") -ProjectPath $testRoot
    & (Join-Path $testRoot "gy.ps1") init -Idea "A secure customer portal" -InitMode guided -ModelMode adaptive -MaxParallel 3

    $profilePath = Join-Path $testRoot "GY/project-profile.json"
    $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    $profile.audience = "customer support staff"
    $profile.primaryOutcome = "manage secure customer access"
    [System.IO.File]::WriteAllText($profilePath, ($profile | ConvertTo-Json -Depth 12) + "`r`n", [System.Text.UTF8Encoding]::new($false))

    $corePath = Join-Path $testRoot "GY/core.md"
    $core = (Get-Content -LiteralPath $corePath -Raw).Replace("Describe in two or three sentences what this project delivers and for whom.", "A secure customer portal for support staff.").Replace("TODO", "configured")
    [System.IO.File]::WriteAllText($corePath, $core, [System.Text.UTF8Encoding]::new($false))
    $commandsPath = Join-Path $testRoot "GY/commands.md"
    $commands = (Get-Content -LiteralPath $commandsPath -Raw).Replace("# TODO", "npm test")
    [System.IO.File]::WriteAllText($commandsPath, $commands, [System.Text.UTF8Encoding]::new($false))
    $strategyPath = Join-Path $testRoot "GY/technology-strategy.md"
    $strategy = (Get-Content -LiteralPath $strategyPath -Raw).Replace("Pending semantic analysis by the orchestrator.", "Keep the detected Node.js stack.")
    [System.IO.File]::WriteAllText($strategyPath, $strategy, [System.Text.UTF8Encoding]::new($false))
    & (Join-Path $testRoot "gy.ps1") complete-init

    & (Join-Path $testRoot "gy.ps1") new-task -Title "Implement secure login" -Tags "auth,security,openspec"
    & (Join-Path $testRoot "gy.ps1") route -Agent security
    & (Join-Path $testRoot "gy.ps1") task-packet -Id TASK-001 -Agent security -Budget 2500
    & (Join-Path $testRoot "gy.ps1") record-result -Id TASK-001 -Agent security -Summary "Security review completed" -Tests "auth.test.js" -Risks "user enumeration"
    & (Join-Path $testRoot "gy.ps1") validate

    $profile = Get-Content -LiteralPath (Join-Path $testRoot "GY/project-profile.json") -Raw | ConvertFrom-Json
    if ($profile.projectStage -ne "existing") { throw "Expected existing project detection" }
    if ($profile.semanticAnalysis -ne "complete") { throw "Expected completed semantic initialization" }
    if ($profile.openspecPath -ne "openspec") { throw "Expected OpenSpec detection" }
    if ($profile.checkpointFiles -notcontains "CHECKPOINT.md") { throw "Expected checkpoint detection" }
    if (-not (Test-Path -LiteralPath (Join-Path $testRoot "GY/.runtime/packets/TASK-001-security.md"))) { throw "Missing task packet" }
    if (@(Get-ChildItem -LiteralPath (Join-Path $testRoot "GY/results") -Filter "TASK-001-security-*.json").Count -ne 1) { throw "Missing structured result" }

    Write-Host "GY V2 smoke test passed" -ForegroundColor Green
}
finally {
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    if ($resolvedTestRoot.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
