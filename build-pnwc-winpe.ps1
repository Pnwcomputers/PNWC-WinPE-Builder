#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Builds an x64 WinPE environment for deployment, recovery and authorized offline triage.

.DESCRIPTION
    One run:
      1. Downloads tools into C:\PNWC-PE\Source\Tools (cached).
         Downloaded helper execution requires -AllowToolExecution. No host installers run.
      2. Builds WinPE from the ADK (optional components in Microsoft's dependency order)
      3. Injects drivers from Source\Drivers, applies any CU in Source\Updates
      4. Puts the tools on the media + a launcher menu that starts at boot
      5. Makes the ISO, and stages Ventoy extras (MemTest86 etc.) in C:\PNWC-PE\Ventoy
      6. Prints a per-tool OK / FAILED table so you can see exactly what made it in

.PARAMETER AllowToolExecution
    Permit downloaded 7-Zip, freshclam and KAPE helpers to run on the elevated build host.
    Review vendor sources and artifacts first. This does not establish their trustworthiness.
.PARAMETER AllowUsbFormat
    Explicitly authorize reformatting the removable USB target supplied by -UsbDrive.
.PARAMETER AllowVhdRebuild
    Permit rewriting a previously created, recognized PNWC VHD. Its boot partition and
    Tools directory are replaced; unrelated VHDs are refused.
.PARAMETER Root
    Dedicated absolute ASCII local build directory. Defaults to C:\PNWC-PE.
    Existing Build directories require this project's ownership marker.
.PARAMETER IsoName
    Simple output ISO filename. Defaults to PNWC-PE.iso.
.PARAMETER UsbDrive
    Optional removable USB drive letter, such as E:. Requires -AllowUsbFormat.
.PARAMETER BootEx
    Request the ADK /bootex media option. Confirm compatibility with your firmware,
    Secure Boot state and installed ADK before selecting it.
.PARAMETER RefreshTools
    Replace cached managed tool directories with fresh downloads.
.PARAMETER SkipDownloads
    Use manually staged or previously cached Source\Tools without downloading tools.
.PARAMETER SkipVentoyExtras
    Skip separate MemTest86, GParted and Clonezilla media downloads.
.PARAMETER VhdPath
    Optional absolute local .vhd output for virtual HDD boot. New files are fixed-size.
    An existing recognized project VHD additionally requires -AllowVhdRebuild.
.PARAMETER VhdSizeGB
    Fixed size of a newly created VHD in GB, from 8 through 2000. Defaults to 80.
    This does not resize an existing VHD.
.PARAMETER Lang
    WinPE language identifier, such as en-us. Matching optional-component language
    CABs are included when present in the installed WinPE add-on.
.PARAMETER ScratchMB
    WinPE scratch space in MB: 32, 64, 128, 256 or 512. Defaults to 512.

.EXAMPLE
    .\Build-PNWC-PE.ps1 -BootEx                 # full build, uses cached tools where present
    .\Build-PNWC-PE.ps1 -BootEx -RefreshTools   # re-download every tool
#>
[CmdletBinding()]
param(
    [string]$Root      = 'C:\PNWC-PE',
    [string]$IsoName   = 'PNWC-PE.iso',
    [string]$UsbDrive,
    [switch]$AllowUsbFormat,
    [switch]$AllowVhdRebuild,
    [switch]$AllowToolExecution,
    [switch]$BootEx,
    [switch]$RefreshTools,
    [switch]$SkipDownloads,
    [switch]$SkipVentoyExtras,
    [string]$VhdPath,                 # e.g. 'E:\VHD\PNWC-PE.vhd' on the IODD (in HDD mode) - builds a bootable VHD too
    [ValidateRange(8, 2000)][int]$VhdSizeGB = 80,
    [ValidatePattern('^[a-zA-Z]{2,3}-[a-zA-Z]{2,4}$')][string]$Lang = 'en-us',
    [ValidateSet(32, 64, 128, 256, 512)][int]$ScratchMB = 512
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSEdition -ne 'Desktop' -or
    $PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess) {
    throw 'Run this builder in elevated 64-bit Windows PowerShell 5.1 (powershell.exe), not PowerShell 7.'
}
Import-Module (Join-Path $PSScriptRoot 'src\BuildSafety.psm1') -Force
$Root = Assert-BuildRoot $Root
Assert-OwnedBuildDirectory $Root
if ($IsoName -notmatch '^[A-Za-z0-9][A-Za-z0-9._ -]*\.iso$' -or $IsoName.Contains('..')) {
    throw '-IsoName must be a simple .iso filename without paths or command-shell metacharacters.'
}
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$WorkDir   = Join-Path $Root 'Build'
$SourceDir = Join-Path $Root 'Source'
$ToolsSrc  = Join-Path $SourceDir 'Tools'
$DlCache   = Join-Path $Root 'Downloads'
$LogDir    = Join-Path $Root 'Logs'
$VentoyDir = Join-Path $Root 'Ventoy'
$IsoPath   = Join-Path $Root $IsoName
$Mount     = Join-Path $WorkDir 'mount'
$Media     = Join-Path $WorkDir 'media'
$UA        = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) PNWC-PE-Builder/2'

foreach ($path in @($SourceDir, $ToolsSrc, $DlCache, $LogDir, $VentoyDir, $IsoPath)) { Assert-NoReparsePath $path }

if ($UsbDrive) {
    if (-not $AllowUsbFormat) { throw '-UsbDrive reformats a removable USB volume. Supply -AllowUsbFormat to explicitly authorize it.' }
    if ($UsbDrive -notmatch '^[D-Zd-z]:$') { throw '-UsbDrive must be a drive letter such as E:.' }
    $usbVolume = Get-Volume -DriveLetter $UsbDrive[0]
    $usbDisk = Get-Partition -DriveLetter $UsbDrive[0] | Get-Disk
    if ($usbVolume.DriveType -ne 'Removable' -or $usbDisk.BusType -ne 'USB' -or $usbDisk.IsBoot -or $usbDisk.IsSystem) {
        throw 'The USB target must be a removable USB volume on a non-system, non-boot disk.'
    }
    $UsbTargetUniqueId = $usbDisk.UniqueId
    foreach ($hostPath in @($Root, $VhdPath) | Where-Object { $_ }) {
        $hostLetter = (Split-Path $hostPath -Qualifier).TrimEnd(':')
        $hostDisk = Get-Partition -DriveLetter $hostLetter | Get-Disk
        if ($hostDisk.Number -eq $usbDisk.Number) { throw 'The USB target cannot share a disk with the build root or VHD file.' }
    }
}

foreach ($d in $LogDir, $DlCache, $VentoyDir, $ToolsSrc, (Join-Path $SourceDir 'Drop'), (Join-Path $SourceDir 'Updates'),
               (Join-Path $SourceDir 'Drivers\Storage'), (Join-Path $SourceDir 'Drivers\Network'), (Join-Path $SourceDir 'Drivers\GPU')) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
