# Run the offline safety suite without invoking the elevated WinPE builder.
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'BuildSafety.Tests.ps1')
