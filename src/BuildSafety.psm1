# Pure path checks are separated from the elevated builder for safe testing.
Set-StrictMode -Version 2.0

function Get-SafeLocalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path -match '[&|<>^%!"`\r\n*?]|[^\x20-\x7e]' -or $Path.Substring(2).Contains(':')) {
        throw 'Use a fully qualified ASCII local drive path without wildcards or command-shell metacharacters.'
    }
    if ($Path -match '(?:^|\\)\.{1,2}(?:\\|$)' -or $Path -match '[. ](?:\\|$)') {
        throw 'Relative path components and trailing dots/spaces are not supported.'
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -match '^[A-Za-z]:$') { throw 'A drive root cannot be used as a build or output path.' }
    return $full
}

function Get-SafeToolRelativePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path) -or $Path -match '[:&|<>^%!"`\r\n*?]|[^\x20-\x7e]' -or
        $Path -match '(?:^|[\\/])\.{1,2}(?:[\\/]|$)' -or $Path -match '[. ](?:[\\/]|$)') {
        throw "Tool paths must stay inside their tool directory and contain no shell metacharacters: $Path"
    }
    return $Path.Replace('/', '\')
}

function Test-PathWithin {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Parent)
    $candidate = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $base = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return $candidate.Equals($base, [StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing a reparse point in the build path: $current"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($current.TrimEnd('\'))
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Assert-BuildRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)
    $safe = Get-SafeLocalPath $Root
    foreach ($protected in @($env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if ($protected -and ((Test-PathWithin $safe $protected) -or (Test-PathWithin $protected $safe))) {
            throw "The build root overlaps a protected system directory: $protected"
        }
    }
    if ($env:USERPROFILE -and (Test-PathWithin $env:USERPROFILE $safe)) {
        throw 'Use a dedicated build directory, not a user profile or its parent.'
    }
    Assert-NoReparsePath $safe
    return $safe
}

function Assert-OwnedBuildDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)
    $build = Join-Path $Root 'Build'
    Assert-NoReparsePath $build
    if (Test-Path -LiteralPath $build) {
        $marker = Join-Path $build '.pnwc-build-owned'
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or
            (Get-Content -LiteralPath $marker -Raw).Trim() -ne 'PNWC-WinPE-Builder v1') {
            throw "Refusing to delete an unrecognized Build directory: $build. Choose a fresh dedicated -Root."
        }
    }
}

function Remove-SafeBuildItem {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$AllowedRoot)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $base = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\')
    if ($full -eq $base -or -not (Test-PathWithin $full $base)) { throw "Deletion escapes its allowed directory: $full" }
    Assert-NoReparsePath $full
    if (Test-Path -LiteralPath $full) {
        if (Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction Stop |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
            Select-Object -First 1) {
            throw "Refusing recursive deletion containing a reparse point: $full"
        }
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    }
}

Export-ModuleMember -Function Get-SafeLocalPath, Get-SafeToolRelativePath, Test-PathWithin, Assert-NoReparsePath, Assert-BuildRoot, Assert-OwnedBuildDirectory, Remove-SafeBuildItem
