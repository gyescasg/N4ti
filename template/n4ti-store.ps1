function Get-N4tiStoreName([string]$Root, [switch]$AllowNew) {
    $stores = @('N4ti', 'GY') | Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) }
    if (@($stores).Count -gt 1) { throw 'Both N4ti/ and GY/ exist. Select one memory store manually; nothing was changed.' }
    if (@($stores).Count -eq 0) {
        if ($AllowNew) { return 'N4ti' }
        throw 'No memory store found. Install N4ti first.'
    }
    $name = @($stores)[0]
    $catalogPath = Join-Path $Root "$name/catalog.json"
    if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
        throw "Existing $name/ is not a valid memory store: catalog.json is missing. Nothing was changed."
    }
    try { $catalog = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Existing $name/catalog.json is invalid. Nothing was changed." }
    if ($catalog.schemaVersion -ne 2 -or $null -eq $catalog.documents) {
        throw "Existing $name/catalog.json has an unsupported structure. Nothing was changed."
    }
    return $name
}
