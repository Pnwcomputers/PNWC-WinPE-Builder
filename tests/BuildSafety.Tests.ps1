# Safe offline checks. This file never imports or executes the elevated builder.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\BuildSafety.psm1') -Force
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw $Message }
}

foreach ($bad in @('C:\', 'relative', '\\server\share\build', 'C:relative', 'C:\a\..\b', 'C:\a&b', 'C:\a%TEMP%', 'C:\a!b', "C:\a`nb", 'C:\a\b.', 'C:\a:stream')) {
    Assert-Throws { Get-SafeLocalPath $bad } "Unsafe path was accepted: $bad"
}
Assert-True ((Get-SafeLocalPath 'C:\PNWC Build') -eq 'C:\PNWC Build') 'Spaces in a safe path should work.'
Assert-Throws { Get-SafeLocalPath ('C:\' + [char]0x00E9) } 'Non-ASCII paths cannot be encoded in the ADK command file.'
foreach ($bad in @('..\escape.exe', 'tool\..\escape.exe', 'C:\escape.exe', '\\server\share\escape.exe', 'tool\exe&whoami.exe')) {
    Assert-Throws { Get-SafeToolRelativePath $bad } "An escaping launcher path was accepted: $bad"
}
Assert-True ((Get-SafeToolRelativePath 'bin\tool.exe') -eq 'bin\tool.exe') 'A normal launcher path was rejected.'
Assert-Throws { Assert-BuildRoot $env:USERPROFILE } 'A user profile cannot be a build root.'
Assert-Throws { Assert-BuildRoot $env:WINDIR } 'The Windows directory cannot be a build root.'
Assert-True (Test-PathWithin 'C:\PNWC\Build' 'C:\PNWC') 'Build must be inside its root.'
Assert-True (-not (Test-PathWithin 'C:\PNWC-other\Build' 'C:\PNWC')) 'Sibling prefixes must not count as descendants.'
Assert-Throws { Remove-SafeBuildItem -Path 'C:\PNWC-other\Build' -AllowedRoot 'C:\PNWC' } 'Deletion escaped its root.'
Assert-Throws { Remove-SafeBuildItem -Path 'C:\PNWC' -AllowedRoot 'C:\PNWC' } 'Deleting the allowed root must fail.'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('pnwc-safety-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -Path (Join-Path $testRoot 'Build') -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $testRoot 'Build\keep.txt') -Value 'sentinel'
    Assert-Throws { Assert-OwnedBuildDirectory $testRoot } 'An unrelated Build directory was accepted.'
    Assert-True (Test-Path -LiteralPath (Join-Path $testRoot 'Build\keep.txt')) 'The unowned sentinel was changed.'
    Set-Content -LiteralPath (Join-Path $testRoot 'Build\.pnwc-build-owned') -Value 'PNWC-WinPE-Builder v1'
    Assert-OwnedBuildDirectory $testRoot
    Remove-SafeBuildItem -Path (Join-Path $testRoot 'Build') -AllowedRoot $testRoot
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'Build'))) 'Owned build deletion failed.'

    $target = Join-Path $testRoot 'target'
    $junction = Join-Path $testRoot 'junction'
    New-Item -Path $target -ItemType Directory | Out-Null
    Set-Content -LiteralPath (Join-Path $target 'keep.txt') -Value 'sentinel'
    New-Item -Path $junction -ItemType Junction -Value $target | Out-Null
    try {
        Assert-Throws { Assert-NoReparsePath (Join-Path $junction 'child') } 'A junction ancestor was accepted.'
        Assert-Throws { Remove-SafeBuildItem -Path $junction -AllowedRoot $testRoot } 'Junction deletion was accepted.'
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'keep.txt')) 'The junction target changed.'
    } finally { [IO.Directory]::Delete($junction) }
    Write-Host 'BuildSafety checks passed.' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-SafeBuildItem -Path $testRoot -AllowedRoot ([IO.Path]::GetTempPath())
    }
}