if ($VhdPath) {
    # Fail fast, before the long build, if the VHD target isn't a writable disk with room
    $VhdPath = Get-SafeLocalPath $VhdPath
    Assert-NoReparsePath $VhdPath
    if ($VhdPath -notmatch '\.vhd$') { throw '-VhdPath must end in .vhd.' }
    foreach ($protected in @($WorkDir, $SourceDir, $DlCache, $LogDir)) {
        if (Test-PathWithin $VhdPath $protected) { throw "The VHD path cannot be inside $protected" }
    }
    if ((Test-Path -LiteralPath $VhdPath) -and -not $AllowVhdRebuild) {
        throw 'The VHD already exists. -AllowVhdRebuild is required, and only recognized PNWC layouts are accepted.'
    }
    if ((Test-Path -LiteralPath $VhdPath) -and (Get-DiskImage -ImagePath $VhdPath).Attached) { throw 'Detach the VHD before rebuilding it.' }
    $qual = Split-Path $VhdPath -Qualifier
    $vol  = Get-Volume -DriveLetter $qual.TrimEnd(':') -ErrorAction SilentlyContinue
    if (-not $vol) { throw "Drive $qual not found. Put the IODD in HDD mode and check its drive letter with Get-Volume." }
    if ($vol.DriveType -eq 'CD-ROM') { throw "$qual is the IODD's virtual CD/DVD. Switch the IODD to HDD mode and use the drive letter of its partition." }
    if ($vol.FileSystem -notin 'NTFS', 'exFAT') { throw "$qual is $($vol.FileSystem); a $VhdSizeGB GB VHD file needs NTFS or exFAT (FAT32 caps files at 4 GB)." }
    if (-not (Test-Path $VhdPath) -and $vol.SizeRemaining -lt ($VhdSizeGB * 1GB + 1GB)) {
        throw "$qual has $([math]::Round($vol.SizeRemaining/1GB)) GB free; a fixed $VhdSizeGB GB VHD needs more. Use -VhdSizeGB to go smaller."
    }
    try { $probe = Join-Path ($qual + '\') ('pnwcpe-write-test-' + [guid]::NewGuid().ToString('N') + '.tmp'); [IO.File]::WriteAllText($probe, 'x'); Remove-Item -LiteralPath $probe }
    catch { throw "$qual is not writable (IODD write protection on?): $($_.Exception.Message)" }
}
$Stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
Start-Transcript -Path (Join-Path $LogDir "build-$Stamp.log") | Out-Null
try {

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

#region ---------- ADK ----------
$kitsRoot = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue).KitsRoot10
if (-not $kitsRoot) { $kitsRoot = "${env:ProgramFiles(x86)}\Windows Kits\10\" }
$Adk   = Join-Path $kitsRoot 'Assessment and Deployment Kit'
$OcDir = Join-Path $Adk 'Windows Preinstallation Environment\amd64\WinPE_OCs'
$DandI = Join-Path $Adk 'Deployment Tools\DandISetEnv.bat'
if ($DandI -match '[^\x20-\x7e]|[&|<>^%!"`\r\n]') { throw 'The ADK installation path must contain ASCII characters and no command-shell metacharacters.' }
foreach ($p in $DandI, $OcDir) {
    if (-not (Test-Path $p)) { throw "Not found: $p`nInstall the ADK (Deployment Tools) and the matching Windows PE add-on." }
}
$RequiredOcs = @('WinPE-WMI', 'WinPE-NetFx', 'WinPE-Scripting', 'WinPE-PowerShell', 'WinPE-StorageWMI', 'WinPE-DismCmdlets')
foreach ($oc in $RequiredOcs) {
    if (-not (Test-Path -LiteralPath (Join-Path $OcDir "$oc.cab"))) { throw "Required WinPE component is missing: $oc" }
}
function Invoke-Adk([string]$CommandLine) {
    Write-Host "   $CommandLine" -ForegroundColor DarkGray
    $cmdFile = Join-Path $env:TEMP ("pnwcpe-{0}.cmd" -f [guid]::NewGuid())
    Set-Content -Path $cmdFile -Encoding Ascii -Value "@echo off`r`ncall `"$DandI`" >nul`r`nif errorlevel 1 exit /b %ERRORLEVEL%`r`n$CommandLine`r`nexit /b %ERRORLEVEL%"
    try { & cmd.exe /c "`"$cmdFile`""; $rc = $LASTEXITCODE } finally { Remove-Item $cmdFile -ErrorAction SilentlyContinue }
    if ($rc -ne 0) { throw "Failed ($rc): $CommandLine" }
}
#endregion

#region ---------- Download helpers ----------
$Results = New-Object System.Collections.Generic.List[object]
$DownloadManifest = New-Object System.Collections.Generic.List[object]
function Add-Result($Tool, $Status, $Detail) {
    $Results.Add([pscustomobject]@{ Tool = $Tool; Status = $Status; Detail = $Detail })
    $c = @{ OK = 'Green'; CACHED = 'DarkGreen'; FAILED = 'Red'; WARN = 'Yellow'; MANUAL = 'DarkYellow' }[$Status]
    Write-Host ("   [{0,-6}] {1}  {2}" -f $Status, $Tool, $Detail) -ForegroundColor $c
}

function Get-File([string]$Url, [string]$OutFile) {
    if (([Uri]$Url).Scheme -ne 'https') { throw "Only HTTPS download sources are allowed: $Url" }
    # curl.exe (built into Win10/11) follows redirects cleanly, incl. SourceForge mirrors
    # SourceForge serves a JS interstitial to browser UAs but a direct mirror redirect to wget-style clients
    $agent = if ($Url -match 'sourceforge\.net') { 'Wget/1.21.4' } else { $UA }
    & curl.exe -fsSL --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 2 -A $agent -o $OutFile $Url
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -lt 1024) {
        Remove-Item $OutFile -ErrorAction SilentlyContinue
        throw "download failed (curl $LASTEXITCODE): $Url"
    }
    $DownloadManifest.Add([pscustomobject]@{
        Timestamp = (Get-Date).ToUniversalTime().ToString('o'); Url = $Url; File = $OutFile
        Bytes = (Get-Item -LiteralPath $OutFile).Length; SHA256 = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash
    })
    $DownloadManifest | Export-Csv -LiteralPath (Join-Path $LogDir "downloads-$Stamp.csv") -NoTypeInformation
}

function Find-Link([string]$Page, [string]$Pattern) {
    if (([Uri]$Page).Scheme -ne 'https') { throw "Only HTTPS source pages are allowed: $Page" }
    $pageHtml = & curl.exe -fsSL --proto '=https' --proto-redir '=https' --retry 3 -A $UA $Page
    if ($LASTEXITCODE -ne 0) { throw "Unable to retrieve HTTPS source page: $Page" }
    $hrefs = @([regex]::Matches(($pageHtml -join "`n"), '(?:href|src)\s*=\s*["'']([^"'']+)["'']') |
        ForEach-Object { $_.Groups[1].Value })
    $hit = $hrefs | Where-Object { $_ -and ($_ -replace '&amp;', '&') -match $Pattern } | Select-Object -First 1
    if (-not $hit) { throw "no link matching '$Pattern' on $Page" }
    ([Uri]::new([Uri]$Page, ($hit -replace '&amp;', '&'))).AbsoluteUri
}

function Find-GitHubAsset([string]$Repo, [string]$Pattern, [string]$Exclude = '^\b$') {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = $UA } -UseBasicParsing
    $a = $rel.assets | Where-Object { $_.name -match $Pattern -and $_.name -notmatch $Exclude } | Select-Object -First 1
    if (-not $a) { throw "$Repo $($rel.tag_name): no asset matching '$Pattern' (assets: $(($rel.assets.name) -join ', '))" }
    $sha = $null
    if ($a.PSObject.Properties['digest'] -and "$($a.digest)" -match '^sha256:([0-9a-fA-F]{64})$') { $sha = $Matches[1] }
    [pscustomobject]@{ Url = $a.browser_download_url; Name = $a.name; Version = $rel.tag_name; Sha256 = $sha }
}

$SevenZr = Join-Path $DlCache '7zr.exe'
$SevenZ  = $null    # full 7z.exe (handles NSIS/installer unpacking) - set once 7-Zip x64 is extracted
function Test-MZ([string]$File) {
    $fs = [IO.File]::OpenRead($File); try { $b = New-Object byte[] 2; [void]$fs.Read($b, 0, 2) } finally { $fs.Close() }
    $b[0] -eq 0x4D -and $b[1] -eq 0x5A   # 'MZ' = Windows executable
}
function Resolve-ToolUrl($t) {
    switch ($t.Src) {
        'scrape' { $u = Find-Link $t.Page $t.Pattern; if ($t.Rewrite) { $u = $u -replace $t.Rewrite[0], $t.Rewrite[1] }; return $u }
        'github' { return (Find-GitHubAsset $t.Repo $t.Pattern $(if ($t.Exclude) { $t.Exclude } else { '^\b$' })).Url }
        default  { return @($t.Url)[0] }
    }
}
function Test-Zip([string]$File) {
    $fs = [IO.File]::OpenRead($File); try { $b = New-Object byte[] 2; [void]$fs.Read($b, 0, 2) } finally { $fs.Close() }
    $b[0] -eq 0x50 -and $b[1] -eq 0x4B   # 'PK'
}
function Expand-Any([string]$File, [string]$Dest) {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    if (Test-Zip $File) {
        if ($File -notmatch '\.zip$') { $z = "$File.zip"; Copy-Item $File $z -Force; $File = $z }   # Expand-Archive insists on .zip
        Expand-Archive -Path $File -DestinationPath $Dest -Force
    } elseif ($File -match '\.gz$') {
        $out = Join-Path $Dest ([IO.Path]::GetFileNameWithoutExtension($File))
        $in = [IO.File]::OpenRead($File); $o = [IO.File]::Create($out)
        try { $gz = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress); $gz.CopyTo($o) }
        finally { if ($gz) { $gz.Dispose() }; $o.Dispose(); $in.Dispose() }
    } elseif ($File -match '\.7z$') {
        if (-not $AllowToolExecution) { throw 'Extract .7z inputs manually, or explicitly permit helper execution with -AllowToolExecution.' }
        $x = if ($SevenZ) { $SevenZ } else { $SevenZr }
        if (-not (Test-Path $x)) { throw "7-Zip not available to extract $File" }
        & $x x $File "-o$Dest" -y | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7-Zip failed on $File" }
    } else {
        Copy-Item $File $Dest -Force
    }
}

