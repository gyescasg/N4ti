[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("init", "complete-init", "status", "search", "context", "bench", "get", "route", "task-packet", "record-result", "new-task", "close-task", "new-decision", "compact", "validate", "save", "resume", "help")]
    [string]$Command = "help",

    [string]$Query,
    [string]$Title,
    [string]$Tags,
    [string]$Id,
    [string]$Summary,
    [string]$Next,
    [string]$Affects,
    [string]$Idea,
    [ValidateSet("quick", "guided")]
    [string]$InitMode = "quick",
    [ValidateSet("uniform", "adaptive", "manual")]
    [string]$ModelMode = "uniform",
    [string]$DefaultModel = "auto",
    [string]$Agent,
    [string]$Files,
    [string]$Tests,
    [string]$Risks,
    [string]$Decisions,
    [ValidateRange(1, 8)]
    [int]$MaxParallel = 2,
    [int]$KeepCompleted = 5,
    [int]$Budget = 0,
    [switch]$IncludeArchive,
    [string]$Supersedes,
    [string]$Since,
    [string]$Output
)

$ErrorActionPreference = "Stop"
if ($PSBoundParameters.ContainsKey('IncludeArchive') -and $Command -notin @('search', 'context', 'bench', 'task-packet')) {
    throw '-IncludeArchive is supported only by search, context, bench, and task-packet.'
}
if ($PSBoundParameters.ContainsKey('Supersedes') -and $Command -ne 'new-decision') {
    throw '-Supersedes is supported only by new-decision.'
}
if ($PSBoundParameters.ContainsKey('Since') -and $Command -ne 'context') {
    throw '-Since is supported only by context.'
}
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $projectRoot 'n4ti-store.ps1')
$storeName = Get-N4tiStoreName $projectRoot -AllowNew:($Command -eq 'help')
$catalogPath = Join-Path $projectRoot "$storeName/catalog.json"
if (-not $PSBoundParameters.ContainsKey('Output')) { $Output = "$storeName/.runtime/context-pack.md" }

