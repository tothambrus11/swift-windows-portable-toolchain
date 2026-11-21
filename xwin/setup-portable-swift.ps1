<#
.SYNOPSIS
  Sets up a portable, VS-free Swift toolchain for Windows in a user-local folder.

.DESCRIPTION
  1. Downloads the official swift.org Windows installer (a WiX/Burn bundle),
     unpacks its MSIs with `/layout` and extracts them with an administrative
     install (`msiexec /a`) - no real install, no registry, no VS dependency.
  2. Downloads xwin (https://github.com/Jake-Shadle/xwin) and uses it to fetch the
     MSVC CRT + Windows SDK headers/libs directly from Microsoft's package
     manifests, splatted in the /winsysroot layout.
  3. Writes <Target>\activate.ps1 and <Target>\activate.bat which set up PATH,
     SDKROOT and the vcvars-style variables (INCLUDE, LIB, VCToolsInstallDir,
     UniversalCRTSdkDir, UCRTVersion, ...) so that `swift build` works in a
     fresh shell without Visual Studio.

  By using xwin you accept the Microsoft Visual Studio license terms
  (https://go.microsoft.com/fwlink/?LinkId=2086102); pass -AcceptMicrosoftLicense.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File setup-portable-swift.ps1 -Target $env:LOCALAPPDATA\swift-portable -AcceptMicrosoftLicense
  . $env:LOCALAPPDATA\swift-portable\activate.ps1
  swift build
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Target,
  # e.g. 6.4.3; default = latest stable release from swift.org
  [string]$SwiftVersion = '',
  # x64 or arm64; default = host architecture
  [ValidateSet('', 'x64', 'arm64')][string]$Arch = '',
  [string]$XwinVersion = '0.10.0',
  # Optional pinning of MSVC CRT / Windows SDK versions (passed to xwin)
  [string]$CrtVersion = '',
  [string]$SdkVersion = '',
  [switch]$IncludeDebugLibs,
  [switch]$AcceptMicrosoftLicense,
  # Keep the downloaded installer / xwin cache (useful for CI caching)
  [switch]$KeepDownloads,
  # Extract SDKs for Android etc. as well (skipped by default)
  [switch]$AllSdks
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $AcceptMicrosoftLicense) {
  throw "xwin downloads Microsoft's CRT/SDK which are subject to the Visual Studio license (https://go.microsoft.com/fwlink/?LinkId=2086102). Re-run with -AcceptMicrosoftLicense."
}

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Get-DirSizeMB($path) {
  if (-not (Test-Path $path)) { return 0 }
  $s = (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
  if (-not $s) { $s = 0 }
  return [math]::Round($s / 1MB, 1)
}
function Invoke-Download($url, $out) {
  Write-Host "    GET $url"
  & curl.exe -L --fail --retry 3 --silent --show-error -o $out $url
  if ($LASTEXITCODE -ne 0) { throw "download failed: $url" }
}

if (-not $Arch) {
  $Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'x64' }
}
$xwinArch = if ($Arch -eq 'arm64') { 'aarch64' } else { 'x86_64' }

$Target = [System.IO.Path]::GetFullPath($Target)
$dl = Join-Path $Target 'downloads'
New-Item -ItemType Directory -Force -Path $Target, $dl | Out-Null
$stats = [ordered]@{ arch = $Arch }
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------- Swift
if (-not $SwiftVersion) {
  Write-Step 'Querying latest Swift release'
  $rel = Invoke-RestMethod -Uri 'https://www.swift.org/api/v1/install/releases.json'
  $SwiftVersion = $rel[-1].name
}
$stats.swift_version = $SwiftVersion
$suffix = if ($Arch -eq 'arm64') { '-arm64' } else { '' }
$swiftUrl = "https://download.swift.org/swift-$SwiftVersion-release/windows10$suffix/swift-$SwiftVersion-RELEASE/swift-$SwiftVersion-RELEASE-windows10$suffix.exe"
$installer = Join-Path $dl "swift-$SwiftVersion-$Arch.exe"

$t = [System.Diagnostics.Stopwatch]::StartNew()
if (-not (Test-Path $installer)) {
  Write-Step "Downloading Swift $SwiftVersion ($Arch)"
  Invoke-Download $swiftUrl $installer
}
$stats.swift_download_mb = [math]::Round((Get-Item $installer).Length / 1MB, 1)
$stats.swift_download_s = [math]::Round($t.Elapsed.TotalSeconds, 1)

Write-Step 'Unpacking installer bundle (/layout)'
$t.Restart()
$layout = Join-Path $dl 'layout'
if (Test-Path $layout) { Remove-Item -Recurse -Force $layout }
$p = Start-Process -FilePath $installer -ArgumentList @('/layout', "`"$layout`"", '/quiet', '/norestart', '/log', "`"$dl\layout.log`"") -Wait -PassThru
if ($p.ExitCode -ne 0) { Get-Content "$dl\layout.log" -Tail 40 -ErrorAction SilentlyContinue; throw "bundle /layout failed: $($p.ExitCode)" }
$msis = Get-ChildItem -Path $layout -Recurse -Filter *.msi
Write-Host ('    MSIs: ' + (($msis | ForEach-Object { "$($_.Name) ($([math]::Round($_.Length/1MB))MB)" }) -join ', '))

$swiftRoot = Join-Path $Target 'swift'
if (Test-Path $swiftRoot) { Remove-Item -Recurse -Force $swiftRoot }
New-Item -ItemType Directory -Force -Path $swiftRoot | Out-Null
foreach ($m in $msis) {
  $n = $m.Name.ToLowerInvariant()
  if (-not $AllSdks -and ($n -match 'android|wasm|wasi|static')) { Write-Host "    skip $($m.Name)"; continue }
  # Only the SDK/runtime MSIs for the requested arch (others are harmless but large)
  if ($n -match '^(sdk\.windows|rtl)\.(amd64|x64|x86|arm64|aarch64)') {
    $want = if ($Arch -eq 'arm64') { 'arm64|aarch64' } else { 'amd64|x64' }
    if ($n -notmatch $want) { Write-Host "    skip $($m.Name)"; continue }
  }
  Write-Host "    msiexec /a $($m.Name)"
  $p = Start-Process -FilePath msiexec.exe -ArgumentList @('/a', "`"$($m.FullName)`"", '/qn', "TARGETDIR=`"$swiftRoot`"", '/L*v', "`"$dl\$($m.BaseName).admin.log`"") -Wait -PassThru
  if ($p.ExitCode -ne 0) { Get-Content "$dl\$($m.BaseName).admin.log" -Tail 30; throw "msiexec /a $($m.Name) failed: $($p.ExitCode)" }
}
# admin installs leave copies of the .msi files in TARGETDIR - drop them
Get-ChildItem -Path $swiftRoot -Filter *.msi -Recurse | Remove-Item -Force
$stats.swift_extract_s = [math]::Round($t.Elapsed.TotalSeconds, 1)

$swiftExe = Get-ChildItem -Path $swiftRoot -Recurse -Filter swift.exe | Where-Object { $_.FullName -match '\\Toolchains\\[^\\]+\\usr\\bin\\swift\.exe$' } | Select-Object -First 1
if (-not $swiftExe) { throw "swift.exe not found under $swiftRoot" }
$toolchainBin = $swiftExe.DirectoryName
$baseDir = $swiftExe.Directory.Parent.Parent.Parent.Parent.FullName   # ...\Swift (contains Toolchains, Platforms, Runtimes)
$runtimeBin = Get-ChildItem -Path (Join-Path $baseDir 'Runtimes') -Directory | ForEach-Object { Join-Path $_.FullName 'usr\bin' } | Where-Object { Test-Path $_ } | Select-Object -First 1
$platform = Get-ChildItem -Path (Join-Path $baseDir 'Platforms') -Recurse -Directory -Filter 'Windows.platform' | Select-Object -First 1
$sdkRoot = Join-Path $platform.FullName 'Developer\SDKs\Windows.sdk'
foreach ($x in @($toolchainBin, $runtimeBin, $sdkRoot)) { if (-not $x -or -not (Test-Path $x)) { throw "expected path missing: $x" } }
$stats.swift_disk_mb = Get-DirSizeMB $swiftRoot

# ---------------------------------------------------------------- xwin
Write-Step "Fetching MSVC CRT + Windows SDK with xwin $XwinVersion"
$t.Restart()
$xwinDir = Join-Path $dl "xwin-$XwinVersion"
$xwinExe = Join-Path $xwinDir "xwin-$XwinVersion-x86_64-pc-windows-msvc\xwin.exe"
if (-not (Test-Path $xwinExe)) {
  New-Item -ItemType Directory -Force -Path $xwinDir | Out-Null
  $tgz = Join-Path $xwinDir 'xwin.tar.gz'
  Invoke-Download "https://github.com/Jake-Shadle/xwin/releases/download/$XwinVersion/xwin-$XwinVersion-x86_64-pc-windows-msvc.tar.gz" $tgz
  & tar.exe -xzf $tgz -C $xwinDir
  if ($LASTEXITCODE -ne 0) { throw 'failed to extract xwin' }
}
$sysroot = Join-Path $Target 'winsysroot'
$xcache = Join-Path $dl 'xwin-cache'
if (Test-Path $sysroot) { Remove-Item -Recurse -Force $sysroot }
$xargs = @('--accept-license', '--arch', $xwinArch, '--cache-dir', $xcache)
if ($CrtVersion) { $xargs += @('--crt-version', $CrtVersion) }
if ($SdkVersion) { $xargs += @('--sdk-version', $SdkVersion) }
$xargs += @('splat', '--output', $sysroot, '--use-winsysroot-style', '--preserve-ms-arch-notation', '--disable-symlinks')
if ($IncludeDebugLibs) { $xargs += '--include-debug-libs' }
Write-Host "    xwin $($xargs -join ' ')"
& $xwinExe @xargs
if ($LASTEXITCODE -ne 0) { throw "xwin failed: $LASTEXITCODE" }
$stats.xwin_s = [math]::Round($t.Elapsed.TotalSeconds, 1)
$stats.xwin_download_mb = Get-DirSizeMB (Join-Path $xcache 'dl')
$stats.sysroot_disk_mb = Get-DirSizeMB $sysroot

$vcRoot = Get-ChildItem -Path (Join-Path $sysroot 'VC\Tools\MSVC') -Directory | Sort-Object Name | Select-Object -Last 1
$kits = Join-Path $sysroot 'Windows Kits\10'
$sdkInc = Get-ChildItem -Path (Join-Path $kits 'Include') -Directory | Sort-Object Name | Select-Object -Last 1
$vcVer = $vcRoot.Name; $sdkVer = $sdkInc.Name
$stats.msvc_version = $vcVer; $stats.winsdk_version = $sdkVer
$msArch = $Arch  # x64 / arm64 thanks to --preserve-ms-arch-notation
$include = @(
  "$($vcRoot.FullName)\include",
  "$kits\Include\$sdkVer\ucrt", "$kits\Include\$sdkVer\shared", "$kits\Include\$sdkVer\um",
  "$kits\Include\$sdkVer\winrt", "$kits\Include\$sdkVer\cppwinrt"
) | Where-Object { Test-Path $_ }
$lib = @(
  "$($vcRoot.FullName)\lib\$msArch",
  "$kits\Lib\$sdkVer\ucrt\$msArch", "$kits\Lib\$sdkVer\um\$msArch"
)
foreach ($l in $lib) { if (-not (Test-Path $l)) { Get-ChildItem -Recurse -Directory $sysroot -Depth 6 | Select-Object -First 80 FullName | Out-Host; throw "lib dir missing: $l" } }

if (-not $KeepDownloads) {
  Write-Step 'Removing downloads'
  Remove-Item -Recurse -Force $dl -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- activation scripts
$envVars = [ordered]@{
  SDKROOT             = "$sdkRoot\"
  VCToolsInstallDir   = "$($vcRoot.FullName)\"
  VCToolsVersion      = $vcVer
  VCINSTALLDIR        = "$sysroot\VC\"
  UniversalCRTSdkDir  = "$kits\"
  UCRTVersion         = $sdkVer
  WindowsSdkDir       = "$kits\"
  WindowsSDKVersion   = "$sdkVer\"
  WindowsSDKLibVersion= "$sdkVer\"
  INCLUDE             = ($include -join ';')
  LIB                 = ($lib -join ';')
  SWIFT_PORTABLE_ROOT = $Target
}
$pathPrefix = "$toolchainBin;$runtimeBin"

$ps = @()
$ps += '# Generated by setup-portable-swift.ps1 - dot-source this file: . .\activate.ps1'
foreach ($k in $envVars.Keys) { $ps += ('$env:{0} = ''{1}''' -f $k, ($envVars[$k] -replace "'", "''")) }
$ps += ('$env:Path = ''{0};'' + $env:Path' -f $pathPrefix)
$ps += 'Write-Host "Portable Swift activated: $((Get-Command swift).Source)"'
Set-Content -Path (Join-Path $Target 'activate.ps1') -Value $ps -Encoding UTF8

$bat = @('@echo off', 'rem Generated by setup-portable-swift.ps1')
foreach ($k in $envVars.Keys) { $bat += ('set "{0}={1}"' -f $k, $envVars[$k]) }
$bat += ('set "Path={0};%Path%"' -f $pathPrefix)
Set-Content -Path (Join-Path $Target 'activate.bat') -Value $bat -Encoding ASCII

$stats.total_s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
$stats.total_disk_mb = Get-DirSizeMB $Target
$stats | ConvertTo-Json | Set-Content -Path (Join-Path $Target 'setup-stats.json') -Encoding UTF8
Write-Step 'Done'
$stats | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Activate with:  . '$Target\activate.ps1'   (or call `"$Target\activate.bat`" from cmd)"
