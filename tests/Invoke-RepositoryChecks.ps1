#Requires -Version 5.1
<#
.SYNOPSIS
    Validate repository source, inventory, links and publication hygiene offline.
.DESCRIPTION
    Parses PowerShell and literal metadata without invoking the builder or any
    third-party tools. Requires only Windows PowerShell 5.1 or PowerShell 7.
#>
[CmdletBinding()]
param([string]$RepositoryRoot)

$ErrorActionPreference = 'Stop'
if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent }
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$failures = New-Object 'System.Collections.Generic.List[string]'
$counts = @{ Files = 0; PowerShell = 0; Embedded = 0; Json = 0; Tools = 0; Examples = 0; Markdown = 0; LocalLinks = 0 }
function Add-Failure([string]$Message) {
    $failures.Add($Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}
function Get-RelativeName([string]$Path) {
    $Path.Substring($RepositoryRoot.Length + 1).Replace('\', '/')
}
function Get-SourceFiles {
    $pending = New-Object 'System.Collections.Generic.Queue[string]'
    $pending.Enqueue($RepositoryRoot)
    while ($pending.Count) {
        $directory = $pending.Dequeue()
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
            if ($item.Name -eq '.git') { continue }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Add-Failure "Redirected repository path: $(Get-RelativeName $item.FullName)"
                continue
            }
            if ($item.PSIsContainer) { $pending.Enqueue($item.FullName) }
            else { $item }
        }
    }
}
function Get-LiteralExpression($Statement) {
    if ($Statement -is [System.Management.Automation.Language.CommandExpressionAst]) { return $Statement.Expression }
    if ($Statement -is [System.Management.Automation.Language.PipelineAst] -and
        $Statement.PipelineElements.Count -eq 1 -and
        $Statement.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
        return $Statement.PipelineElements[0].Expression
    }
    throw 'Expected a literal expression, not executable metadata.'
}
function Get-Assignment($Ast, [string]$Name) {
    $matches = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq $Name
    }, $true))
    if ($matches.Count -ne 1) { throw "Expected one literal assignment to $Name." }
    return Get-LiteralExpression $matches[0].Right
}
function Get-CatalogMetadata($Ast) {
    $array = Get-Assignment $Ast 'Catalog'
    if ($array -isnot [System.Management.Automation.Language.ArrayExpressionAst]) { throw 'Catalog must be a literal array.' }
    foreach ($statement in $array.SubExpression.Statements) {
        $table = Get-LiteralExpression $statement
        if ($table -isnot [System.Management.Automation.Language.HashtableAst]) { throw 'Catalog entries must be literal hashtables.' }
        $fields = @{}
        foreach ($pair in $table.KeyValuePairs) {
            if ($pair.Item1 -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
            $key = $pair.Item1.Value
            if ($key -notin @('Name', 'Dir', 'Type')) { continue }
            $value = Get-LiteralExpression $pair.Item2
            if ($value -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { throw "Catalog $key must be a literal string." }
            $fields[$key] = $value.Value
        }
        foreach ($key in @('Name', 'Dir', 'Type')) {
            if (-not $fields.ContainsKey($key) -or -not $fields[$key]) { throw "Catalog entry is missing $key." }
        }
        [pscustomobject]$fields
    }
}
function Get-MarkdownText([string]$Content) {
    # Code examples are not rendered Markdown links.
    $kept = New-Object 'System.Collections.Generic.List[string]'
    $fence = $null
    foreach ($line in ($Content -split '\r?\n')) {
        if ($line -match '^\s{0,3}(`{3,}|~{3,})') {
            $marker = $Matches[1]
            if (-not $fence) { $fence = $marker[0] }
            elseif ($marker[0] -eq $fence) { $fence = $null }
            continue
        }
        if (-not $fence) { $kept.Add($line) }
    }
    $kept -join "`n"
}
function Get-MarkdownAnchors([string]$Content) {
    $anchors = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $duplicates = @{}
    foreach ($line in ((Get-MarkdownText $Content) -split '\n')) {
        if ($line -match '^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$') {
            $heading = $Matches[1] -replace '<[^>]+>', ''
            $heading = $heading -replace '\[([^\]]+)\]\([^)]*\)', '$1'
            $slug = ($heading.ToLowerInvariant() -replace '[^\p{L}\p{M}\p{N}_\-\s]', '') -replace '\s', '-'
            if ($duplicates.ContainsKey($slug)) { $duplicates[$slug]++; $slug = "$slug-$($duplicates[$slug])" }
            else { $duplicates[$slug] = 0 }
            [void]$anchors.Add($slug)
        }
    }
    foreach ($match in [regex]::Matches($Content, '<a\s+(?:id|name)=["'']([^"'']+)["'']', 'IgnoreCase')) {
        [void]$anchors.Add($match.Groups[1].Value)
    }
    return ,$anchors
}

try {
    if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) { throw 'Repository root does not exist.' }
    $files = @(Get-SourceFiles)
    $counts.Files = $files.Count
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($file in $files) { [void]$names.Add((Get-RelativeName $file.FullName)) }
    $required = @('README.md', 'LICENSE', 'CONTRIBUTING.md', 'SECURITY.md', 'THIRD_PARTY_NOTICES.md',
        'CHANGELOG.md', '.gitignore', '.gitattributes', '.editorconfig', 'build-pnwc-winpe.ps1',
        'src/BuildSafety.psm1', 'docs/TOOLS.md', 'docs/VALIDATION.md', 'docs/CYBERSECURITY-INTEGRATION.md',
        'data/tools.json', 'data/required-inputs.json', 'examples/README.md', 'examples/launch.txt.example',
        '.github/workflows/validate.yml', '.github/CODEOWNERS')
    foreach ($path in $required) { if (-not $names.Contains($path)) { Add-Failure "Missing required file: $path" } }
    $examplePath = Join-Path $RepositoryRoot 'examples/launch.txt.example'
    if (Test-Path -LiteralPath $examplePath) {
        foreach ($line in [IO.File]::ReadAllLines($examplePath)) {
            if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') { continue }
            $fields = $line -split '\|'
            if ($fields.Count -ne 4 -or -not $fields[0] -or -not $fields[1] -or
                $fields[1] -match '(^[\\/]|:|(?:^|[\\/])\.\.(?:[\\/]|$))' -or
                $fields[3] -notin @('gui', 'console')) { Add-Failure 'Launcher example must contain name|relative-path|args|gui-or-console.' }
            $counts.Examples++
        }
        if (-not $counts.Examples) { Add-Failure 'Launcher example contains no entries.' }
    }

    $builderAst = $null
    foreach ($file in ($files | Where-Object { $_.Extension -in @('.ps1', '.psm1') })) {
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        $counts.PowerShell++
        foreach ($errorRecord in $parseErrors) { Add-Failure "PowerShell parse error in $(Get-RelativeName $file.FullName):$($errorRecord.Extent.StartLineNumber): $($errorRecord.Message)" }
        if ((Get-RelativeName $file.FullName) -eq 'build-pnwc-winpe.ps1') { $builderAst = $ast }
    }
    if ($builderAst) {
        try {
            $launcher = Get-Assignment $builderAst 'launcher'
            if ($launcher -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -or
                $launcher.StringConstantType -ne 'SingleQuotedHereString') { throw 'Launcher must be a literal single-quoted here-string.' }
            $tokens = $null; $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($launcher.Value, [ref]$tokens, [ref]$parseErrors)
            $counts.Embedded++
            foreach ($errorRecord in $parseErrors) { Add-Failure "Embedded launcher parse error at line $($errorRecord.Extent.StartLineNumber): $($errorRecord.Message)" }
        } catch { Add-Failure "Embedded launcher: $($_.Exception.Message)" }
    }

    $jsonDocuments = @{}
    foreach ($file in ($files | Where-Object { $_.Extension -eq '.json' })) {
        try { $jsonDocuments[(Get-RelativeName $file.FullName)] = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json; $counts.Json++ }
        catch { Add-Failure "Invalid JSON: $(Get-RelativeName $file.FullName)" }
    }
    if ($jsonDocuments.ContainsKey('data/tools.json') -and $builderAst) {
        try {
            $inventory = $jsonDocuments['data/tools.json']
            if ($inventory.schemaVersion -ne 1 -or $inventory.tools -isnot [System.Array] -or $inventory.tools.Count -lt 1) { throw 'Expected schemaVersion 1 and a nonempty tools array.' }
            $catalog = @(Get-CatalogMetadata $builderAst)
            $seenNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            $seenDirectories = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($tool in $inventory.tools) {
                foreach ($field in @('name', 'category', 'directory', 'acquisition', 'winPECompatibility')) {
                    $property = $tool.PSObject.Properties[$field]
                    if (-not $property -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value)) { throw "Tool entry lacks string field $field." }
                }
                if (-not $seenNames.Add($tool.name) -or -not $seenDirectories.Add($tool.directory)) { throw "Duplicate tool name or directory: $($tool.name)" }
                if ($tool.directory -notmatch '^[A-Za-z0-9+_. -]+/[A-Za-z0-9+_. -]+$' -or $tool.directory.Contains('..')) { throw "Unsafe relative tool directory: $($tool.name)" }
                if ($tool.category -cne ($tool.directory -split '/')[0]) { throw "Category disagrees with directory: $($tool.name)" }
                if ($tool.acquisition -notin @('direct', 'scrape', 'file', 'unpack', 'nupkg', 'multi', 'github')) { throw "Unknown acquisition type: $($tool.name)" }
                if ($tool.winPECompatibility -cne 'unverified') { throw "Compatibility needs a reviewed validation schema: $($tool.name)" }
                if ($tool.upstream -isnot [System.Array] -or $tool.upstream.Count -lt 1) { throw "Missing upstream URLs: $($tool.name)" }
                foreach ($url in $tool.upstream) {
                    $uri = $null
                    if ($url -isnot [string] -or -not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or
                        $uri.Scheme -ne 'https' -or -not $uri.Host -or $uri.UserInfo) { throw "Invalid HTTPS upstream URL: $($tool.name)" }
                }
                $matching = @($catalog | Where-Object { $_.Name -ceq $tool.name })
                if ($matching.Count -ne 1 -or $matching[0].Dir.Replace('\', '/') -cne $tool.directory -or $matching[0].Type -cne $tool.acquisition) { throw "Inventory differs from builder catalog: $($tool.name)" }
                $counts.Tools++
            }
            if ($catalog.Count -ne $counts.Tools) { throw "Catalog has $($catalog.Count) tools but inventory has $($counts.Tools)." }
        } catch { Add-Failure "Tool inventory: $($_.Exception.Message)" }
    }
    if ($jsonDocuments.ContainsKey('data/required-inputs.json')) {
        $inputs = $jsonDocuments['data/required-inputs.json']
        if ($inputs.schemaVersion -ne 1 -or -not $inputs.required -or -not $inputs.optionalLocalInputs -or -not $inputs.neverPublish) { Add-Failure 'Input checklist is missing schemaVersion 1 or required sections.' }
        foreach ($item in $inputs.required) { if (-not $item.name -or -not $item.source -or $item.storedInGit -ne $false) { Add-Failure 'Required inputs must be named, sourced and excluded from Git.' } }
    }

    $anchorCache = @{}
    foreach ($file in ($files | Where-Object { $_.Extension -eq '.md' })) {
        $counts.Markdown++
        $content = Get-MarkdownText ([IO.File]::ReadAllText($file.FullName))
        $targets = New-Object 'System.Collections.Generic.List[string]'
        foreach ($match in [regex]::Matches($content, '!?\[[^\]\r\n]*\]\(\s*(<[^>]+>|[^\s)]+)')) { $targets.Add($match.Groups[1].Value.Trim('<', '>')) }
        foreach ($match in [regex]::Matches($content, '(?m)^\s{0,3}\[[^\]]+\]:\s*(<[^>]+>|\S+)')) { $targets.Add($match.Groups[1].Value.Trim('<', '>')) }
        foreach ($target in $targets) {
            if ($target -match '^[A-Za-z][A-Za-z0-9+.-]*:' -and $target -notmatch '^file:') { continue }
            $counts.LocalLinks++
            try {
                if ($target -match '^(?:file:|[\\/])') { throw 'Use repository-relative links.' }
                $parts = $target -split '#', 2
                $local = [Uri]::UnescapeDataString(($parts[0] -split '\?', 2)[0])
                $resolved = if ($local) { [IO.Path]::GetFullPath((Join-Path $file.DirectoryName $local)) } else { $file.FullName }
                $isRoot = $resolved.Equals($RepositoryRoot, [StringComparison]::OrdinalIgnoreCase)
                if (-not $isRoot -and -not $resolved.StartsWith($RepositoryRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Link escapes the repository.' }
                $relative = if ($isRoot) { '.' } else { Get-RelativeName $resolved }
                if (-not (Test-Path -LiteralPath $resolved)) { throw 'Target does not exist.' }
                if ((Test-Path -LiteralPath $resolved -PathType Leaf) -and -not $names.Contains($relative)) { throw 'Target case does not match the file name.' }
                if ($parts.Count -eq 2 -and $parts[1] -and [IO.Path]::GetExtension($resolved) -eq '.md') {
                    if (-not $anchorCache.ContainsKey($resolved)) { $anchorCache[$resolved] = Get-MarkdownAnchors ([IO.File]::ReadAllText($resolved)) }
                    if (-not $anchorCache[$resolved].Contains([Uri]::UnescapeDataString($parts[1]))) { throw 'Heading fragment does not exist.' }
                }
            } catch { Add-Failure "Markdown link in $(Get-RelativeName $file.FullName): $target ($($_.Exception.Message))" }
        }
    }

    $payloadExtensions = @('.iso', '.wim', '.esd', '.vhd', '.vhdx', '.img', '.cab', '.msu', '.exe', '.dll', '.sys', '.zip', '.7z', '.gz', '.msi', '.nupkg', '.cvd', '.cld', '.evtx', '.dmp', '.mem', '.log', '.key', '.pem', '.pfx', '.p12', '.dat', '.license')
    $secretPatterns = @('\bgh[pousr]_[A-Za-z0-9]{30,}\b', '\bgithub_pat_[A-Za-z0-9_]{70,}\b',
        '\b(?:AKIA|ASIA)[A-Z0-9]{16}\b', '\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{40,}\b',
        '(?m)^-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----\r?$',
        '(?m)^-----START_OF_KEY-----\r?$')
    foreach ($file in $files) {
        $relative = Get-RelativeName $file.FullName
        if ($file.Extension.ToLowerInvariant() -in $payloadExtensions -or
            $relative -match '^(Build|Source|Downloads|Logs|Ventoy|PNWC-Logs|artifacts)/' -or
            ($file.Name -like '.env*' -and $file.Name -ne '.env.example')) { Add-Failure "Private input or generated payload in repository: $relative" }
        if ($file.Length -gt 2MB) { Add-Failure "Unexpected large source file: $relative"; continue }
        $content = [IO.File]::ReadAllText($file.FullName)
        foreach ($pattern in $secretPatterns) {
            if ([regex]::IsMatch($content, $pattern)) { Add-Failure "Possible embedded credential or private key in $relative (value withheld)."; break }
        }
    }
    $ignorePath = Join-Path $RepositoryRoot '.gitignore'
    if (Test-Path -LiteralPath $ignorePath) {
        $ignoreLines = [IO.File]::ReadAllLines($ignorePath)
        foreach ($pattern in @('/Source/', '/Downloads/', '/Logs/', '*.iso', '*.wim', '*.vhd', '*.exe', '*.dll', 'key.dat')) {
            if ($ignoreLines -notcontains $pattern) { Add-Failure "Missing publication exclusion in .gitignore: $pattern" }
        }
    }
} catch { Add-Failure "Repository check stopped: $($_.Exception.Message)" }

Write-Host ("Checked {0} files: {1} PowerShell sources, {2} embedded launcher, {3} JSON documents, {4} catalog tools, {5} example entries, {6} Markdown files, {7} local links." -f
    $counts.Files, $counts.PowerShell, $counts.Embedded, $counts.Json, $counts.Tools, $counts.Examples, $counts.Markdown, $counts.LocalLinks)
if ($failures.Count) { Write-Host "$($failures.Count) repository check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'Repository checks passed. No build, download, media write or runtime tool validation was performed.' -ForegroundColor Green
exit 0