function Get-Catalog {
    if (-not (Test-Path -LiteralPath $catalogPath)) {
        throw "Missing $storeName/catalog.json. Install N4ti first."
    }
    return Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-Catalog($Catalog) {
    $json = $Catalog | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($catalogPath, $json + "`r`n", [System.Text.UTF8Encoding]::new($false))
}

function Get-JsonFileText($Value) { return ($Value | ConvertTo-Json -Depth 12) + "`r`n" }

function Save-JsonFile([string]$RelativePath, $Value) {
    $path = Resolve-ProjectPath $RelativePath
    [System.IO.File]::WriteAllText($path, (Get-JsonFileText $Value), [System.Text.UTF8Encoding]::new($false))
}

function Get-ResultTokenCap {
    # Legacy installs without the key keep the historical 800 target.
    $path = Resolve-ProjectPath "$storeName/policies/orchestration.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 800 }
    $policy = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $property = $policy.PSObject.Properties['resultTokenCap']
    if (-not $property) { return 800 }
    $value = $property.Value
    if (-not ($value -is [int] -or $value -is [long]) -or $value -le 0 -or $value -gt [int]::MaxValue) {
        throw "$storeName/policies/orchestration.json resultTokenCap must be a positive integer; found '$value'."
    }
    return [int]$value
}

function Get-RelativeProjectPath([string]$FullPath) {
    $root = $projectRoot.TrimEnd('\') + '\'
    if ($FullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $FullPath.Substring($root.Length).Replace('\', '/')
    }
    return $FullPath
}

function Get-ProjectSignals {
    $signals = [System.Collections.Generic.List[string]]::new()
    $markers = @(
        @{ Path = "package.json"; Signal = "node" },
        @{ Path = "pyproject.toml"; Signal = "python" },
        @{ Path = "requirements.txt"; Signal = "python" },
        @{ Path = "go.mod"; Signal = "go" },
        @{ Path = "Cargo.toml"; Signal = "rust" },
        @{ Path = "pubspec.yaml"; Signal = "flutter-dart" },
        @{ Path = "composer.json"; Signal = "php" },
        @{ Path = "pom.xml"; Signal = "java-maven" },
        @{ Path = "build.gradle"; Signal = "java-gradle" },
        @{ Path = "Dockerfile"; Signal = "docker" },
        @{ Path = "docker-compose.yml"; Signal = "docker-compose" },
        @{ Path = "docker-compose.yaml"; Signal = "docker-compose" }
    )
    foreach ($marker in $markers) {
        if (Test-Path -LiteralPath (Join-Path $projectRoot $marker.Path)) { $signals.Add($marker.Signal) }
    }
    if (@(Get-ChildItem -LiteralPath $projectRoot -Filter "*.sln" -File -ErrorAction SilentlyContinue).Count -gt 0) { $signals.Add("dotnet") }
    if (@(Get-ChildItem -LiteralPath $projectRoot -Filter "*.csproj" -File -ErrorAction SilentlyContinue).Count -gt 0) { $signals.Add("dotnet") }
    if (Test-Path -LiteralPath (Join-Path $projectRoot ".github/workflows")) { $signals.Add("github-actions") }
    if (Test-Path -LiteralPath (Join-Path $projectRoot ".git")) { $signals.Add("git") }
    return @($signals | Select-Object -Unique)
}

function Find-CheckpointFiles {
    $found = @()
    $searchRoots = @($projectRoot, (Join-Path $projectRoot "docs"), (Join-Path $projectRoot ".claude"), (Join-Path $projectRoot ".codex"))
    foreach ($root in $searchRoots | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $found += Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "(?i)checkpoint.*\.md$|.*checkpoint\.md$" }
    }
    return @($found | Sort-Object FullName -Unique | Select-Object -First 10 | ForEach-Object { Get-RelativeProjectPath $_.FullName })
}

function Find-OpenSpecPath {
    foreach ($candidate in @("openspec", "OpenSpec", ".openspec")) {
        $path = Join-Path $projectRoot $candidate
        if (Test-Path -LiteralPath $path -PathType Container) { return $candidate }
    }
    return $null
}

function Get-TokenEstimate([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    return [math]::Ceiling($Text.Length / 4.0)
}

# Pack layout: title, documents, then request details and counters. Stable content
# comes first so packs for different requests share a cacheable prefix.
function Split-PackHeader([string]$Header) {
    $lines = @($Header.TrimEnd() -split "`r?`n")
    $details = (@($lines | Select-Object -Skip 1) -join "`r`n").Trim()
    return [pscustomobject]@{ Title = $lines[0]; Details = $details }
}

function Get-PackBlock($Row) {
    return "`r`n---`r`n`r`n## $($Row.Id) | L$($Row.Level) | $($Row.Path)`r`n`r`n$($Row.Content.Trim())`r`n"
}

function Get-PackFixedText($Parts, [string[]]$Ids) {
    $details = if ($Parts.Details) { "$($Parts.Details)`r`n" } else { '' }
    $fixed = [pscustomobject]@{
        Head = "$($Parts.Title)`r`n"
        Middle = "`r`n---`r`n`r`n$details"
        Documents = "- Documents: $(if ($Ids.Count) { $Ids -join ', ' } else { 'none' })`r`n"
        Length = 0
    }
    $fixed.Length = $fixed.Head.Length + $fixed.Middle.Length + $fixed.Documents.Length
    return $fixed
}

function Get-PackCountLine([int]$Estimate, [int]$Limit, [string]$TokenLabel) {
    return "- ${TokenLabel}: $Estimate / $Limit`r`n"
}

function Measure-PackTokens([int]$Length, [int]$Limit, [string]$TokenLabel) {
    # Include the count line itself in the estimate. Its width stabilizes quickly.
    $estimate = 0
    do {
        $previous = $estimate
        $estimate = [int][math]::Ceiling(($Length + (Get-PackCountLine $estimate $Limit $TokenLabel).Length) / 4.0)
    } while ($estimate -ne $previous)
    return $estimate
}

function Get-PackIndexText([string[]]$Lines) {
    if ($Lines.Count -eq 0) { return '' }
    return "`r`n---`r`n`r`n## Not included`r`n`r`nRetrieve with: n4ti get -Id <ID>`r`n`r`n" + (($Lines | ForEach-Object { "$_`r`n" }) -join '')
}

function Get-PackIndexLine($Row) {
    return "- $($Row.Id) | $($Row.Tokens) tokens | $($Row.Label)"
}

function Get-PackLength($Rows, $Parts, [string[]]$IndexLines = @(), [int]$ReservedLength = 0) {
    $fixed = Get-PackFixedText $Parts @($Rows | ForEach-Object { $_.Id })
    $blocks = 0
    foreach ($row in $Rows) { $blocks += (Get-PackBlock $row).Length }
    return $fixed.Length + $blocks + (Get-PackIndexText $IndexLines).Length + $ReservedLength
}

# ReservedLength counts trailing text appended after rendering (the pack id line).
function Format-ContextPack($Rows, [string]$Header, [int]$Limit, [string]$TokenLabel, [string[]]$IndexLines = @(), [string]$Trailer = '', [int]$ReservedLength = 0) {
    $fixed = Get-PackFixedText (Split-PackHeader $Header) @($Rows | ForEach-Object { $_.Id })
    $blocks = (@($Rows | ForEach-Object { Get-PackBlock $_ }) -join '')
    $index = Get-PackIndexText $IndexLines
    $estimate = Measure-PackTokens ($fixed.Length + $blocks.Length + $index.Length + $Trailer.Length + $ReservedLength) $Limit $TokenLabel
    $text = $fixed.Head + $blocks + $index + $fixed.Middle + (Get-PackCountLine $estimate $Limit $TokenLabel) + $fixed.Documents + $Trailer
    return [pscustomobject]@{ Text = $text; Tokens = $estimate; Rows = @($Rows); Covered = @(); Indexed = @($IndexLines) }
}

function Merge-CompleteDocuments($Rows) {
    # Optional sections are grouped by document; a fully selected document becomes one block again.
    $order = [Collections.Generic.List[string]]::new()
    foreach ($row in $Rows) { if (-not $order.Contains($row.DocumentId)) { $order.Add($row.DocumentId) } }
    $merged = @()
    foreach ($documentId in $order) {
        $group = @($Rows | Where-Object { $_.DocumentId -eq $documentId } | Sort-Object SectionIndex)
        if ($group[0].SectionIndex -ge 0 -and $group.Count -eq $group[0].SectionCount) {
            $whole = $group[0].PSObject.Copy()
            $whole.Id = $documentId
            $whole.SectionIndex = -1
            $whole.Content = $whole.DocumentContent
            $merged += $whole
        } else { $merged += $group }
    }
    return $merged
}

function New-BoundedContextPack($Rows, [string]$Header, [int]$Limit, [string]$TokenLabel, [string[]]$RequiredIds = @(), [int]$ReservedLength = 0) {
    # Catalog-mandatory documents keep a fixed order; assigned items follow them.
    $mandatory = @($Rows | Where-Object { $_.AlwaysLoad -or $_.Priority -eq "critical" } | Sort-Object Level, Id)
    $assigned = @($Rows | Where-Object { $_.Id -in $RequiredIds -and $_.Id -notin $mandatory.Id })
    $selected = @($mandatory + $assigned)
    # Only optional copies may be skipped. Required sources retain their identity.
    $contents = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $selected) { [void]$contents.Add($row.Content.Trim()) }
    $parts = Split-PackHeader $Header
    $ids = [Collections.Generic.List[string]]::new()
    foreach ($row in $selected) { $ids.Add($row.Id) }
    $blocksLength = 0
    foreach ($row in $selected) { $blocksLength += (Get-PackBlock $row).Length }
    $length = (Get-PackFixedText $parts $ids.ToArray()).Length + $blocksLength + $ReservedLength
    $tokens = Measure-PackTokens $length $Limit $TokenLabel
    if ($tokens -gt $Limit) {
        throw "Required context needs $tokens estimated tokens; budget is $Limit. Increase -Budget or reduce required documents. No output was written."
    }
    # Each candidate only adds its block and its ID; the pack is rendered once at the end.
    $optional = @()
    $omitted = @()
    # Optional units far below the best match go to the index instead of the pack.
    $candidates = @($Rows | Where-Object { $_.Id -notin $selected.Id -and $_.Matches -gt 0 })
    $bestRelevance = [double](($candidates | Measure-Object -Property Relevance -Maximum).Maximum)
    foreach ($row in $candidates) {
        if ([double]$row.Relevance -lt $relevanceCutoff * $bestRelevance) { $omitted += $row; continue }
        $content = $row.Content.Trim()
        if ($contents.Contains($content)) { continue }
        # The first id replaces "none" on the Documents line.
        $separator = if ($ids.Count) { ', ' } else { '' }
        $candidateLength = $length + (Get-PackBlock $row).Length + $separator.Length + $row.Id.Length - $(if ($ids.Count) { 0 } else { 'none'.Length })
        if ((Measure-PackTokens $candidateLength $Limit $TokenLabel) -le $Limit) {
            $optional += $row
            $ids.Add($row.Id)
            [void]$contents.Add($content)
            $length = $candidateLength
        } else { $omitted += $row }
    }

    $covered = @($selected + $optional | ForEach-Object { $_.Id })
    $final = @($selected + (Merge-CompleteDocuments $optional))
    # A merged document repeats its title line; keep the sections if that would not fit.
    if ((Measure-PackTokens (Get-PackLength $final $parts @() $ReservedLength) $Limit $TokenLabel) -gt $Limit) {
        $final = @($selected + $optional)
    }

    # Omitted matches are listed for explicit retrieval while the index fits.
    $indexLines = @()
    foreach ($row in $omitted) {
        $candidate = @($indexLines + (Get-PackIndexLine $row))
        if ((Measure-PackTokens (Get-PackLength $final $parts $candidate $ReservedLength) $Limit $TokenLabel) -le $Limit) { $indexLines = $candidate }
    }
    $pack = Format-ContextPack $final $Header $Limit $TokenLabel $indexLines '' $ReservedLength
    $pack.Covered = $covered
    return $pack
}

# Delivered-pack manifests: one SHA-256 per delivered unit, keyed by a content-derived pack id.
$packManifestLimit = 20

function Get-TextHash([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([System.Text.UTF8Encoding]::new($false).GetBytes($Text)) } finally { $sha.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-UnitHash([string]$Content) { return Get-TextHash ($Content.Trim() -replace "`r`n", "`n") }

function Get-PackManifestDirectory { return Resolve-ProjectPath "$storeName/.runtime/packs" }

function Read-PackManifest([string]$PackId) {
    # Strict id format: the value becomes a file name.
    $path = Join-Path (Get-PackManifestDirectory) "$PackId.json"
    if ($PackId -notmatch '^[0-9a-f]{12}$' -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Unknown pack id: $PackId. Run context without -Since to start a new pack. No output was written."
    }
    $units = @{}
    foreach ($unit in @((Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).units)) { $units[[string]$unit.id] = [string]$unit.hash }
    return $units
}

function Test-UnitDelivered($Row, $Delivered) {
    if ($Delivered.ContainsKey($Row.Id) -and $Delivered[$Row.Id] -eq (Get-UnitHash $Row.Content)) { return $true }
    # A section is also delivered when its whole, unchanged document was.
    return ($Row.Id -ne $Row.DocumentId -and $Delivered.ContainsKey($Row.DocumentId) -and $Delivered[$Row.DocumentId] -eq (Get-UnitHash $Row.DocumentContent))
}

function Get-PackManifest($Units) {
    # The id depends only on unit ids and hashes, so the same content always gets the same id.
    $ids = [string[]]@($Units.Keys)
    [Array]::Sort($ids, [StringComparer]::Ordinal)
    $entries = @($ids | ForEach-Object { [pscustomobject]@{ id = $_; hash = $Units[$_] } })
    $packId = (Get-TextHash (($entries | ForEach-Object { "$($_.id)`t$($_.hash)`n" }) -join '')).Substring(0, 12)
    return [pscustomobject]@{ id = $packId; units = $entries }
}

function Get-PackIdLine([string]$PackId) { return "- Pack id: $PackId`r`n" }
$packIdLineLength = (Get-PackIdLine ('0' * 12)).Length

function Add-PackUnits($Units, $Rows) {
    foreach ($row in $Rows) { $Units[$row.Id] = Get-UnitHash $row.Content }
    return $Units
}

function Save-PackManifest($Manifest) {
    $packId = $Manifest.id
    $directory = Get-PackManifestDirectory
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $manifest = $Manifest
    [System.IO.File]::WriteAllText((Join-Path $directory "$packId.json"), (Get-JsonFileText $manifest), [System.Text.UTF8Encoding]::new($false))
    # Keep the most recently written manifests; the timestamp is used only for pruning.
    # Pruning is best effort: a concurrent run may already have removed or still hold a file.
    Get-ChildItem -LiteralPath $directory -Filter '*.json' -File |
        Sort-Object @{ Expression = 'LastWriteTimeUtc'; Descending = $true }, @{ Expression = 'Name'; Ascending = $true } |
        Select-Object -Skip $packManifestLimit |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    return $packId
}

function Get-QueryPackHeader([string]$SearchQuery) {
    return "# N4ti Pack`r`n`r`n- Query: $SearchQuery"
}

function Resolve-ProjectPath([string]$RelativePath) {
    return Join-Path $projectRoot ($RelativePath -replace "/", "\")
}

function Normalize-SearchText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $decomposed = $Text.Normalize([Text.NormalizationForm]::FormD)
    return ([regex]::Replace($decomposed, '\p{Mn}', '')).Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
}

function Get-QueryTerms([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $stop = @("para", "como", "desde", "esta", "este", "esto", "with", "from", "that", "this", "the", "una", "uno", "del", "los", "las", "por", "con", "and")
    return @([regex]::Matches((Normalize-SearchText $Text), '[\p{L}\p{Nd}_./-]{3,}') |
        ForEach-Object { $_.Value } |
        Where-Object { $_ -notin $stop } |
        Select-Object -Unique)
}

function Get-AliasGroups($Catalog) {
    $property = $Catalog.PSObject.Properties['aliases']
    if (-not $property) { return @() }
    $message = 'Invalid catalog aliases: expected a list of term groups with at least two non-empty terms each.'
    if ($property.Value -isnot [array]) { throw $message }
    $groups = @()
    foreach ($group in $property.Value) {
        if ($group -isnot [array] -or $group.Count -lt 2) { throw $message }
        foreach ($alias in $group) { if ($alias -isnot [string] -or [string]::IsNullOrWhiteSpace($alias)) { throw $message } }
        $groups += , @($group | ForEach-Object { Normalize-SearchText $_.Trim() } | Select-Object -Unique)
    }
    # The comma keeps a single group from being unrolled into loose terms.
    return , $groups
}

function Get-QueryTermGroups([string]$Text, $Catalog) {
    # Each query term expands to its catalog aliases; equivalent terms count once.
    $aliasGroups = Get-AliasGroups $Catalog
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($term in Get-QueryTerms $Text) {
        $variants = @($term)
        foreach ($group in $aliasGroups) { if ($group -contains $term) { $variants += $group } }
        $variants = @($variants | Select-Object -Unique)
        if ($seen.Add((($variants | Sort-Object) -join '|'))) { [pscustomobject]@{ Variants = $variants } }
    }
}

function Test-AnyVariant([string]$Field, [string[]]$Variants) {
    foreach ($variant in $Variants) { if ($Field.Contains($variant)) { return $true } }
    return $false
}

# Optional documents above this estimate are retrieved by level-2 section.
$sectionMinTokens = 200
# Optional units need this share of the best optional relevance to enter a pack.
$relevanceCutoff = 0.25

function Get-SectionSlug([string]$Heading, $Used) {
    $base = ([regex]::Replace((Normalize-SearchText $Heading), '[^a-z0-9]+', '-')).Trim('-')
    if (-not $base) { $base = 'section' }
    $slug = $base
    $suffix = 2
    while (-not $Used.Add($slug)) { $slug = "$base-$suffix"; $suffix++ }
    return $slug
}

function Split-DocumentSections([string]$Content) {
    # Splits on "## " headings outside fenced code; the text before the first one is "intro".
    $used = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [void]$used.Add('intro')
    $parts = @()
    $heading = ''
    $slug = 'intro'
    $lines = [Collections.Generic.List[string]]::new()
    $inFence = $false
    foreach ($line in ($Content -split "`r?`n")) {
        if ($line -match '^\s*(```|~~~)') { $inFence = -not $inFence }
        if (-not $inFence -and $line -match '^##\s+(.+?)\s*#*\s*$') {
            $parts += [pscustomobject]@{ Slug = $slug; Heading = $heading; Text = ($lines -join "`n").Trim() }
            $heading = $Matches[1]
            $slug = Get-SectionSlug $heading $used
            $lines = [Collections.Generic.List[string]]::new()
        }
        $lines.Add($line)
    }
    $parts += [pscustomobject]@{ Slug = $slug; Heading = $heading; Text = ($lines -join "`n").Trim() }
    # An intro holding only the document title is not a retrievable unit.
    return @($parts | Where-Object { $_.Heading -or ($_.Text -replace '(?m)^#\s+[^\r\n]*', '').Trim() })
}

function Get-TermHits($Terms, [string]$Metadata, [string]$Title, [string]$Body) {
    # Field weights per term: metadata 50, title 35, body 10. IDF is applied later.
    # The comma keeps one-term results as an indexable array.
    return , @(foreach ($term in $Terms) {
        $weight = 0
        if (Test-AnyVariant $Metadata $term.Variants) { $weight += 50 }
        if (Test-AnyVariant $Title $term.Variants) { $weight += 35 }
        if (Test-AnyVariant $Body $term.Variants) { $weight += 10 }
        $weight
    })
}

function Get-TermIdf([int]$Units, [int]$UnitsWithTerm) {
    # Smoothed BM25 IDF: always positive, lower for terms found in many units.
    return [math]::Log(1 + ($Units - $UnitsWithTerm + 0.5) / ($UnitsWithTerm + 0.5))
}

function Get-DocumentSupersedes($Document) {
    # Optional list of document ids this document replaces.
    $property = $Document.PSObject.Properties['supersedes']
    if (-not $property -or $null -eq $property.Value) { return @() }
    $ids = @($property.Value)
    foreach ($supersededId in $ids) {
        if ($supersededId -isnot [string] -or [string]::IsNullOrWhiteSpace($supersededId)) {
            throw "Invalid supersedes for $($Document.id): expected a list of document ids."
        }
    }
    return @($ids | ForEach-Object { $_.Trim() })
}

function Get-DocumentExpiry($Document) {
    # Optional local date "yyyy-MM-dd"; the document stays valid through that day.
    $property = $Document.PSObject.Properties['expires']
    if (-not $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { return $null }
    $parsed = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::None
    if (-not [datetime]::TryParseExact([string]$property.Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        throw "Invalid expires date for $($Document.id): $($property.Value) (expected yyyy-MM-dd)"
    }
    return $parsed
}

function Test-DocumentMandatory($Document) { return [bool]($Document.alwaysLoad -or $Document.priority -eq 'critical') }

function Get-SupersedesErrors($Catalog) {
    # Reports invalid supersedes/expires fields, unknown targets, self-references and cycles.
    $errors = @()
    $knownIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($document in $Catalog.documents) { [void]$knownIds.Add($document.id) }
    $graph = @{}
    $today = [datetime]::Today
    foreach ($document in $Catalog.documents) {
        try {
            $expiry = Get-DocumentExpiry $document
            if ($expiry -and $expiry -lt $today -and (Test-DocumentMandatory $document)) { $errors += "Expired document cannot be mandatory: $($document.id)" }
        } catch { $errors += $_.Exception.Message }
        try { $targets = @(Get-DocumentSupersedes $document) } catch { $errors += $_.Exception.Message; continue }
        $graph[$document.id] = @()
        foreach ($target in $targets) {
            if ($target -eq $document.id) { $errors += "Document cannot supersede itself: $($document.id)"; continue }
            if (-not $knownIds.Contains($target)) { $errors += "Unknown supersedes target in $($document.id): $target"; continue }
            $graph[$document.id] += $target
            $targetDocument = $Catalog.documents | Where-Object { $_.id -eq $target } | Select-Object -First 1
            if ([int]$document.level -lt 4 -and (Test-DocumentMandatory $targetDocument)) { $errors += "Superseded document cannot be mandatory: $target" }
        }
    }

    foreach ($cycle in @(Get-SupersedesCycles $graph)) { $errors += "Supersedes cycle: $cycle" }
    return $errors
}

function Get-SupersedesCycles($graph) {
    # Breadth-first walk from each document back to itself; each cycle is reported once.
    $cycles = @()
    $reported = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($start in @($graph.Keys | Sort-Object)) {
        $queue = [Collections.Generic.Queue[object]]::new()
        $queue.Enqueue(@($start))
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $cycle = $null
        while ($queue.Count -and -not $cycle) {
            $path = @($queue.Dequeue())
            foreach ($next in @($graph[$path[-1]])) {
                if ($next -eq $start) { $cycle = @($path) + $start; break }
                if ($graph.ContainsKey($next) -and $seen.Add($next)) { $queue.Enqueue(@($path) + $next) }
            }
        }
        if ($cycle -and $reported.Add((@($cycle | Select-Object -Unique | Sort-Object) -join '|'))) {
            $cycles += $cycle -join ' -> '
        }
    }
    return $cycles
}

function Get-RetiredDocuments($Catalog, [string[]]$RequiredIds = @()) {
    # Expired documents (id -> date) and superseded ones (id -> current replacements).
    # Throws on invalid supersedes/expires values and on supersedes cycles.
    $expired = [Collections.Generic.Dictionary[string, datetime]]::new([StringComparer]::OrdinalIgnoreCase)
    $supersededBy = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $knownIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($document in $Catalog.documents) { [void]$knownIds.Add($document.id) }
    $today = [datetime]::Today
    foreach ($document in $Catalog.documents) {
        $expiry = Get-DocumentExpiry $document
        if ($expiry -and $expiry -lt $today) { $expired[$document.id] = $expiry }
    }
    $graph = @{}
    foreach ($document in $Catalog.documents) {
        $replacements = @(Get-DocumentSupersedes $document)
        $graph[$document.id] = @($replacements | Where-Object { $_ -ne $document.id -and $knownIds.Contains($_) })
        # Only current documents (not archived, not expired) can supersede others.
        if ($expired.ContainsKey($document.id) -or ([int]$document.level -ge 4 -and $document.id -notin $RequiredIds)) { continue }
        foreach ($supersededId in $replacements) {
            if (-not $supersededBy.ContainsKey($supersededId)) { $supersededBy[$supersededId] = [Collections.Generic.List[string]]::new() }
            $supersededBy[$supersededId].Add($document.id)
        }
    }
    # A cycle would silently hide every document in it, so retrieval refuses it.
    $cycles = @(Get-SupersedesCycles $graph)
    if ($cycles.Count) { throw "Supersedes cycle: $($cycles -join '; '). Fix supersedes in the catalog (see validate). No output was written." }
    return [pscustomobject]@{ Expired = $expired; SupersededBy = $supersededBy }
}

function Get-DocumentRows([string]$SearchQuery, [string[]]$RequiredIds = @(), [switch]$Sections) {
    $catalog = Get-Catalog
    $terms = @(Get-QueryTermGroups $SearchQuery $catalog)
    $rows = @()
    $retired = Get-RetiredDocuments $catalog $RequiredIds

    foreach ($document in $catalog.documents) {
        if ([int]$document.level -ge 4) {
            if (Test-DocumentMandatory $document) {
                throw "Archive document cannot be mandatory: $($document.id)"
            }
            # Skip historical file reads unless explicitly requested or assigned.
            if (-not $IncludeArchive -and $document.id -notin $RequiredIds) { continue }
        }
        $superseded = $retired.SupersededBy.ContainsKey($document.id)
        $expired = $retired.Expired.ContainsKey($document.id)
        if ($superseded -or $expired) {
            if (Test-DocumentMandatory $document) {
                $reason = if ($superseded) { 'Superseded' } else { 'Expired' }
                throw "$reason document cannot be mandatory: $($document.id)"
            }
            # Replaced or outdated documents behave like history.
            if (-not $IncludeArchive -and $document.id -notin $RequiredIds) { continue }
        }
        $fullPath = Resolve-ProjectPath $document.path
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }

        $content = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8
        $metadata = Normalize-SearchText ($document.id + ' ' + $document.type + ' ' + $document.path + ' ' + ($document.tags -join ' ') + ' ' + ($document.affects -join ' '))
        $heading = [regex]::Match($content, '(?m)^#\s+([^\r\n]+)').Groups[1].Value
        $priorityScore = switch ($document.priority) {
            "critical" { 40 }
            "high" { 20 }
            "normal" { 8 }
            default { 0 }
        }
        $statusScore = if ($document.status -eq "active") { 12 } else { 0 }
        $baseScore = $priorityScore + $statusScore - [int]$document.level * 3
        if ($document.alwaysLoad) { $baseScore += 1000 }
        $tokens = Get-TokenEstimate $content

        # Each unit is the whole document or one of its sections, scored on its own text.
        $units = @([pscustomobject]@{ Id = $document.id; Index = -1; Heading = ''; Text = $content })
        $required = $document.alwaysLoad -or $document.priority -eq 'critical' -or $document.id -in $RequiredIds
        if ($Sections -and -not $required -and $tokens -gt $sectionMinTokens) {
            $parts = @(Split-DocumentSections $content)
            if (@($parts | Where-Object Heading).Count -gt 0) {
                $units = @(for ($index = 0; $index -lt $parts.Count; $index++) {
                    [pscustomobject]@{ Id = "$($document.id)#$($parts[$index].Slug)"; Index = $index; Heading = $parts[$index].Heading; Text = $parts[$index].Text }
                })
            }
        }

        foreach ($unit in $units) {
            $title = Normalize-SearchText ($heading + ' ' + $document.title + ' ' + $unit.Heading)
            $hits = Get-TermHits $terms $metadata $title (Normalize-SearchText $unit.Text)
            $unitTokens = Get-TokenEstimate $unit.Text
            $label = if ($unit.Heading) { $unit.Heading } elseif ($heading) { $heading } else { $document.id }
            $rows += [pscustomobject]@{
                Id = $unit.Id
                DocumentId = $document.id
                SectionIndex = $unit.Index
                SectionCount = $units.Count
                Label = $label
                Level = [int]$document.level
                Type = $document.type
                Priority = $document.priority
                Path = $document.path
                AlwaysLoad = [bool]$document.alwaysLoad
                Matches = @($hits | Where-Object { $_ -gt 0 }).Count
                Tokens = $unitTokens
                Hits = $hits
                BaseScore = $baseScore - [math]::Floor($unitTokens / 500)
                Relevance = 0.0
                Score = 0
                Content = $unit.Text
                DocumentContent = $content
            }
        }
    }

    # Second pass: weight each term by how specific it is across all retrievable units.
    for ($termIndex = 0; $termIndex -lt $terms.Count; $termIndex++) {
        $unitsWithTerm = @($rows | Where-Object { $_.Hits[$termIndex] -gt 0 }).Count
        $idf = Get-TermIdf $rows.Count $unitsWithTerm
        foreach ($row in $rows) { $row.Relevance += $row.Hits[$termIndex] * $idf }
    }
    foreach ($row in $rows) { $row.Score = [int][math]::Round($row.Relevance + $row.BaseScore) }

    return @($rows | Sort-Object -Property `
        @{ Expression = "Score"; Descending = $true }, `
        @{ Expression = "Level"; Ascending = $true }, `
        @{ Expression = "Id"; Ascending = $true })
}

function Set-CurrentState {
    param([string]$ActiveTask, [string]$Result, [string]$NextAction)
    $path = Resolve-ProjectPath "$storeName/current-state.md"
    $content = Get-Content -LiteralPath $path -Raw
    $date = Get-Date -Format "yyyy-MM-dd HH:mm"
    $replacements = @{
        "(?m)^- Active task:.*$" = "- Active task: $ActiveTask"
        "(?m)^- Last verified result:.*$" = "- Last verified result: $Result"
        "(?m)^- Next action:.*$" = "- Next action: $NextAction"
        "(?m)^- Updated:.*$" = "- Updated: $date"
    }
    foreach ($pattern in $replacements.Keys) {
        $content = [regex]::Replace($content, $pattern, $replacements[$pattern])
    }
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
}

function Assert-CheckpointTask([string]$TaskId) {
    if ([string]::IsNullOrWhiteSpace($TaskId)) { return }
    $tasks = @((Get-Catalog).documents | Where-Object { $_.id -eq $TaskId -and $_.type -eq 'task' })
    if ($tasks.Count -ne 1) { throw "Expected exactly one task in the catalog: $TaskId" }
}

function Save-Checkpoint($Checkpoint) {
    $directory = Resolve-ProjectPath "$storeName/checkpoints"
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $destination = Join-Path $directory "$($Checkpoint.id).json"
    $temporary = Join-Path $directory "$($Checkpoint.id).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Checkpoint | ConvertTo-Json -Depth 8) + "`r`n", [Text.UTF8Encoding]::new($false))
        # Same-directory publication is atomic; an existing checkpoint is never overwritten.
        [IO.File]::Move($temporary, $destination)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
    return $destination
}

function Get-Checkpoints {
    $directory = Resolve-ProjectPath "$storeName/checkpoints"
    if (-not (Test-Path -LiteralPath $directory)) { return @() }
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'Checkpoint storage is not a directory.' }
    foreach ($file in Get-ChildItem -LiteralPath $directory -Filter '*.json' -File) {
        try {
            $record = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($record.schemaVersion -ne 1 -or $record.status -ne 'reported' -or $record.verified -ne $false -or
                $record.id -notmatch '^[a-f0-9]{32}$' -or [string]::IsNullOrWhiteSpace($record.summary) -or
                [string]::IsNullOrWhiteSpace($record.next)) { throw 'Invalid checkpoint fields' }
            [void][DateTimeOffset]::Parse($record.savedAt, [Globalization.CultureInfo]::InvariantCulture)
        } catch { throw "Invalid checkpoint: $($file.Name). Repair or restore it before resuming." }
        $record
    }
}

switch ($Command) {
    'save' {
        if ([string]::IsNullOrWhiteSpace($Summary) -or [string]::IsNullOrWhiteSpace($Next)) {
            throw 'save requires -Summary and -Next. Do not include credentials or personal data.'
        }
        Assert-CheckpointTask $Id
        $checkpoint = [ordered]@{
            schemaVersion = 1
            id = [guid]::NewGuid().ToString('N')
            savedAt = [DateTimeOffset]::UtcNow.ToString('o')
            task = if ([string]::IsNullOrWhiteSpace($Id)) { $null } else { $Id }
            status = 'reported'
            verified = $false
            summary = $Summary
            next = $Next
            files = @($Files -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            tests = @($Tests -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            risks = @($Risks -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $checkpointPath = Save-Checkpoint $checkpoint
        Write-Host "Checkpoint saved: $checkpointPath"
        Write-Host 'Evidence is reported, not verified. No task or current-state file was changed.'
    }
    'resume' {
        if ($Budget -lt 0) { throw 'Budget cannot be negative.' }
        Assert-CheckpointTask $Id
        $checkpoint = @(Get-Checkpoints | Where-Object { [string]::IsNullOrWhiteSpace($Id) -or $_.task -eq $Id } |
            Sort-Object -Property @{ Expression = { [DateTimeOffset]::Parse($_.savedAt, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime.Ticks }; Descending = $true },
                @{ Expression = 'id'; Descending = $true } | Select-Object -First 1)
        if ($checkpoint.Count -eq 0) {
            Write-Host 'No checkpoints found for this project/task. Use n4ti save to record progress.'
            break
        }
        $record = $checkpoint[0]
        $taskLabel = if ($record.task) { $record.task } else { 'project' }
        $body = @"
- Saved: $($record.savedAt)
- Task: $taskLabel
- Evidence: reported / unverified

## Progress

$($record.summary)

## Next step

$($record.next)

## Reported files

$($record.files -join "`n")

## Reported tests

$($record.tests -join "`n")

## Reported risks

$($record.risks -join "`n")
"@
        $row = [pscustomobject]@{
            Id = $record.id; Level = 1; Path = "$storeName/checkpoints/$($record.id).json"
            AlwaysLoad = $true; Priority = 'critical'; Matches = 1; Content = $body
        }
        $limit = if ($Budget -gt 0) { $Budget } else { [int](Get-Catalog).tokenBudget }
        $pack = New-BoundedContextPack @($row) '# N4ti Resume' $limit 'Estimated tokens'
        Write-Host -NoNewline $pack.Text
    }
    "init" {
        if ([string]::IsNullOrWhiteSpace($Idea)) {
            $Idea = Read-Host "What do you want to build, for whom, and what is the main outcome"
        }
        if ([string]::IsNullOrWhiteSpace($Idea)) { throw "init requires a project idea" }

        $signals = @(Get-ProjectSignals)
        $checkpoints = @(Find-CheckpointFiles)
        $openspecPath = Find-OpenSpecPath
        $hasProjectFiles = $signals.Count -gt 0 -or (Test-Path -LiteralPath (Join-Path $projectRoot "src")) -or (Test-Path -LiteralPath (Join-Path $projectRoot "app"))
        $stage = if ($hasProjectFiles) { "existing" } else { "new" }
        $now = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"

        $profile = [ordered]@{
            schemaVersion = 2
            initialized = $true
            semanticAnalysis = "pending-orchestrator"
            idea = $Idea
            audience = "pending-orchestrator"
            primaryOutcome = "pending-orchestrator"
            projectStage = $stage
            detectedStack = $signals
            constraints = @()
            assumptions = @("Initial project classification is based on repository markers.")
            checkpointFiles = $checkpoints
            openspecPath = $openspecPath
            initMode = $InitMode
            updatedAt = $now
        }
        Save-JsonFile "$storeName/project-profile.json" $profile

        $openSpec = [ordered]@{
            schemaVersion = 2
            detected = [bool]($null -ne $openspecPath)
            path = $openspecPath
            mode = "reference-only"
            rule = "OpenSpec owns requirements; N4ti owns orchestration state, retrieval, assignments, and evidence."
        }
        Save-JsonFile "$storeName/integrations/openspec.json" $openSpec

        $modelsPath = Resolve-ProjectPath "$storeName/policies/model-routing.json"
        $models = Get-Content -LiteralPath $modelsPath -Raw | ConvertFrom-Json
        $models.mode = $ModelMode
        $models.defaultModel = $DefaultModel
        Save-JsonFile "$storeName/policies/model-routing.json" $models

        $staffPath = Resolve-ProjectPath "$storeName/agents/staff.json"
        $staff = Get-Content -LiteralPath $staffPath -Raw | ConvertFrom-Json
        $staff.maxParallel = $MaxParallel
        Save-JsonFile "$storeName/agents/staff.json" $staff

        $stackText = if ($signals.Count -gt 0) { $signals -join ", " } else { "none detected" }
        $checkpointText = if ($checkpoints.Count -gt 0) { $checkpoints -join ", " } else { "none" }
        $openSpecText = if ($openspecPath) { $openspecPath } else { "not detected" }
        $strategy = @"
# Technology Strategy

## Product Drivers

- Initial idea: $Idea
- Project stage: $stage
- Initialization mode: $InitMode

## Current Stack

- Detected signals: $stackText
- Checkpoints: $checkpointText
- OpenSpec: $openSpecText

## Recommendation

Pending semantic analysis by the orchestrator. Preserve working technology by
default. Score alternatives by product fit, simplicity, maintainability,
deployment, ecosystem, team familiarity, portability, migration risk, and lock-in.

## Review Triggers

- New platform or incompatible requirement.
- Material security, scale, support, or operating-cost change.
- Critical dependency becomes unsupported.

No technology migration is approved by this file alone. Create a decision and ask
for approval when the autonomy policy requires it.
"@
        [System.IO.File]::WriteAllText((Resolve-ProjectPath "$storeName/technology-strategy.md"), $strategy.TrimStart() + "`r`n", [System.Text.UTF8Encoding]::new($false))

        $request = @"
# N4ti Initialization Request

You are the main orchestrator and the only canonical writer to $storeName/.

## Initial Idea

$Idea

## Deterministic Scan

- Project stage: $stage
- Stack signals: $stackText
- Checkpoints: $checkpointText
- OpenSpec: $openSpecText
- Model mode: $ModelMode
- Default model: $DefaultModel
- Maximum parallel subagents: $MaxParallel

## Required Analysis

1. Inspect the repository without changing product code.
2. Read detected checkpoints and classify useful content into core, state, tasks,
   decisions, commands, knowledge, or archive. Do not keep two active states.
3. If OpenSpec exists, reference its active requirements without copying them.
4. Complete project profile, core, current state, commands, architecture, and
   technology strategy.
5. Propose the smallest dynamic staff needed for the idea and detected stack.
6. Keep model routing provider-neutral and respect the selected mode.
7. In guided mode, ask only unanswered high-impact product or architecture
   questions. In quick mode, state reversible assumptions and continue.
8. Do not implement product code. Run ``n4ti.cmd complete-init`` when the semantic
   initialization is ready for validation.
"@
        $requestPath = Resolve-ProjectPath "$storeName/.runtime/initialization-request.md"
        [System.IO.File]::WriteAllText($requestPath, $request.TrimStart() + "`r`n", [System.Text.UTF8Encoding]::new($false))
        Set-CurrentState -ActiveTask "initialization" -Result "Deterministic repository scan completed" -NextAction "Orchestrator must complete $storeName/.runtime/initialization-request.md"

        Write-Host "N4ti deterministic initialization completed" -ForegroundColor Green
        Write-Host "Project stage: $stage"
        Write-Host "Stack: $stackText"
        Write-Host "Checkpoint files: $checkpointText"
        Write-Host "OpenSpec: $openSpecText"
        Write-Host "Next: ask the main agent to execute $storeName/.runtime/initialization-request.md"
    }

    "complete-init" {
        $profilePath = Resolve-ProjectPath "$storeName/project-profile.json"
        $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
        $problems = @()
        if (-not $profile.initialized) { $problems += "Run n4ti.cmd init first" }
        if ([string]::IsNullOrWhiteSpace($profile.audience) -or $profile.audience -match "^pending") { $problems += "project-profile audience is pending" }
        if ([string]::IsNullOrWhiteSpace($profile.primaryOutcome) -or $profile.primaryOutcome -match "^pending") { $problems += "project-profile primaryOutcome is pending" }
        foreach ($relativePath in @("$storeName/core.md", "$storeName/commands.md")) {
            $content = Get-Content -LiteralPath (Resolve-ProjectPath $relativePath) -Raw
            if ($content -match "(?m)\bTODO\b|pending initialization") { $problems += "$relativePath still has initialization placeholders" }
        }
        $strategy = Get-Content -LiteralPath (Resolve-ProjectPath "$storeName/technology-strategy.md") -Raw
        if ($strategy -match "Pending semantic analysis") { $problems += "technology strategy is still pending semantic analysis" }
        if ($problems.Count -gt 0) {
            $problems | ForEach-Object { Write-Host "INCOMPLETE: $_" -ForegroundColor Yellow }
            throw "N4ti semantic initialization is not complete"
        }

        $profile.semanticAnalysis = "complete"
        $profile | Add-Member -NotePropertyName semanticCompletedAt -NotePropertyValue (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK") -Force
        Save-JsonFile "$storeName/project-profile.json" $profile

        $statePath = Resolve-ProjectPath "$storeName/current-state.md"
        $state = Get-Content -LiteralPath $statePath -Raw
        $state = [regex]::Replace($state, "(?m)^- Active task: initialization$", "- Active task: none")
        $state = [regex]::Replace($state, "(?m)^- Last verified result:.*$", "- Last verified result: N4ti semantic initialization completed")
        $state = [regex]::Replace($state, "(?m)^- Updated:.*$", "- Updated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
        [System.IO.File]::WriteAllText($statePath, $state, [System.Text.UTF8Encoding]::new($false))
        Write-Host "N4ti semantic initialization completed" -ForegroundColor Green
        Write-Host "Run: .\n4ti.cmd validate"
    }

    "status" {
        $statePath = Resolve-ProjectPath "$storeName/current-state.md"
        Get-Content -LiteralPath $statePath
    }

    "route" {
        if ([string]::IsNullOrWhiteSpace($Agent)) { throw "route requires -Agent" }
        $staff = Get-Content -LiteralPath (Resolve-ProjectPath "$storeName/agents/staff.json") -Raw | ConvertFrom-Json
        $role = $staff.roles | Where-Object { $_.id -eq $Agent -and $_.enabled } | Select-Object -First 1
        if (-not $role) { throw "Enabled agent role not found: $Agent" }
        $policy = Get-Content -LiteralPath (Resolve-ProjectPath "$storeName/policies/model-routing.json") -Raw | ConvertFrom-Json
        $resolved = $policy.defaultModel
        if ($policy.mode -eq "adaptive") {
            $candidate = $policy.capabilityRouting.($role.capability)
            if ($candidate -and $candidate -ne "default") { $resolved = $candidate }
        }
        [pscustomobject]@{
            Agent = $role.id
            Capability = $role.capability
            Mode = $policy.mode
            Model = $resolved
            AdvisorOnly = $policy.advisorOnly
        } | Format-List
    }

    "task-packet" {
        if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Agent)) {
            throw "task-packet requires -Id and -Agent"
        }
        $catalog = Get-Catalog
        $task = $catalog.documents | Where-Object { $_.id -eq $Id -and $_.type -eq "task" } | Select-Object -First 1
        if (-not $task) { throw "Task not found: $Id" }
        $taskPath = Resolve-ProjectPath $task.path
        $taskContent = Get-Content -LiteralPath $taskPath -Raw -Encoding UTF8

        $staff = Get-Content -LiteralPath (Resolve-ProjectPath "$storeName/agents/staff.json") -Raw | ConvertFrom-Json
        $role = $staff.roles | Where-Object { $_.id -eq $Agent -and $_.enabled } | Select-Object -First 1
        if (-not $role) { throw "Enabled agent role not found: $Agent" }

        $policy = Get-Content -LiteralPath (Resolve-ProjectPath "$storeName/policies/model-routing.json") -Raw | ConvertFrom-Json
        $resolvedModel = $policy.defaultModel
        if ($policy.mode -eq "adaptive") {
            $candidate = $policy.capabilityRouting.($role.capability)
            if ($candidate -and $candidate -ne "default") { $resolvedModel = $candidate }
        }

        $resultCap = Get-ResultTokenCap
        $effectiveBudget = if ($Budget -gt 0) { $Budget } else { 3000 }
        $queryText = "$Id $Agent $($task.tags -join ' ') $taskContent"
        $header = @"
# N4ti Subagent Task Packet

- Task: $Id
- Role: $($role.id)
- Purpose: $($role.purpose)
- Capability: $($role.capability)
- Suggested model: $resolvedModel

## Contract

Work only on the scoped task. Do not edit $storeName/ canonical memory. Return status, changed files, tests, risks, proposed decisions, and a concise summary to the orchestrator. The whole result must stay within $resultCap estimated tokens; record-result rejects larger results.

"@
        $pack = New-BoundedContextPack @(Get-DocumentRows $queryText @($Id) -Sections) $header $effectiveBudget "Estimated context tokens" @($Id)
        $packetPath = Resolve-ProjectPath "$storeName/.runtime/packets/$Id-$Agent.md"
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $packetPath)) | Out-Null
        [System.IO.File]::WriteAllText($packetPath, $pack.Text, [System.Text.UTF8Encoding]::new($false))
        Write-Host "Task packet: $packetPath" -ForegroundColor Green
        Write-Host "Suggested model: $resolvedModel ($($policy.mode))"
        Write-Host "Estimated context tokens: $($pack.Tokens) / $effectiveBudget"
    }

    "record-result" {
        if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Agent) -or [string]::IsNullOrWhiteSpace($Summary)) {
            throw "record-result requires -Id, -Agent, and -Summary"
        }
        $task = (Get-Catalog).documents | Where-Object { $_.id -eq $Id -and $_.type -eq "task" } | Select-Object -First 1
        if (-not $task) { throw "Task not found: $Id" }
        $staff = Get-Content -LiteralPath (Resolve-ProjectPath "$storeName/agents/staff.json") -Raw | ConvertFrom-Json
        $role = $staff.roles | Where-Object { $_.id -eq $Agent -and $_.enabled } | Select-Object -First 1
        if (-not $role) { throw "Enabled agent role not found: $Agent" }
        $splitValues = {
            param($Value)
            return @($Value -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $result = [ordered]@{
            schemaVersion = 2
            task = $Id
            agent = $Agent
            status = "reported"
            filesChanged = @(& $splitValues $Files)
            tests = @(& $splitValues $Tests)
            risks = @(& $splitValues $Risks)
            decisionsProposed = @(& $splitValues $Decisions)
            summary = $Summary
            recordedAt = Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"
            integratedByOrchestrator = $false
        }
        $safeAgent = $Agent -replace "[^a-zA-Z0-9_-]", "-"
        $relativePath = "$storeName/results/$Id-$safeAgent-$(Get-Date -Format 'yyyyMMddHHmmss')-$([guid]::NewGuid().ToString('N')).json"
        # Measure the exact file text before writing so a rejected result leaves nothing behind.
        $resultCap = Get-ResultTokenCap
        $resultText = Get-JsonFileText $result
        $estimated = Get-TokenEstimate $resultText
        if ($estimated -gt $resultCap) {
            throw "Result of about $estimated est. tokens exceeds resultTokenCap $resultCap. No result was written. Shorten -Summary or the lists."
        }
        [System.IO.File]::WriteAllText((Resolve-ProjectPath $relativePath), $resultText, [System.Text.UTF8Encoding]::new($false))
        Write-Host "Result recorded: $relativePath" -ForegroundColor Green
        Write-Host "The orchestrator must review and integrate it into canonical N4ti state."
    }

    "search" {
        if ([string]::IsNullOrWhiteSpace($Query)) { throw "search requires -Query" }
        Get-DocumentRows $Query |
            Where-Object { $_.AlwaysLoad -or $_.Priority -eq "critical" -or $_.Matches -gt 0 } |
            Select-Object Id, Level, Type, Priority, Score, Tokens, Path |
            Format-Table -AutoSize
    }

    "context" {
        if ([string]::IsNullOrWhiteSpace($Query)) { throw "context requires -Query" }
        $catalog = Get-Catalog
        $effectiveBudget = if ($Budget -gt 0) { $Budget } else { [int]$catalog.tokenBudget }
        $delivered = if ($PSBoundParameters.ContainsKey('Since')) { Read-PackManifest $Since } else { @{} }
        $header = Get-QueryPackHeader $Query
        $pack = New-BoundedContextPack @(Get-DocumentRows $Query -Sections) $header $effectiveBudget "Estimated tokens" @() $packIdLineLength

        # The manifest covers everything the host holds: earlier deliveries plus this pack.
        $units = @{}
        foreach ($key in $delivered.Keys) { $units[$key] = $delivered[$key] }
        if ($PSBoundParameters.ContainsKey('Since')) {
            # Delta: same selection; unchanged units are listed by id instead of repeated.
            $fresh = @($pack.Rows | Where-Object { -not (Test-UnitDelivered $_ $delivered) })
            $unchanged = @($pack.Rows | Where-Object { $_.Id -notin $fresh.Id } | ForEach-Object { $_.Id })
            $trailer = if ($unchanged.Count) { "- Already delivered: $($unchanged -join ', ')`r`n" } else { '' }
            $deltaPack = Format-ContextPack $fresh $header $effectiveBudget "Estimated tokens" $pack.Indexed $trailer $packIdLineLength
            $deltaPack.Covered = $pack.Covered
            $pack = $deltaPack
        }
        $packId = Save-PackManifest (Get-PackManifest (Add-PackUnits $units $pack.Rows))
        $packText = $pack.Text + (Get-PackIdLine $packId)

        $outputPath = Resolve-ProjectPath $Output
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $outputPath)) | Out-Null
        [System.IO.File]::WriteAllText($outputPath, $packText, [System.Text.UTF8Encoding]::new($false))
        Write-Host "Context pack: $outputPath" -ForegroundColor Green
        Write-Host "Estimated tokens: $($pack.Tokens) / $effectiveBudget"
        Write-Host "Documents: $(if ($pack.Rows.Count) { ($pack.Rows.Id) -join ', ' } else { 'none' })"
        if ($PSBoundParameters.ContainsKey('Since')) { Write-Host "Already delivered: $($unchanged.Count) unit(s) since $Since" }
        Write-Host "Pack id: $packId (next turn: context -Since $packId)"
    }

    "get" {
        # Explicit, read-only retrieval of one document or one of its sections.
        if ([string]::IsNullOrWhiteSpace($Id)) { throw 'get requires -Id DOCUMENT or -Id DOCUMENT#section' }
        $documentId, $slug = $Id.Split('#', 2)
        $catalog = Get-Catalog
        $document = $catalog.documents | Where-Object { $_.id -eq $documentId } | Select-Object -First 1
        if (-not $document) { throw "Document not found: $documentId" }
        # get still prints retired documents, with one warning line per reason.
        $warnings = @()
        try {
            $retired = Get-RetiredDocuments $catalog
            if ($retired.SupersededBy.ContainsKey($document.id)) { $warnings += "superseded by $($retired.SupersededBy[$document.id] -join ', ')" }
            if ($retired.Expired.ContainsKey($document.id)) { $warnings += "expired $($retired.Expired[$document.id].ToString('yyyy-MM-dd'))" }
        } catch { $warnings += 'catalog has invalid supersedes/expires values; run validate' }
        $warningText = ($warnings | ForEach-Object { "> Warning: $_`r`n" }) -join ''
        $fullPath = Resolve-ProjectPath $document.path
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Missing file for $($document.id): $($document.path)" }
        $text = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8
        if ($slug) {
            $parts = @(Split-DocumentSections $text)
            $part = $parts | Where-Object { $_.Slug -eq $slug } | Select-Object -First 1
            if (-not $part) { throw "Section not found: $Id. Available: $(($parts.Slug) -join ', ')" }
            $text = $part.Text
        }
        Write-Output "## $Id | L$($document.level) | $($document.path)`r`n$warningText`r`n$($text.Trim())"
    }

    "bench" {
        # Read-only baseline: builds the same packs as context without writing them.
        $queries = @($Query -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
        if ($queries.Count -eq 0) { throw 'bench requires -Query (separate several queries with ;)' }
        $catalog = Get-Catalog
        $effectiveBudget = if ($Budget -gt 0) { $Budget } else { [int]$catalog.tokenBudget }
        $results = @()
        foreach ($benchQuery in $queries) {
            $rows = @(Get-DocumentRows $benchQuery -Sections)
            $pack = New-BoundedContextPack $rows (Get-QueryPackHeader $benchQuery) $effectiveBudget "Estimated tokens" @() $packIdLineLength
            # Same trailing id line as context; computed only, no manifest is written.
            $pack.Text += Get-PackIdLine (Get-PackManifest (Add-PackUnits @{} $pack.Rows)).id
            $omitted = @($rows | Where-Object { $_.Matches -gt 0 -and $_.Id -notin $pack.Covered })
            $results += [pscustomobject]@{ Query = $benchQuery; Pack = $pack; Rows = $rows; Omitted = $omitted }
        }

        # Corpus figures are per document, whether or not it was split into sections.
        $corpus = @($results[0].Rows | Group-Object DocumentId | ForEach-Object { $_.Group[0] })
        $required = @($corpus | Where-Object { $_.AlwaysLoad -or $_.Priority -eq 'critical' } | Sort-Object Level, Id)
        $requiredTokens = [int](($required | Measure-Object -Property Tokens -Sum).Sum)
        $corpusTokens = 0
        foreach ($document in $corpus) { $corpusTokens += Get-TokenEstimate $document.DocumentContent }
        $archiveLabel = if ($IncludeArchive) { 'archive included' } else { 'archive excluded' }
        $prefixLine = '- Shared pack prefix: n/a (single query)'
        if ($results.Count -gt 1) {
            $texts = @($results | ForEach-Object { $_.Pack.Text })
            $prefix = ($texts | ForEach-Object Length | Measure-Object -Minimum).Minimum
            foreach ($text in $texts[1..($texts.Count - 1)]) {
                $index = 0
                while ($index -lt $prefix -and $text[$index] -ceq $texts[0][$index]) { $index++ }
                $prefix = $index
            }
            $prefixLine = "- Shared pack prefix: $prefix characters across $($texts.Count) packs"
        }

        $lines = @(
            '# N4ti Bench', '',
            '- Estimator: characters / 4 (model-independent estimate)',
            "- Budget: $effectiveBudget",
            "- Corpus: $($corpus.Count) documents, $corpusTokens estimated tokens ($archiveLabel)",
            "- Required in every pack: $(($required.Id) -join ', ') = $requiredTokens estimated tokens",
            $prefixLine, '',
            '| Query | Tokens | Chars | Documents | Omitted |',
            '|---|---|---|---|---|'
        )
        foreach ($result in $results) {
            $omittedText = if ($result.Omitted.Count) { ($result.Omitted | ForEach-Object { "$($_.Id) ($($_.Tokens))" }) -join ', ' } else { '-' }
            $lines += "| $($result.Query.Replace('|', '\|')) | $($result.Pack.Tokens) | $($result.Pack.Text.Length) | $(($result.Pack.Rows.Id) -join ', ') | $omittedText |"
        }
        Write-Output ($lines -join "`n")
    }

    "new-task" {
        if ([string]::IsNullOrWhiteSpace($Title)) { throw "new-task requires -Title" }
        $catalog = Get-Catalog
        $numbers = @($catalog.documents | Where-Object { $_.id -match '^TASK-(\d+)$' } | ForEach-Object { [int]$Matches[1] })
        $nextNumber = if ($numbers.Count -eq 0) { 1 } else { (($numbers | Measure-Object -Maximum).Maximum + 1) }
        $taskId = "TASK-{0:D3}" -f [int]$nextNumber
        $tagList = @($Tags -split "," | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
        $relativePath = "$storeName/tasks/$taskId.md"
        $taskPath = Resolve-ProjectPath $relativePath
        $date = Get-Date -Format "yyyy-MM-dd"
        $body = @"
# ${taskId}: $Title

- Status: active
- Created: $date
- Tags: $($tagList -join ', ')
- Depends on: none
- Affects: to be discovered

## Outcome

Describe the observable result required.

## Acceptance Checks

- [ ] Required behavior implemented.
- [ ] Relevant tests pass.
- [ ] N4ti state updated.

## Working Notes

Keep only current evidence and unresolved questions here.

## Result

Pending.
"@
        [System.IO.File]::WriteAllText($taskPath, $body.TrimStart() + "`r`n", [System.Text.UTF8Encoding]::new($false))
        $entry = [pscustomobject]@{
            id = $taskId; level = 2; type = "task"; status = "active"; priority = "high"
            tags = $tagList; affects = @(); path = $relativePath; alwaysLoad = $false
        }
        $catalog.documents = @($catalog.documents) + $entry
        Save-Catalog $catalog
        Set-CurrentState -ActiveTask $taskId -Result "Task created: $Title" -NextAction "Define outcome and acceptance checks for $taskId"
        Write-Host "Created $taskId at $relativePath" -ForegroundColor Green
    }

    "close-task" {
        if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Summary) -or [string]::IsNullOrWhiteSpace($Next)) {
            throw "close-task requires -Id, -Summary, and -Next"
        }
        $catalog = Get-Catalog
        $entry = $catalog.documents | Where-Object { $_.id -eq $Id -and $_.type -eq "task" } | Select-Object -First 1
        if (-not $entry) { throw "Task not found in catalog: $Id" }
        $taskPath = Resolve-ProjectPath $entry.path
        $content = Get-Content -LiteralPath $taskPath -Raw
        $content = [regex]::Replace($content, "(?m)^- Status:.*$", "- Status: completed")
        $content = [regex]::Replace($content, "(?s)## Result\s+.*$", "## Result`r`n`r`n$Summary`r`n`r`n- Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm')`r`n- Next: $Next`r`n")
        [System.IO.File]::WriteAllText($taskPath, $content, [System.Text.UTF8Encoding]::new($false))
        $entry.status = "completed"
        Save-Catalog $catalog
        $state = Get-Content -LiteralPath (Resolve-ProjectPath "$storeName/current-state.md") -Raw
        $activeTask = [regex]::Match($state, '(?m)^- Active task:\s*([^\r\n]+)').Groups[1].Value.Trim()
        if ($activeTask -eq $Id) {
            Set-CurrentState -ActiveTask "none" -Result $Summary -NextAction $Next
        }
        Write-Host "Closed $Id" -ForegroundColor Green
    }

    "new-decision" {
        if ([string]::IsNullOrWhiteSpace($Title) -or [string]::IsNullOrWhiteSpace($Summary)) {
            throw "new-decision requires -Title and -Summary"
        }
        $catalog = Get-Catalog
        $numbers = @($catalog.documents | Where-Object { $_.id -match '^DEC-(\d+)$' } | ForEach-Object { [int]$Matches[1] })
        $nextNumber = if ($numbers.Count -eq 0) { 1 } else { (($numbers | Measure-Object -Maximum).Maximum + 1) }
        $decisionId = "DEC-{0:D3}" -f [int]$nextNumber
        $tagList = @($Tags -split "," | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
        $affectList = @($Affects -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $supersededList = @($Supersedes -split "[,;]" | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
        $supersededList = @(foreach ($supersededId in $supersededList) {
            $target = $catalog.documents | Where-Object { $_.id -eq $supersededId } | Select-Object -First 1
            if (-not $target) { throw "Unknown document to supersede: $supersededId" }
            # Same rule the loader enforces: a mandatory document cannot be superseded.
            if (Test-DocumentMandatory $target) { throw "Superseded document cannot be mandatory: $($target.id)" }
            $target.id
        })
        $supersedesText = if ($supersededList.Count) { $supersededList -join ', ' } else { 'none' }
        $relativePath = "$storeName/decisions/$decisionId.md"
        $decisionPath = Resolve-ProjectPath $relativePath
        $body = @"
# ${decisionId}: $Title

- Status: active
- Date: $(Get-Date -Format 'yyyy-MM-dd')
- Tags: $($tagList -join ', ')
- Affects: $($affectList -join ', ')
- Supersedes: $supersedesText

## Context

Describe the problem and relevant constraints.

## Decision

$Summary

## Consequences

Record tradeoffs and follow-up work.

## Evidence

Add tests, measurements, commits, or alternatives considered.
"@
        [System.IO.File]::WriteAllText($decisionPath, $body.TrimStart() + "`r`n", [System.Text.UTF8Encoding]::new($false))
        $entry = [pscustomobject]@{
            id = $decisionId; level = 3; type = "decision"; status = "active"; priority = "high"
            tags = $tagList; affects = $affectList; path = $relativePath; alwaysLoad = $false
        }
        if ($supersededList.Count) { $entry | Add-Member -NotePropertyName supersedes -NotePropertyValue $supersededList }
        $catalog.documents = @($catalog.documents) + $entry
        Save-Catalog $catalog
        Write-Host "Created $decisionId at $relativePath" -ForegroundColor Green
    }

    "compact" {
        if ($KeepCompleted -lt 0) { throw "KeepCompleted cannot be negative" }
        $catalog = Get-Catalog
        $completed = @($catalog.documents |
            Where-Object { $_.type -eq "task" -and $_.status -eq "completed" -and [int]$_.level -lt 4 } |
            Sort-Object { (Get-Item -LiteralPath (Resolve-ProjectPath $_.path)).LastWriteTime } -Descending)
        $toArchive = @($completed | Select-Object -Skip $KeepCompleted)
        $archiveFolder = "$storeName/archive/$(Get-Date -Format 'yyyy-MM')"
        $archivePath = Resolve-ProjectPath $archiveFolder
        [System.IO.Directory]::CreateDirectory($archivePath) | Out-Null

        foreach ($entry in $toArchive) {
            $source = Resolve-ProjectPath $entry.path
            $destination = Join-Path $archivePath ([System.IO.Path]::GetFileName($source))
            Move-Item -LiteralPath $source -Destination $destination
            $entry.path = "$archiveFolder/$([System.IO.Path]::GetFileName($destination))"
            $entry.level = 4
            $entry.priority = "low"
        }
        Save-Catalog $catalog
        Write-Host "Archived $($toArchive.Count) completed tasks; kept $([math]::Min($completed.Count, $KeepCompleted)) in L2" -ForegroundColor Green
    }

    "validate" {
        $catalog = Get-Catalog
        $errors = @()
        $warnings = @()
        try { [void](Get-AliasGroups $catalog) } catch { $errors += $_.Exception.Message }
        $duplicateIds = @($catalog.documents | Group-Object id | Where-Object Count -gt 1)
        foreach ($duplicate in $duplicateIds) { $errors += "Duplicate id: $($duplicate.Name)" }
        $errors += @(Get-SupersedesErrors $catalog)

        foreach ($document in $catalog.documents) {
            $normalizedDocumentPath = ([string]$document.path).Replace("\", "/")
            if (-not $normalizedDocumentPath.StartsWith("$storeName/", [System.StringComparison]::OrdinalIgnoreCase)) {
                $errors += "Catalog documents must stay inside $storeName/: $($document.id) -> $($document.path)"
                continue
            }
            $path = Resolve-ProjectPath $document.path
            $resolved = [System.IO.Path]::GetFullPath($path)
            $rootWithSeparator = (Join-Path $projectRoot $storeName).TrimEnd('\') + '\'
            if (-not $resolved.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
                $errors += "Path escapes memory store for $($document.id): $($document.path)"
                continue
            }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $errors += "Missing file for $($document.id): $($document.path)"
                continue
            }
            $documentContent = Get-Content -LiteralPath $path -Raw
            $tokens = Get-TokenEstimate $documentContent
            $limit = switch ([int]$document.level) { 0 { 700 } 1 { 900 } 2 { 1800 } 3 { 2500 } default { 5000 } }
            if ($tokens -gt $limit) { $warnings += "$($document.id) is about $tokens tokens; L$($document.level) limit is $limit" }
            if ([int]$document.level -ge 4 -and ($document.alwaysLoad -or $document.priority -eq 'critical')) { $errors += "Archive document cannot be mandatory: $($document.id)" }
            if ([int]$document.level -le 2 -and $documentContent -match "(?m)\bTODO\b") {
                $warnings += "$($document.id) still contains TODO placeholders"
            }
        }

        $profilePath = Resolve-ProjectPath "$storeName/project-profile.json"
        if (Test-Path -LiteralPath $profilePath) {
            $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
            if (-not $profile.initialized) { $warnings += "N4ti has been installed but n4ti.cmd init has not been completed" }
            if ($profile.semanticAnalysis -eq "pending-orchestrator") { $warnings += "Deterministic init is complete; orchestrator semantic analysis is still pending" }
        }
        $resultCap = $null
        try { $resultCap = Get-ResultTokenCap } catch { $errors += $_.Exception.Message }
        $resultFiles = @(Get-ChildItem -LiteralPath (Resolve-ProjectPath "$storeName/results") -Filter "*.json" -File -ErrorAction SilentlyContinue)
        foreach ($resultFile in $resultFiles) {
            if ($null -eq $resultCap) { break }
            $resultTokens = Get-TokenEstimate (Get-Content -LiteralPath $resultFile.FullName -Raw)
            if ($resultTokens -gt $resultCap) { $warnings += "$($resultFile.Name) is about $resultTokens tokens; resultTokenCap is $resultCap" }
        }

        if ($errors.Count -gt 0) {
            $errors | ForEach-Object { Write-Host "ERROR: $_" -ForegroundColor Red }
            exit 1
        }
        $warnings | ForEach-Object { Write-Host "WARNING: $_" -ForegroundColor Yellow }
        Write-Host "N4ti valid: $($catalog.documents.Count) documents, $($warnings.Count) warnings" -ForegroundColor Green
    }

    default {
        @"
N4ti commands (gy.cmd remains a compatible alias):
  .\n4ti.cmd init -Idea "what to build" [-InitMode quick|guided] [-ModelMode uniform|adaptive|manual]
  .\n4ti.cmd complete-init
  .\n4ti.cmd route -Agent implementer
  .\n4ti.cmd task-packet -Id TASK-001 -Agent implementer [-Budget 3000] [-IncludeArchive]
  .\n4ti.cmd record-result -Id TASK-001 -Agent implementer -Summary "result" [-Files "a,b"] [-Tests "x"]
  .\n4ti.cmd save -Summary "progress" -Next "next step" [-Id TASK-001] [-Files "a,b"] [-Tests "reported tests"] [-Risks "pending checks"]
  .\n4ti.cmd resume [-Id TASK-001] [-Budget 5000]
  .\n4ti.cmd status
  .\n4ti.cmd search -Query "terms" [-IncludeArchive]
  .\n4ti.cmd context -Query "request" [-Budget 5000] [-IncludeArchive] [-Since PACK_ID]
  .\n4ti.cmd bench -Query "request one;request two" [-Budget 5000] [-IncludeArchive]
  .\n4ti.cmd get -Id DOCUMENT[#section]
  .\n4ti.cmd new-task -Title "title" [-Tags "tag1,tag2"]
  .\n4ti.cmd close-task -Id TASK-001 -Summary "result" -Next "next action"
  .\n4ti.cmd new-decision -Title "title" -Summary "decision" [-Tags "tag1"] [-Affects "path,TASK-001"] [-Supersedes "DEC-001"]
  .\n4ti.cmd compact [-KeepCompleted 5]
  .\n4ti.cmd validate

Memory store: $storeName/. Existing GY/ stores are preserved; dual stores are rejected.
save records only supplied progress, never transcripts or file contents; exclude credentials and personal data.
resume is read-only and selects the latest saved checkpoint (optionally restricted to a task).
Reported tests are not executed or promoted to verified evidence. Save never changes current-state.

Context and task-packet budgets include the complete generated output (estimated characters / 4).
Required documents and the assigned task are never omitted; an insufficient budget fails without writing output.
record-result requires an existing task and enabled agent; each result is saved separately as reported evidence.
A result above resultTokenCap (policies/orchestration.json, default 800 est. tokens) is rejected and not written.
close-task only updates current-state when closing its active task.
Search ignores accents and weights titles/tags/paths above body-only matches; source text stays unchanged.
Terms found in many units weigh less (IDF); optional units below 25% of the best match are only indexed.
Catalog "aliases" groups equivalent terms (e.g. ["architecture","arquitectura"]); equivalents count once.
History is excluded unless -IncludeArchive is supplied or a historical task is explicitly assigned.
Optional identical rendered document bodies are included once; search still lists every matching source.
Required documents are never deduplicated. Archived mandatory documents are rejected as invalid.
Catalog "supersedes" (list of ids) and "expires" ("yyyy-MM-dd", valid through that day) hide replaced or
outdated documents like history: -IncludeArchive brings them back, get still prints them under a "> Warning:"
line, and mandatory documents cannot be superseded or expired. validate reports unknown targets, self-references,
cycles, bad dates; a supersedes cycle also makes search/context/bench/task-packet fail without writing output.
bench is read-only: it builds the same packs as context and reports tokens, omissions and the shared pack prefix.
Optional documents above 200 estimated tokens are retrieved by "## " section (ID#section); a fully selected
document is emitted whole. Matches that do not fit are listed under "Not included"; get prints one by ID.
Every context pack ends with "- Pack id"; its manifest (.runtime/packs, last 20 kept) hashes each delivered unit.
context -Since PACK_ID keeps the same selection but sends only new or changed units; the rest are listed under
"Already delivered" ("- Documents: none" when nothing changed). The delta prints its own id for the next turn; an unknown id fails without writing output.
"@
    }
}
