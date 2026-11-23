#Requires -Version 5.1
<#
.SYNOPSIS
    Export documentation metadata without running the builder or its tool recipes.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path $PSScriptRoot -Parent
$tokensFound = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repositoryRoot 'build-pnwc-winpe.ps1'), [ref]$tokensFound, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }
$catalog = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$Catalog'
}, $true)
if (-not $catalog) { throw 'Cannot find the static tool catalog.' }

$tools = @($catalog.Right.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.HashtableAst]
}, $false) | ForEach-Object {
    $fields = @{}
    foreach ($pair in $_.KeyValuePairs) {
        $key = $pair.Item1.SafeGetValue()
        if ($key -in @('Name', 'Dir', 'Type', 'Url', 'Urls', 'Page', 'Repo')) {
            # SafeGetValue accepts constants/constant arrays; it never invokes code.
            $fields[$key] = $pair.Item2.PipelineElements[0].Expression.SafeGetValue()
        }
    }
    if ($fields.Name -and $fields.Dir -and $fields.Type) {
        $upstream = if ($fields.Repo) { @('https://github.com/' + $fields.Repo) }
                    elseif ($fields.Page) { @($fields.Page) }
                    elseif ($fields.Urls) { @($fields.Urls) }
                    else { @($fields.Url) }
        [ordered]@{
            name = $fields.Name
            category = ($fields.Dir -split '\\')[0]
            directory = $fields.Dir -replace '\\', '/'
            acquisition = $fields.Type
            upstream = @($upstream)
            winPECompatibility = 'unverified'
        }
    }
})
$inventory = [ordered]@{
    schemaVersion = 1
    description = 'Acquisition recipes only; not a dependency lock, license grant, or compatibility certification.'
    tools = $tools
    extras = @(
        [ordered]@{ name = '7-Zip'; upstream = 'https://www.7-zip.org/'; purpose = 'Optional extractor and file manager; preparation execution requires opt-in.' },
        [ordered]@{ name = 'KAPE'; upstream = 'https://www.kroll.com/en/services/cyber/reactive-services/kroll-artifact-parser-and-extractor-kape'; purpose = 'Optional local archive for permitted use; current Kroll terms exclude third-party paid engagements.' },
        [ordered]@{ name = 'Ventoy extras'; upstream = @('https://www.memtest86.com/', 'https://gparted.org/', 'https://clonezilla.org/'); purpose = 'Optional separate boot payloads; not applications in the WinPE image.' }
    )
}
$json = $inventory | ConvertTo-Json -Depth 8
$encoding = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $repositoryRoot 'data/tools.json'), ($json -replace "`r`n", "`n") + "`n", $encoding)
Write-Host ('Exported {0} tool recipes.' -f $tools.Count)