# Pick the x64 exe: prefer \x64\ folders and *64.exe, skip ARM64/x86/installers
function Select-Exe([string]$Dir, [string]$Filter) {
    Get-ChildItem $Dir -Recurse -Filter $Filter -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '(?i)\\(arm64|x86|win32|i386)\\' -and
                       $_.Name -notmatch '(?i)64a\.exe$|arm64|unins|^setup|^install|(setup|install|installer)\.exe$|vcredist|crash|update' } |
        Sort-Object @{ e = { if ($_.FullName -match '(?i)\\(x64|amd64|win64|bin64)\\' -or $_.Name -match '(?i)(64|x64)\.exe$') { 0 } else { 1 } } },
                    @{ e = { $_.Name.Length } }, @{ e = { $_.FullName.Length } } |
        Select-Object -First 1
}

# launch specs: 'Menu name|exe filter|args|gui|console'  -> writes launch.txt with resolved relative paths
function Write-LaunchFile([string]$ToolDir, [string[]]$Specs) {
    $lines = foreach ($s in $Specs) {
        $p = $s -split '\|'
        $exe = Select-Exe $ToolDir $p[1]
        if (-not $exe) { throw "no '$($p[1])' found in $ToolDir" }
        '{0}|{1}|{2}|{3}' -f $p[0], $exe.FullName.Substring($ToolDir.TrimEnd('\').Length + 1), $p[2], $p[3]
    }
    Set-Content -Path (Join-Path $ToolDir 'launch.txt') -Value $lines
}
#endregion

#region ---------- Tool catalog ----------
# Source types: direct (Url), scrape (Page + Pattern), github (Repo + Pattern [+ Exclude])
$Catalog = @(
    @{ Name='Sysinternals Suite'; Dir='Sysinternals\Suite'; Type='direct'; Url='https://download.sysinternals.com/files/SysinternalsSuite.zip'
       Post={ param($d) $s = Get-AuthenticodeSignature (Join-Path $d 'procexp64.exe'); if ($s.Status -ne 'Valid') { throw "signature: $($s.Status)" } } }
    @{ Name='Explorer++';       Dir='Utilities\ExplorerPlusPlus'; Type='github'; Repo='derceg/explorerplusplus'; Pattern='(?i)^explorerpp_x64\.zip$'
       Launch=@('Explorer++ (file manager)|Explorer++.exe||gui') }
    @{ Name='Notepad++';        Dir='Utilities\NotepadPlusPlus';  Type='github'; Repo='notepad-plus-plus/notepad-plus-plus'; Pattern='(?i)portable\.x64\.zip$'; Exclude='(?i)minimalist'
       Launch=@('Notepad++|notepad++.exe||gui') }
    @{ Name='SumatraPDF';       Dir='Utilities\SumatraPDF';       Type='scrape'; Page='https://www.sumatrapdfreader.org/download-free-pdf-viewer'; Pattern='(?i)SumatraPDF-[\d\.]+-64\.zip$'
       Launch=@('SumatraPDF|SumatraPDF*.exe||gui') }
    @{ Name='Everything';       Dir='Utilities\Everything';       Type='scrape'; Page='https://www.voidtools.com/downloads/'; Pattern='(?i)Everything-[\d\.]+\.x64\.zip$'
       Launch=@('Everything (file search)|Everything.exe||gui') }
    @{ Name='WinDirStat';       Dir='Storage\WinDirStat';         Type='github'; Repo='windirstat/windirstat'; Pattern='(?i)\.zip$'; Exclude='(?i)src|source|pdb|symbol|debug'
       Launch=@('WinDirStat|WinDirStat*.exe||gui') }
    @{ Name='CPU-Z';            Dir='Hardware\CPU-Z';             Type='scrape'; Page='https://www.cpuid.com/softwares/cpu-z.html'; Pattern='(?i)cpu-z_[\d\.]+-en\.zip$'
       Rewrite=@('(?i)^https?://www\.cpuid\.com/downloads/', 'https://download.cpuid.com/')
       Launch=@('CPU-Z|cpuz*.exe||gui') }
    @{ Name='HWiNFO64';         Dir='Hardware\HWiNFO';            Type='direct'; Url=@('https://sourceforge.net/projects/hwinfo/files/latest/download', 'https://sourceforge.net/projects/hwinfo/files/Windows_Portable/hwi_834.zip/download')
       Launch=@('HWiNFO64|HWiNFO64.exe||gui'); Note='Review current commercial-use terms; Personal Pro does not cover commercial use.' }
    @{ Name='CrystalDiskInfo';  Dir='Storage\CrystalDiskInfo';    Type='direct'; Url=@('https://sourceforge.net/projects/crystaldiskinfo/files/latest/download', 'https://crystalmark.info/redirect.php?product=CrystalDiskInfo')
       Launch=@('CrystalDiskInfo (SMART)|DiskInfo64.exe||gui') }
    @{ Name='smartmontools';    Dir='Storage\smartmontools';      Type='unpack'; Src='github'; Repo='smartmontools/smartmontools'; Pattern='(?i)setup\.exe$'
       Launch=@('smartctl (SMART console)|smartctl.exe|--scan|console') }
    @{ Name='Victoria';         Dir='Storage\Victoria';           Type='scrape'; Page='https://hdd.by/victoria/'; Pattern='(?i)Victoria\d+\.zip$'
       Rewrite=@('(?i)^.*?(https?://hdd\.by/Victoria/Victoria\d+\.zip)$', '$1')
       Launch=@('Victoria (HDD/SSD scan)|Victoria*.exe||gui') }
    @{ Name='DMDE';             Dir='Recovery\DMDE';              Type='scrape'; Page='https://dmde.com/download.html'; Pattern='(?i)dmde-[\d\-]+-win64-gui\.zip$'
       Launch=@('DMDE (disk editor/recovery)|dmde.exe||gui') }
    @{ Name='TestDisk/PhotoRec';Dir='Recovery\TestDisk';          Type='direct'; Url=@('https://www.cgsecurity.org/testdisk-7.2.win64.zip', 'https://www.cgsecurity.org/Download_and_donate.php/testdisk-7.2.win64.zip')
       Launch=@('TestDisk (partition recovery)|testdisk_win.exe||console', 'PhotoRec (file carving)|photorec_win.exe||console', 'QPhotoRec (GUI)|qphotorec_win.exe||gui') }
    @{ Name='PuTTY';            Dir='Network\PuTTY';              Type='multi'
       Urls=@('https://the.earth.li/~sgtatham/putty/latest/w64/putty.exe', 'https://the.earth.li/~sgtatham/putty/latest/w64/plink.exe', 'https://the.earth.li/~sgtatham/putty/latest/w64/psftp.exe')
       Launch=@('PuTTY|putty.exe||gui', 'PSFTP|psftp.exe||console') }
    @{ Name='iperf3';           Dir='Network\iperf3';             Type='github'; Repo='ar51an/iperf3-win-builds'; Pattern='(?i)^iperf-[\d.]+-win64\.zip$'
       Launch=@('iperf3 (console)|iperf3.exe|--version|console') }
    @{ Name='ClamAV';           Dir='Security\ClamAV';            Type='scrape'; Page='https://www.clamav.net/downloads'; Pattern='(?i)clamav-[\d\.]+\.win\.x64\.zip$'
       Launch=@('ClamAV (clamscan console)|clamscan.exe|--database=database --version|console')
       Note='Verify signature freshness before scanning; freshclam execution requires -AllowToolExecution.'
       Post={ param($d)
           $fc = Select-Exe $d 'freshclam.exe'; if (-not $fc) { throw 'freshclam.exe not found' }
           $db = Join-Path $fc.DirectoryName 'database'; New-Item -ItemType Directory -Force -Path $db | Out-Null
           $conf = Join-Path $fc.DirectoryName 'freshclam.conf'
            if ($AllowToolExecution) {
                Set-Content $conf -Encoding Ascii -Value "DatabaseDirectory `"$db`"`r`nDatabaseMirror database.clamav.net`r`n"
                try {
                    & $fc.FullName "--config-file=$conf"
                    if ($LASTEXITCODE -ne 0) { throw "freshclam failed ($LASTEXITCODE)" }
                    if (-not (Get-ChildItem $db -Include *.cvd, *.cld -Recurse)) { throw 'freshclam produced no signature databases' }
                } finally {
                    Set-Content $conf -Encoding Ascii -Value "DatabaseDirectory database`r`nDatabaseMirror database.clamav.net`r`n"
                }
            } else { Set-Content $conf -Encoding Ascii -Value "DatabaseDirectory database`r`nDatabaseMirror database.clamav.net`r`n" }
        } }
    @{ Name='Hayabusa';         Dir='Security\Hayabusa';          Type='github'; Repo='Yamato-Security/hayabusa'; Pattern='(?i)win.*x64.*\.zip$'; Exclude='(?i)live|lin|mac|aarch|arm'
       Launch=@('Hayabusa (EVTX hunting)|hayabusa*.exe||console') }
    @{ Name='Chainsaw';         Dir='Security\Chainsaw';          Type='github'; Repo='WithSecureOpenSource/chainsaw'; Pattern='(?i)x86_64-pc-windows.*\.zip$'
       Launch=@('Chainsaw (EVTX/Sigma)|chainsaw*.exe||console') }
    @{ Name='Velociraptor';     Dir='Forensics\Velociraptor';     Type='github'; Repo='Velocidex/velociraptor'; Pattern='(?i)windows-amd64\.exe(\.gz)?$'; Exclude='(?i)legacy|\.sig$'
       Launch=@('Velociraptor (triage collector)|velociraptor*.exe|--help|console') }
)

# Obtain and review each vendor's license and WinPE compatibility before adding manual tools.
$ManualOnly = 'Recuva, R-Studio, FTK Imager, KAPE, Emsisoft Emergency Kit, NTPWEdit, WinNTSetup, HFSExplorer'
#endregion

#region ---------- Download tools ----------
function Install-CatalogTool($t) {
    $dest = Join-Path $ToolsSrc $t.Dir
    if (-not $RefreshTools -and (Test-Path (Join-Path $dest '.version'))) {
        if ($t.Name -eq 'ClamAV' -and $AllowToolExecution) {
            try {
                & $t.Post $dest
                Write-LaunchFile $dest $t.Launch
                Add-Result $t.Name 'WARN' 'Cached binaries; signatures updated. Verify signature freshness before each scan.'
            } catch { Add-Result $t.Name 'FAILED' $_.Exception.Message }
        } elseif ($t.Note) { Add-Result $t.Name 'WARN' ('Cached; ' + $t.Note) }
        else { Add-Result $t.Name 'CACHED' (Get-Content (Join-Path $dest '.version') -First 1) }
        return
    }
    try {
        if (Test-Path $dest) { Remove-SafeBuildItem -Path $dest -AllowedRoot $ToolsSrc }
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        $ver = ''
        switch ($t.Type) {
            'direct' {
                # Url may be a list: first one that yields an actual archive wins (some sites put a landing page first)
                $f = Join-Path $DlCache ("{0}.dl" -f ($t.Name -replace '[^\w]', '_')); $ok = $false
                foreach ($u in @($t.Url)) {
                    try { Get-File $u $f; if (Test-Zip $f) { $ok = $true; $ver = $u; break } } catch { }
                }
                if (-not $ok) { throw "no archive from: $(@($t.Url) -join ' , ')" }
                Expand-Any $f $dest
            }
            'scrape' {
                $u = Find-Link $t.Page $t.Pattern
                if ($t.Rewrite) { $u = $u -replace $t.Rewrite[0], $t.Rewrite[1] }     # e.g. landing page -> real file host
                $f = Join-Path $DlCache (Split-Path ([Uri]$u).AbsolutePath -Leaf); Get-File $u $f
                if ($f -match '\.zip$' -and -not (Test-Zip $f)) { throw "got a web page instead of a zip from $u" }
                Expand-Any $f $dest; $ver = $u
            }
            'file' {
                # single portable exe
                $u = Resolve-ToolUrl $t; $f = Join-Path $dest $t.FileName; Get-File $u $f
                if (-not (Test-MZ $f)) { throw "got a web page instead of an exe from $u" }
                $ver = $u
            }
            'unpack' {
                # installer unpacked with full 7-Zip (NSIS/7z SFX) - nothing gets installed on this PC
                if (-not $AllowToolExecution -or -not $SevenZ) { throw 'Unpacking installer files requires -AllowToolExecution and full 7-Zip, or manual staging.' }
                $u = Resolve-ToolUrl $t; $f = Join-Path $DlCache (Split-Path ([Uri]$u).AbsolutePath -Leaf); Get-File $u $f
                & $SevenZ x $f "-o$dest" -y | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "7-Zip could not unpack $(Split-Path $f -Leaf)" }
                Get-ChildItem $dest -Directory -Filter '$PLUGINSDIR' -Recurse -ErrorAction SilentlyContinue |
                    ForEach-Object { Remove-SafeBuildItem -Path $_.FullName -AllowedRoot $dest }
                $ver = $u
            }
            'nupkg' {
                # Chocolatey community package that embeds the vendor's original zip
                $n = Join-Path $DlCache "$($t.Package).nupkg"
                Get-File "https://community.chocolatey.org/api/v2/package/$($t.Package)" $n
                $nx = Join-Path $DlCache $t.Package; if (Test-Path $nx) { Remove-SafeBuildItem -Path $nx -AllowedRoot $DlCache }
                Expand-Any $n $nx
                $inner = Get-ChildItem $nx -Recurse -Filter $t.Inner | Select-Object -First 1
                if (-not $inner) { throw "no $($t.Inner) inside $($t.Package).nupkg" }
                Expand-Any $inner.FullName $dest
                $nuspec = Get-ChildItem $nx -Filter *.nuspec | Select-Object -First 1
                $ver = if ($nuspec) { "choco $($t.Package) " + ([xml](Get-Content $nuspec.FullName)).package.metadata.version } else { "choco $($t.Package)" }
            }
            'multi'  { foreach ($u in $t.Urls) { Get-File $u (Join-Path $dest (Split-Path $u -Leaf)) }; $ver = 'latest' }
            'github' {
                $a = Find-GitHubAsset $t.Repo $t.Pattern $(if ($t.Exclude) { $t.Exclude } else { '^\b$' })
                $f = Join-Path $DlCache $a.Name; Get-File $a.Url $f
                if ($a.Sha256 -and (Get-FileHash $f -Algorithm SHA256).Hash -ne $a.Sha256.ToUpper()) { throw "SHA256 mismatch on $($a.Name)" }
                Expand-Any $f $dest; $ver = "$($a.Version) $($a.Name)"
            }
        }
        if ($t.Post)   { & $t.Post $dest }
        if ($t.Launch) { Write-LaunchFile $dest $t.Launch }
        Set-Content (Join-Path $dest '.version') $ver
        Add-Result $t.Name $(if ($t.Note) { 'WARN' } else { 'OK' }) $(if ($t.Note) { $t.Note } else { $ver })
    } catch {
        Add-Result $t.Name 'FAILED' $_.Exception.Message
        Remove-SafeBuildItem -Path $dest -AllowedRoot $ToolsSrc
    }
}

if (-not $SkipDownloads) {
    Write-Step "Downloading tools (cache: $DlCache)"
    # 7-Zip first - 7zr.exe is needed to unpack .7z packages
    if (-not $AllowToolExecution) {
        Add-Result '7-Zip' 'WARN' 'Automatic extraction disabled; manually stage 7-Zip or use -AllowToolExecution after reviewing the helper.'
    } else { try {
        $dest7 = Join-Path $ToolsSrc 'Utilities\7-Zip'
        # Full 7-Zip x64 (7zFM GUI + 7z.exe/7z.dll); the x64 installer is a 7z SFX that 7zr.exe can unpack
        if ($RefreshTools -or -not (Select-Exe $dest7 '7zFM.exe')) {
            Get-File (Find-Link 'https://www.7-zip.org/download.html' '(?i)/7zr\.exe$') $SevenZr
            $xu = Find-Link 'https://www.7-zip.org/download.html' '(?i)7z\d+-x64\.exe$'
            $xf = Join-Path $DlCache (Split-Path $xu -Leaf); Get-File $xu $xf
            if (Test-Path $dest7) { Remove-SafeBuildItem -Path $dest7 -AllowedRoot $ToolsSrc }
            New-Item -ItemType Directory -Force -Path $dest7 | Out-Null
            & $SevenZr x $xf "-o$dest7" -y | Out-Null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $dest7 '7z.exe'))) { throw "7zr could not unpack $(Split-Path $xf -Leaf)" }
            Get-ChildItem $dest7 -Directory -Filter '$*' -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-SafeBuildItem -Path $_.FullName -AllowedRoot $dest7 }
            Write-LaunchFile $dest7 @('7-Zip File Manager|7zFM.exe||gui', '7-Zip console|7z.exe||console')
            Set-Content (Join-Path $dest7 '.version') $xu
            Add-Result '7-Zip' 'OK' $xu
        } else { Add-Result '7-Zip' 'CACHED' '' }
        $SevenZ = Join-Path $dest7 '7z.exe'
    } catch { Add-Result '7-Zip' 'FAILED' $_.Exception.Message } }

    foreach ($t in $Catalog)  { Install-CatalogTool $t }


    # KAPE - Kroll gates the download behind a form, so it comes from the zip you save in Source\Drop
    $kz = Get-ChildItem (Join-Path $SourceDir 'Drop') -Filter 'kape*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    $kd = Join-Path $ToolsSrc 'Forensics\KAPE'
    if ($kz) {
        try {
            if ($RefreshTools -or -not (Test-Path (Join-Path $kd '.version')) -or ((Get-Content (Join-Path $kd '.version') -First 1) -ne $kz.Name)) {
                $kx = Join-Path $DlCache 'kape-extract'; if (Test-Path $kx) { Remove-SafeBuildItem -Path $kx -AllowedRoot $DlCache }
                Expand-Any $kz.FullName $kx
                $ke = Get-ChildItem $kx -Recurse -Filter 'kape.exe' | Select-Object -First 1
                if (-not $ke) { throw "no kape.exe inside $($kz.Name)" }
                if (Test-Path $kd) { Remove-SafeBuildItem -Path $kd -AllowedRoot $ToolsSrc }
                robocopy $ke.DirectoryName $kd /E /NFL /NDL /NJH /NJS | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
            }
            # Pull current Targets/Modules from the KapeFiles repo (kape.exe --sync)
            if ($AllowToolExecution) {
                Push-Location $kd
                try {
                    & (Join-Path $kd 'kape.exe') --sync | Out-Host
                    if ($LASTEXITCODE -ne 0) { throw "KAPE --sync failed ($LASTEXITCODE)" }
                } finally { Pop-Location }
            }
            Set-Content (Join-Path $kd 'launch.txt') @('gKAPE (GUI)|gkape.exe||gui', 'KAPE console|kape.exe||console')
            Set-Content (Join-Path $kd '.version') $kz.Name
            Add-Result 'KAPE' 'WARN' 'Review current Kroll terms; third-party paid use may be unavailable. --sync requires -AllowToolExecution.'
        } catch { Add-Result 'KAPE' 'FAILED' $_.Exception.Message }
    } else {
        Add-Result 'KAPE' 'MANUAL' "download from Kroll's form and save the zip as $SourceDir\Drop\kape.zip"
    }

    if (-not $SkipVentoyExtras) {
        Write-Step "Ventoy extras -> $VentoyDir"
        try {
            $mz = Join-Path $DlCache 'memtest86-usb.zip'
            Get-File 'https://www.memtest86.com/downloads/memtest86-usb.zip' $mz
            $mx = Join-Path $DlCache 'memtest86'; if (Test-Path $mx) { Remove-SafeBuildItem -Path $mx -AllowedRoot $DlCache }
            Expand-Archive $mz $mx -Force
            $img = Get-ChildItem $mx -Recurse -Filter *.img | Sort-Object Length -Descending | Select-Object -First 1
            if (-not $img) { throw 'no .img inside memtest86-usb.zip' }
            Copy-Item $img.FullName (Join-Path $VentoyDir 'MemTest86.img') -Force
            Add-Result 'MemTest86 (Ventoy)' 'OK' $img.Name
        } catch { Add-Result 'MemTest86 (Ventoy)' 'FAILED' $_.Exception.Message }
        function Test-Iso([string]$File) {   # ISO9660 primary volume descriptor "CD001" at offset 0x8001
            $fs = [IO.File]::OpenRead($File)
            try { if ($fs.Length -lt 0x8006) { return $false }; [void]$fs.Seek(0x8001, 'Begin'); $b = New-Object byte[] 5; [void]$fs.Read($b, 0, 5) } finally { $fs.Close() }
            [Text.Encoding]::ASCII.GetString($b) -eq 'CD001'
        }
        $isoJobs = @(
            @{ N = 'GParted Live'; F = 'GParted-Live-amd64.iso'
               Get = { Find-Link 'https://gparted.org/download.php' '(?i)gparted-live-[\d\.\-]+-amd64\.iso$' } }
            @{ N = 'Clonezilla Live'; F = 'Clonezilla-Live-amd64.iso'
               Get = {   # newest folder under clonezilla_live_stable -> clonezilla-live-<ver>-amd64.iso
                   $pg = Invoke-WebRequest 'https://sourceforge.net/projects/clonezilla/files/clonezilla_live_stable/' -UseBasicParsing -UserAgent $UA
                   $vers = [regex]::Matches($pg.Content, 'clonezilla_live_stable/(\d+\.\d+\.\d+-\d+)/') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
                   $v = $vers | Sort-Object { [version]($_ -replace '-', '.') } | Select-Object -Last 1
                   if (-not $v) { throw 'could not find a Clonezilla stable version folder' }
                   "https://downloads.sourceforge.net/clonezilla/clonezilla-live-$v-amd64.iso" } }
        )
        foreach ($j in $isoJobs) {
            try {
                $out = Join-Path $VentoyDir $j.F
                if ($RefreshTools -or -not (Test-Path $out) -or -not (Test-Iso $out)) {
                    $u = & $j.Get
                    Get-File $u $out
                    if (-not (Test-Iso $out)) { Remove-Item $out; throw "downloaded file is not an ISO: $u" }
                    Add-Result "$($j.N) (Ventoy)" 'OK' (Split-Path $u -Leaf)
                } else { Add-Result "$($j.N) (Ventoy)" 'CACHED' $j.F }
            } catch { Add-Result "$($j.N) (Ventoy)" 'FAILED' $_.Exception.Message }
        }
    }
}
#endregion

#region ---------- Build WinPE ----------
Write-Step "Cleaning previous build"
Assert-OwnedBuildDirectory $Root
$mountedHere = @(Get-WindowsImage -Mounted | Where-Object { $_.Path.TrimEnd('\') -eq $Mount.TrimEnd('\') })
if ($mountedHere) { Invoke-Adk "dism /Unmount-Image /MountDir:`"$Mount`" /Discard" }
if (Test-Path -LiteralPath $WorkDir) { Remove-SafeBuildItem -Path $WorkDir -AllowedRoot $Root }

Write-Step "copype amd64"
Invoke-Adk "call copype amd64 `"$WorkDir`""
Set-Content -LiteralPath (Join-Path $WorkDir '.pnwc-build-owned') -Value 'PNWC-WinPE-Builder v1' -Encoding Ascii
Write-Step "Mounting boot.wim"
Invoke-Adk "dism /Mount-Image /ImageFile:`"$Media\sources\boot.wim`" /Index:1 /MountDir:`"$Mount`""

$committed = $false
try {
    Write-Step "Adding WinPE optional components"
    $ocs = 'WinPE-WMI', 'WinPE-NetFx', 'WinPE-Scripting', 'WinPE-PowerShell', 'WinPE-StorageWMI', 'WinPE-DismCmdlets',
           'WinPE-SecureBootCmdlets', 'WinPE-SecureStartup', 'WinPE-PlatformId', 'WinPE-HTA', 'WinPE-EnhancedStorage',
           'WinPE-FMAPI', 'WinPE-Dot3Svc'
    foreach ($oc in $ocs) {
        $cab = Join-Path $OcDir "$oc.cab"; $lcab = Join-Path $OcDir "$Lang\$($oc)_$Lang.cab"
        if (-not (Test-Path $cab)) {
            if ($oc -in $RequiredOcs) { throw "Required WinPE component is missing: $oc" }
            Write-Warning "Optional component not found, skipping: $oc"; continue
        }
        Invoke-Adk "dism /Image:`"$Mount`" /Add-Package /PackagePath:`"$cab`""
        if (Test-Path $lcab) { Invoke-Adk "dism /Image:`"$Mount`" /Add-Package /PackagePath:`"$lcab`"" }
    }

    $drv = Join-Path $SourceDir 'Drivers'
    if (Get-ChildItem $drv -Recurse -Filter *.inf -ErrorAction SilentlyContinue | Select-Object -First 1) {
        Write-Step "Injecting drivers"; Invoke-Adk "dism /Image:`"$Mount`" /Add-Driver /Driver:`"$drv`" /Recurse"
    }
    $msus = Get-ChildItem (Join-Path $SourceDir 'Updates') -Filter *.msu -ErrorAction SilentlyContinue
    if ($msus) {
        Write-Step "Applying updates"
        foreach ($m in $msus) {
            $updatePath = Get-SafeLocalPath $m.FullName
            Invoke-Adk "dism /Image:`"$Mount`" /Add-Package /PackagePath:`"$updatePath`""
        }
        Invoke-Adk "dism /Image:`"$Mount`" /Cleanup-Image /StartComponentCleanup /ResetBase"
    }
    Invoke-Adk "dism /Image:`"$Mount`" /Set-ScratchSpace:$ScratchMB"

    Write-Step "Writing startnet.cmd + Launcher.ps1"
    $startnet = @'
@echo off
title PNWC-PE
wpeinit
powercfg /s 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
start "PNWC-PE Launcher" powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File X:\Windows\System32\Launcher.ps1
'@
    Set-Content -Path (Join-Path $Mount 'Windows\System32\startnet.cmd') -Value $startnet -Encoding Ascii

    $launcher = @'
# PNWC-PE Launcher - runs inside WinPE
$Host.UI.RawUI.WindowTitle = 'PNWC-PE Launcher'
$ToolsRoot = $null; $Tools = @(); $LogRoot = 'X:\PNWC-Logs'

function Find-Tools {
    $script:ToolsRoot = Get-PSDrive -PSProvider FileSystem |
        ForEach-Object { Join-Path $_.Root 'Tools' } |
        Where-Object { Test-Path (Join-Path $_ '.pnwc-pe') } | Select-Object -First 1
    $script:Tools = @()
    if ($script:ToolsRoot -and (Test-Path "$($script:ToolsRoot)\tools.csv")) { $script:Tools = Import-Csv "$($script:ToolsRoot)\tools.csv" }
    $script:LogRoot = 'X:\PNWC-Logs'
    if ($script:ToolsRoot) {
        $try = Join-Path (Split-Path $script:ToolsRoot -Parent) 'PNWC-Logs'
        try { New-Item -ItemType Directory -Force -Path $try -ErrorAction Stop | Out-Null
              [IO.File]::WriteAllText((Join-Path $try '.w'), 'x'); Remove-Item (Join-Path $try '.w'); $script:LogRoot = $try } catch {}
    }
    # A read-only ISO logs to RAM. Never choose a random evidence disk as a log destination.
    New-Item -ItemType Directory -Force -Path $script:LogRoot | Out-Null
}
Find-Tools

function Start-Tool($t) {
    if ([IO.Path]::IsPathRooted($t.Path) -or $t.Path -match '[:&|<>^%!"`\r\n*?]|(?:^|[\\/])\.{1,2}(?:[\\/]|$)') {
        Write-Warning 'Refusing an unsafe launcher path.'; return
    }
    $exe = Join-Path $ToolsRoot $t.Path
    if (Test-Path $exe -PathType Container) { Start-Process cmd.exe -ArgumentList "/k cd /d `"$exe`""; return }
    $dir = Split-Path $exe -Parent
    if ($t.Console -eq 'True') {
        Start-Process cmd.exe -ArgumentList "/k cd /d `"$dir`" && `"$exe`" $($t.Args)" -WorkingDirectory $dir
    } elseif ($t.Args) { Start-Process $exe -ArgumentList $t.Args -WorkingDirectory $dir }
      else             { Start-Process $exe -WorkingDirectory $dir }
}

function Get-HwReport {
    $sn = ((Get-CimInstance Win32_BIOS).SerialNumber -replace '[^\w-]', '_').Trim('_'); if (-not $sn) { $sn = 'noserial' }
    $f = Join-Path $LogRoot ("hw-{0}-{1:yyyyMMdd-HHmm}.txt" -f $sn, (Get-Date))
    & {
        '=== System ==='; Get-CimInstance Win32_ComputerSystem | Format-List Manufacturer, Model, TotalPhysicalMemory
        Get-CimInstance Win32_BIOS | Format-List SMBIOSBIOSVersion, SerialNumber, ReleaseDate
        '=== CPU ===';    Get-CimInstance Win32_Processor | Format-List Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed
        '=== RAM ===';    Get-CimInstance Win32_PhysicalMemory | Format-Table BankLabel, DeviceLocator, Manufacturer, PartNumber, @{n='GB';e={$_.Capacity/1GB}}, Speed -AutoSize
        '=== Disks ===';  Get-PhysicalDisk | Format-Table FriendlyName, MediaType, BusType, HealthStatus, OperationalStatus, @{n='GB';e={[math]::Round($_.Size/1GB)}} -AutoSize
        '=== Reliability ==='; Get-PhysicalDisk | Get-StorageReliabilityCounter | Format-Table DeviceId, Temperature, Wear, PowerOnHours, ReadErrorsTotal, WriteErrorsTotal -AutoSize
        '=== Secure Boot / TPM ==='; try { "SecureBoot: $(Confirm-SecureBootUEFI)" } catch { 'SecureBoot: n/a (legacy BIOS?)' }
        Get-CimInstance -Namespace root\cimv2\Security\MicrosoftTpm -ClassName Win32_Tpm -ErrorAction SilentlyContinue | Format-List SpecVersion, IsActivated_InitialValue, IsEnabled_InitialValue
        '=== BitLocker ==='; manage-bde -status
        '=== Video ==='; Get-CimInstance Win32_VideoController | Format-List Name, DriverVersion, PNPDeviceID
        '=== NICs ===';  Get-CimInstance Win32_NetworkAdapter -Filter 'PhysicalAdapter=True' | Format-Table Name, MACAddress, NetEnabled -AutoSize
    } *>&1 | Out-File $f -Width 200
    notepad.exe $f
}

while ($true) {
    Clear-Host
    Write-Host '  PNWC-PE  |  Pacific Northwest Computers' -ForegroundColor Cyan
    Write-Host ("  Tools: {0}   Logs: {1}" -f ($(if ($ToolsRoot) { $ToolsRoot } else { 'NOT FOUND - press T' })), $LogRoot) -ForegroundColor DarkGray
    $i = 0; $map = @{}
    foreach ($g in ($Tools | Group-Object Category | Sort-Object Name)) {
        Write-Host "`n  [$($g.Name)]" -ForegroundColor Yellow
        foreach ($t in ($g.Group | Sort-Object Name)) { $i++; $map["$i"] = $t; Write-Host ("   {0,3}) {1}" -f $i, $t.Name) }
    }
    Write-Host "`n  [Built-in]" -ForegroundColor Yellow
    Write-Host '     H) Hardware report -> log    N) Init network + ipconfig    C) Command prompt'
    Write-Host '     D) diskpart                  T) Re-scan for tools          R) Reboot    S) Shutdown'
    $sel = Read-Host "`n  Select"
    switch -Regex ($sel) {
        '^[Hh]$' { Get-HwReport }
        '^[Tt]$' { Find-Tools }
        '^[Nn]$' { wpeutil InitializeNetwork; ipconfig /all | Out-Host -Paging; Read-Host 'Enter to continue' | Out-Null }
        '^[Cc]$' { Start-Process cmd.exe -ArgumentList '/k cd /d X:\' }
        '^[Dd]$' { Start-Process cmd.exe -ArgumentList '/k diskpart' }
        '^[Rr]$' { wpeutil reboot }
        '^[Ss]$' { wpeutil shutdown }
        default  { if ($map.ContainsKey($sel)) { Start-Tool $map[$sel] } }
    }
}
'@
    Set-Content -Path (Join-Path $Mount 'Windows\System32\Launcher.ps1') -Value $launcher -Encoding UTF8

    Write-Step "Unmounting + committing"
    Invoke-Adk "dism /Unmount-Image /MountDir:`"$Mount`" /Commit"
    $committed = $true
} finally {
    if (-not $committed) { Write-Warning "Build failed - discarding mounted image"; Invoke-Adk "dism /Unmount-Image /MountDir:`"$Mount`" /Discard" }
}

Write-Step "Re-exporting boot.wim (max compression)"
$wim = Join-Path $Media 'sources\boot.wim'; $tmp = "$wim.tmp"
Invoke-Adk "dism /Export-Image /SourceImageFile:`"$wim`" /SourceIndex:1 /DestinationImageFile:`"$tmp`" /Compress:max"
Move-Item $tmp $wim -Force
#endregion

#region ---------- Tools -> media + tools.csv ----------
Write-Step "Copying tools to media + building tools.csv"
$MediaTools = Join-Path $Media 'Tools'
if (Get-ChildItem -LiteralPath $ToolsSrc -Recurse -Force |
    Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Select-Object -First 1) {
    throw 'Refusing tool staging containing reparse points.'
}
robocopy $ToolsSrc $MediaTools /E /NFL /NDL /NJH /NJS /XF '*.pdb' | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
Set-Content (Join-Path $MediaTools '.pnwc-pe') "Built $(Get-Date -Format s)"

$entries = New-Object System.Collections.Generic.List[object]
function Add-Entry($cat, $name, $path, $toolArgs, $console) {
    $path = Get-SafeToolRelativePath $path
    $entries.Add([pscustomobject]@{ Category = $cat; Name = $name; Path = $path; Args = $toolArgs; Console = [bool]$console })
}
$KnownCats = 'Hardware', 'Storage', 'Security', 'Forensics', 'Recovery', 'Network', 'Utilities', 'Sysinternals'
# Tool folders dropped straight into Tools\ (not under a category) -> menu category
$LooseMap = @{ 'emsisoft' = 'Security'; 'gpuz' = 'Hardware'; 'hfsexplorer' = 'Utilities'; 'ntpwedit' = 'Recovery'
               'smartmontools' = 'Storage'; 'victoria' = 'Storage'; 'winntsetup' = 'Recovery'
               'recuva' = 'Recovery'; 'rstudio' = 'Recovery'; 'ftkimager' = 'Forensics'; 'kape' = 'Forensics'; 'dmde' = 'Recovery' }
function Get-Norm([string]$s) { ($s -replace '[^A-Za-z0-9]', '').ToLower() }
$managed = @(Get-ChildItem $MediaTools -Directory | Where-Object { $_.Name -in $KnownCats } |
             ForEach-Object { Get-ChildItem $_.FullName -Directory } | ForEach-Object { Get-Norm $_.Name })

foreach ($cat in Get-ChildItem $MediaTools -Directory) {
    if ($cat.Name -notin $KnownCats) {
        # Loose tool folder, e.g. Tools\GPU-Z\GPU-Z.2.x.exe
        $n = Get-Norm $cat.Name
        if ($n -in $managed) { Write-Host "   Skipping loose '$($cat.Name)' - the build already maintains its own copy" -ForegroundColor DarkYellow; continue }
        $menuCat = if ($LooseMap.ContainsKey($n)) { $LooseMap[$n] } else { 'Other' }
        $lt = Join-Path $cat.FullName 'launch.txt'
        if (Test-Path $lt) {
            foreach ($line in (Get-Content $lt | Where-Object { $_ -and $_ -notmatch '^\s*#' })) {
                $p = $line -split '\|'; Add-Entry $menuCat $p[0] (Join-Path $cat.Name $p[1]) $p[2] ($p[3] -eq 'console')
            }
            continue
        }
        $exe = Select-Exe $cat.FullName '*.exe'
        if ($exe) { Add-Entry $menuCat $cat.Name $exe.FullName.Substring($MediaTools.TrimEnd('\').Length + 1) '' $false }
        else      { Write-Warning "No exe found in Tools\$($cat.Name) - add a launch.txt" }
        continue
    }
    if ($cat.Name -eq 'Sysinternals') {
        $curated = [ordered]@{ 'Process Explorer' = 'procexp64.exe'; 'Process Monitor' = 'Procmon64.exe'; 'Autoruns (incl. offline system)' = 'Autoruns64.exe'
                               'TCPView' = 'tcpview64.exe'; 'RAMMap' = 'RAMMap64.exe'; 'Disk2vhd' = 'disk2vhd64.exe'
                               'Coreinfo' = 'Coreinfo64.exe|console'; 'Sigcheck' = 'sigcheck64.exe|console' }
        foreach ($k in $curated.Keys) {
            $exe, $mode = $curated[$k] -split '\|'
            if (Test-Path (Join-Path $cat.FullName "Suite\$exe")) { Add-Entry 'Sysinternals' $k "Sysinternals\Suite\$exe" '' ($mode -eq 'console') }
        }
        Add-Entry 'Sysinternals' 'Sysinternals console (all tools)' 'Sysinternals\Suite' '' $true
        continue
    }
    foreach ($tool in Get-ChildItem $cat.FullName -Directory) {
        $lt = Join-Path $tool.FullName 'launch.txt'
        if (Test-Path $lt) {
            foreach ($line in (Get-Content $lt | Where-Object { $_ -and $_ -notmatch '^\s*#' })) {
                $p = $line -split '\|'
                Add-Entry $cat.Name $p[0] (Join-Path $cat.Name (Join-Path $tool.Name $p[1])) $p[2] ($p[3] -eq 'console')
            }
            continue
        }
        $exe = Select-Exe $tool.FullName '*.exe'     # manually dropped tools
        if ($exe) { Add-Entry $cat.Name $tool.Name $exe.FullName.Substring($MediaTools.TrimEnd('\').Length + 1) '' $false }
        else      { Write-Warning "No exe found for $($cat.Name)\$($tool.Name) - add a launch.txt" }
    }
}
$entries | Export-Csv (Join-Path $MediaTools 'tools.csv') -NoTypeInformation
Write-Host "   $($entries.Count) launcher entries" -ForegroundColor DarkGreen
#endregion

#region ---------- Media ----------
$bx = if ($BootEx) { ' /bootex' } else { '' }
Write-Step "Creating ISO: $IsoPath"
Invoke-Adk "call MakeWinPEMedia /ISO /F `"$WorkDir`" `"$IsoPath`"$bx"
Copy-Item $IsoPath (Join-Path $VentoyDir $IsoName) -Force
if ($UsbDrive) {
    $currentUsbVolume = Get-Volume -DriveLetter $UsbDrive[0]
    $currentUsbDisk = Get-Partition -DriveLetter $UsbDrive[0] | Get-Disk
    if ($currentUsbDisk.UniqueId -ne $UsbTargetUniqueId -or $currentUsbVolume.DriveType -ne 'Removable' -or
        $currentUsbDisk.BusType -ne 'USB' -or $currentUsbDisk.IsBoot -or $currentUsbDisk.IsSystem) {
        throw 'The USB target changed or is no longer safe to format. Re-run after checking its identity.'
    }
    Write-Step "Writing USB $UsbDrive (REFORMATS it)"
    Invoke-Adk "call MakeWinPEMedia /UFD /F `"$WorkDir`" $UsbDrive$bx"
}

if ($VhdPath) {
    # Bootable fixed VHD for IODD virtual-HDD mode:
    #   MBR | P1 2 GB FAT32 active (PE boot files - UEFI needs FAT, Windows won't format FAT32 > 32 GB)
    #       | P2 rest NTFS (Tools + PNWC-Logs, writable)
    # Rebuilds reuse the existing VHD: boot partition is rewritten, Tools mirrored, logs/other files on P2 kept.
    if ($VhdPath -notmatch '\.vhd$') { throw "-VhdPath must end in .vhd (IODD supports VHD, not VHDX)" }
    Write-Step "Bootable VHD: $VhdPath ($VhdSizeGB GB)"
    $new = -not (Test-Path $VhdPath)
    if ($new) {
        New-Item -ItemType Directory -Force -Path (Split-Path $VhdPath -Parent) | Out-Null
        Write-Host "   Creating fixed $VhdSizeGB GB VHD - this writes the full size and can take a while over USB" -ForegroundColor Yellow
        $dp = Join-Path $env:TEMP ('pnwcpe-vhd-' + [guid]::NewGuid().ToString('N') + '.txt')
        Set-Content $dp -Encoding Ascii -Value "create vdisk file=`"$VhdPath`" maximum=$($VhdSizeGB * 1024) type=fixed"
        try {
            & diskpart.exe /s $dp | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "diskpart failed ($LASTEXITCODE)" }
        } finally { Remove-Item -LiteralPath $dp }
        if (-not (Test-Path $VhdPath)) { throw "diskpart did not create $VhdPath" }
    }
    $img = Mount-DiskImage -ImagePath $VhdPath -PassThru
    try {
        $disks = @($img | Get-DiskImage | Get-Disk)
        if ($disks.Count -ne 1 -or $disks[0].IsBoot -or $disks[0].IsSystem) { throw 'The mounted VHD must resolve to exactly one non-system, non-boot disk.' }
        $disk = $disks[0]
        if ($new) {
            if ($disk.PartitionStyle -ne 'RAW') { throw 'A newly created VHD unexpectedly already contains partitions.' }
            Initialize-Disk -Number $disk.Number -PartitionStyle MBR
            $p1 = New-Partition -DiskNumber $disk.Number -Size 2GB -IsActive -AssignDriveLetter
            Format-Volume -Partition $p1 -FileSystem FAT32 -NewFileSystemLabel 'PNWCPE-BOOT' -Confirm:$false | Out-Null
            $p2 = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
            Format-Volume -Partition $p2 -FileSystem NTFS -NewFileSystemLabel 'PNWC-DATA' -Confirm:$false | Out-Null
        }
        $parts = @(Get-Partition -DiskNumber $disk.Number | Sort-Object PartitionNumber)
        if ($disk.PartitionStyle -ne 'MBR' -and -not $new) { throw 'An existing PNWC VHD must use MBR.' }
        if ($parts.Count -ne 2) { throw 'Refusing an unrecognized VHD: exactly two PNWC partitions are required.' }
        $bootVolume = $parts[0] | Get-Volume
        $dataVolume = $parts[1] | Get-Volume
        if ($bootVolume.FileSystem -ne 'FAT32' -or $bootVolume.FileSystemLabel -ne 'PNWCPE-BOOT' -or
            $dataVolume.FileSystem -ne 'NTFS' -or $dataVolume.FileSystemLabel -ne 'PNWC-DATA' -or
            $parts[0].Size -ne 2GB -or -not $parts[0].IsActive) {
            throw 'Refusing an unrecognized VHD partition layout or labels.'
        }
        foreach ($p in $parts) { if (-not $p.DriveLetter) { $p | Add-PartitionAccessPath -AssignDriveLetter } }
        $parts = @(Get-Partition -DiskNumber $disk.Number | Sort-Object PartitionNumber)
        $bootL = "$($parts[0].DriveLetter):"; $dataL = "$($parts[1].DriveLetter):"
        if ($bootL -eq ':' -or $dataL -eq ':') { throw 'could not get drive letters for the VHD partitions' }
        $vhdMarker = Join-Path ($dataL + '\') '.pnwc-vhd-owned'
        if (-not $new -and (-not (Test-Path -LiteralPath $vhdMarker -PathType Leaf) -or
            (Get-Content -LiteralPath $vhdMarker -Raw).Trim() -ne 'PNWC-WinPE-Builder v1')) {
            throw 'Refusing a VHD without the PNWC ownership marker. Create a new VHD path instead.'
        }
        $vhdTools = Join-Path ($dataL + '\') 'Tools'
        Assert-NoReparsePath $vhdTools
        if (Test-Path -LiteralPath $vhdTools) {
            if (Get-ChildItem -LiteralPath $vhdTools -Recurse -Force |
                Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Select-Object -First 1) {
                throw 'Refusing to mirror into a VHD Tools directory containing reparse points.'
            }
        }

        # Boot partition: PE only (Tools moved aside so they don't land on the small FAT32 partition)
        $aside = Join-Path $WorkDir 'Tools.aside'
        Move-Item $MediaTools $aside
        try   { Invoke-Adk "call MakeWinPEMedia /UFD /F `"$WorkDir`" $bootL$bx" }
        finally { Move-Item $aside $MediaTools }

        # Data partition: tools (mirrored) + logs folder
        robocopy $MediaTools $vhdTools /MIR /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy to VHD failed ($LASTEXITCODE)" }
        New-Item -ItemType Directory -Force -Path (Join-Path $dataL 'PNWC-Logs') | Out-Null
        Set-Content -LiteralPath $vhdMarker -Value 'PNWC-WinPE-Builder v1' -Encoding Ascii
        Write-Host "   VHD ready: boot $bootL (FAT32)  data $dataL (NTFS, Tools + PNWC-Logs)" -ForegroundColor Green
    } finally {
        Dismount-DiskImage -ImagePath $VhdPath | Out-Null
    }
}
#endregion

#region ---------- Summary ----------
Write-Step "Tool summary"
$Results | Format-Table -AutoSize | Out-Host
$Results | Export-Csv (Join-Path $LogDir "tools-$Stamp.csv") -NoTypeInformation
$failed = @($Results | Where-Object Status -eq 'FAILED')
if ($failed) { Write-Host "$($failed.Count) tool(s) FAILED - see table above / $LogDir\tools-$Stamp.csv" -ForegroundColor Red }
Write-Host "Not auto-downloadable (drop into $ToolsSrc\<Category>\<Tool>\ and rebuild): $ManualOnly" -ForegroundColor DarkYellow
Write-Host "`nDone. ISO: $IsoPath  ($([math]::Round((Get-Item $IsoPath).Length/1MB)) MB)" -ForegroundColor Green
Write-Host "Ventoy: copy everything in $VentoyDir to the Ventoy USB." -ForegroundColor Green
} finally { Stop-Transcript | Out-Null }
#endregion
