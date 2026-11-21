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
  # Where the Windows SDK half comes from: 'nuget' (official Microsoft.Windows.SDK.CPP packages, complete)
  # or 'xwin' (VS manifest via xwin; its pruning drops headers such as ucrt\corecrt_math.h)
  [ValidateSet('nuget', 'xwin')][string]$SdkSource = 'nuget',
  [string]$NugetSdkVersion = '',
  # Don't copy Swift's ucrt/winsdk/vcruntime modulemaps into the sysroot (then you need the -windows-sdk-root... flags)
  [switch]$NoModulemapCopy,
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

function Copy-StreamRange([System.IO.FileStream]$src, [long]$offset, [long]$length, [string]$dest) {
  $src.Position = $offset
  $out = [System.IO.File]::Create($dest)
  try {
    $buf = New-Object byte[] (4MB)
    $left = $length
    while ($left -gt 0) {
      $n = $src.Read($buf, 0, [int][math]::Min($buf.Length, $left))
      if ($n -le 0) { throw 'unexpected EOF' }
      $out.Write($buf, 0, $n); $left -= $n
    }
  } finally { $out.Dispose() }
}

# Extracts the payloads of a WiX (v3-v6) Burn bundle without running it.
# Layout: [engine stub (size = .wixburn header dwStubSize)][UX container CAB][attached container CAB(s)][signature]
function Expand-BurnBundle([string]$Bundle, [string]$OutDir) {
  $fs = [System.IO.File]::OpenRead($Bundle)
  try {
    $br = New-Object System.IO.BinaryReader($fs)
    $fs.Position = 0x3C; $pe = $br.ReadInt32()
    $fs.Position = $pe + 6; $nsec = $br.ReadUInt16()
    $fs.Position = $pe + 20; $optSize = $br.ReadUInt16()
    $secTable = $pe + 24 + $optSize
    $burnRaw = $null
    for ($i = 0; $i -lt $nsec; $i++) {
      $fs.Position = $secTable + 40 * $i
      $name = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(8)).TrimEnd([char]0)
      if ($name -eq '.wixburn') { $fs.Position = $secTable + 40 * $i + 20; $burnRaw = $br.ReadUInt32() }
    }
    if ($null -eq $burnRaw) { throw "$Bundle is not a WiX Burn bundle (.wixburn section missing)" }
    $fs.Position = $burnRaw
    $magic = $br.ReadUInt32(); if ($magic -ne 0x00f14300) { throw ('bad burn magic 0x{0:x}' -f $magic) }
    $fs.Position = $burnRaw + 24; $stub = [long]$br.ReadUInt32()
    $fs.Position = $burnRaw + 44; $count = $br.ReadUInt32()
    $sizes = @(); for ($k = 0; $k -lt $count; $k++) { $sizes += [long]$br.ReadUInt32() }
    # Containers follow the stub; the original Authenticode blob (+ padding) may sit between
    # the UX container and the attached ones, so search for each CAB header of the expected size.
    $off = $stub; $cabs = @()
    for ($idx = 0; $idx -lt $count; $idx++) {
      $fs.Position = $off
      $win = $br.ReadBytes(1MB)
      $found = -1
      for ($j = 0; $j -le $win.Length - 12; $j++) {
        if ($win[$j] -eq 0x4D -and $win[$j+1] -eq 0x53 -and $win[$j+2] -eq 0x43 -and $win[$j+3] -eq 0x46 -and
            [BitConverter]::ToUInt32($win, $j + 8) -eq $sizes[$idx]) { $found = $j; break }
      }
      if ($found -lt 0) { throw "CAB for container $idx (size $($sizes[$idx])) not found near offset $off" }
      $off += $found
      $cab = Join-Path $OutDir ("container{0}.cab" -f $idx)
      Write-Host ("    container {0}: offset {1}, {2:n1} MB" -f $idx, $off, ($sizes[$idx] / 1MB))
      Copy-StreamRange $fs $off $sizes[$idx] $cab
      $cabs += $cab; $off += $sizes[$idx]
    }
  } finally { $fs.Dispose() }
  if ($cabs.Count -lt 2) { throw "expected UX + attached containers, found $($cabs.Count)" }
  $skip = @{}
  $i = 0
  foreach ($cab in $cabs) {
    $d = Join-Path $OutDir ("c$i"); New-Item -ItemType Directory -Force -Path $d | Out-Null
    if ($skip[$i]) { Write-Host "    skipping container $i ($($skip[$i]))"; Remove-Item $cab -Force; $i++; continue }
    # expand.exe (built into Windows) handles LZX reliably; libarchive's tar fails on the big LZX CABs
    & expand.exe -F:* $cab $d | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "failed to extract $cab" }
    Remove-Item $cab -Force
    if ($i -eq 0) {
      # The non-asserts toolchain is an alternative copy of the toolchain - don't unpack it
      [xml]$m0 = Get-Content -Raw -Path (Join-Path $d '0')
      foreach ($c in $m0.GetElementsByTagName('Container')) {
        if ($c.GetAttribute('Id') -match 'NoAsserts' -and -not $AllSdks) { $skip[[int]$c.GetAttribute('AttachedIndex')] = $c.GetAttribute('Id') }
      }
    }
    $i++
  }
  # UX container file "0" is the burn manifest; map payload SourcePath (a0, a1, ...) -> FilePath
  [xml]$manifest = Get-Content -Raw -Path (Join-Path $OutDir 'c0\0')
  foreach ($pl in $manifest.GetElementsByTagName('Payload')) {
    $srcPath = $pl.GetAttribute('SourcePath'); $filePath = $pl.GetAttribute('FilePath')
    if (-not $srcPath -or -not $filePath) { continue }
    for ($c = 1; $c -lt $cabs.Count; $c++) {
      $f = Join-Path $OutDir "c$c\$srcPath"
      if (Test-Path $f) {
        $dest = Join-Path $OutDir "payloads\$filePath"
        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
        Move-Item -Force $f $dest
      }
    }
  }
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

Write-Step 'Unpacking installer bundle (carving WiX Burn containers)'
$t.Restart()
$layout = Join-Path $dl 'layout'
if (Test-Path $layout) { Remove-Item -Recurse -Force $layout }
New-Item -ItemType Directory -Force -Path $layout | Out-Null
# Note: `installer.exe /layout <dir>` only copies the bundle exe for this bundle, so we read
# the Burn containers (plain CAB files appended after the engine stub) ourselves.
Expand-BurnBundle -Bundle $installer -OutDir $layout
$msis = Get-ChildItem -Path $layout -Recurse -Filter *.msi -ErrorAction SilentlyContinue
if (-not $msis) {
  Get-ChildItem -Path $layout -Recurse | Select-Object FullName, Length | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
  throw 'no MSIs found in bundle'
}
Write-Host ('    MSIs: ' + (($msis | ForEach-Object { "$($_.Name) ($([math]::Round($_.Length/1MB))MB)" }) -join ', '))

$swiftRoot = Join-Path $Target 'Swift'   # will contain Toolchains\, Platforms\, Runtimes\ like %LOCALAPPDATA%\Programs\Swift
$stage = Join-Path $Target '_'   # keep this short: admin images hit MAX_PATH (error 1603) otherwise
foreach ($d in @($swiftRoot, $stage)) { if (Test-Path $d) { Remove-Item -Recurse -Force $d } }
New-Item -ItemType Directory -Force -Path $swiftRoot, $stage | Out-Null
foreach ($m in $msis) {
  $n = $m.Name.ToLowerInvariant()
  if (-not $AllSdks -and ($n -match 'android|wasm|wasi|static|noasserts')) { Write-Host "    skip $($m.Name)"; continue }
  # Only the runtime MSI for the requested arch
  if ($n -match '^rtl\.(amd64|x64|x86|arm64|aarch64)') {
    $want = if ($Arch -eq 'arm64') { 'arm64|aarch64' } else { 'amd64|x64' }
    if ($n -notmatch $want) { Write-Host "    skip $($m.Name)"; continue }
  }
  $msiIdx = 1 + [int]$msiIdx
  $s = Join-Path $stage "$msiIdx"
  Write-Host "    msiexec /a $($m.Name)"
  $p = Start-Process -FilePath msiexec.exe -ArgumentList @('/a', "`"$($m.FullName)`"", '/qn', "TARGETDIR=`"$s`"", '/L*v', "`"$dl\$($m.BaseName).admin.log`"") -Wait -PassThru
  if ($p.ExitCode -ne 0) {
    Select-String -Path "$dl\$($m.BaseName).admin.log" -Pattern 'Return value 3|Error 1|error 1|Note: 1: 1[0-9]{3} 2:' -Context 3,1 | Select-Object -First 8 | Out-String -Width 400 | Write-Host
    throw "msiexec /a $($m.Name) failed: $($p.ExitCode)"
  }
  Get-ChildItem -Path $s -Filter *.msi | Remove-Item -Force   # admin image keeps a copy of the .msi at its root
  # Per-user MSIs land under <TARGETDIR>\LocalApp\Programs\Swift; merge that into $swiftRoot
  $perUser = Join-Path $s 'LocalApp\Programs\Swift'
  if (Test-Path $perUser) {
    & robocopy.exe $perUser $swiftRoot /E /MOVE /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $($m.Name)" }
    Remove-Item -Recurse -Force (Join-Path $s 'LocalApp') -ErrorAction SilentlyContinue
  }
  # The runtime MSI's files land directly in TARGETDIR: give them the standard Runtimes\<ver>\usr\bin home
  $left = @(Get-ChildItem -Path $s -Force)
  if ($left.Count -gt 0) {
    if ($n -match '^rtl\.') {
      $rt = Join-Path $swiftRoot "Runtimes\$SwiftVersion\usr\bin"
      New-Item -ItemType Directory -Force -Path $rt | Out-Null
      & robocopy.exe $s $rt /E /MOVE /NFL /NDL /NJH /NJS /NP | Out-Null
    } else {
      Write-Host "      note: $($m.Name) also produced: $(($left | ForEach-Object Name) -join ', ') (kept under $s)"
    }
  }
}
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
$stats.swift_extract_s = [math]::Round($t.Elapsed.TotalSeconds, 1)

$swiftExe = Get-ChildItem -Path (Join-Path $swiftRoot 'Toolchains') -Recurse -Filter swift.exe | Where-Object { $_.FullName -match '\\Toolchains\\[^\\]+\\usr\\bin\\swift\.exe$' } | Select-Object -First 1
if (-not $swiftExe) { throw "swift.exe not found under $swiftRoot" }
$toolchainBin = $swiftExe.DirectoryName
$runtimeBin = Join-Path $swiftRoot "Runtimes\$SwiftVersion\usr\bin"
$platform = Get-ChildItem -Path (Join-Path $swiftRoot 'Platforms') -Recurse -Directory -Filter 'Windows.platform' | Select-Object -First 1
if (-not (Test-Path (Join-Path $runtimeBin 'swiftCore.dll')) -or -not $platform) {
  Get-ChildItem -Path $Target -Recurse -Directory -Depth 6 | Select-Object -ExpandProperty FullName | Write-Host
  throw "runtime ($runtimeBin) or Windows.platform ($platform) not found"
}
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
$kits = Join-Path $sysroot 'Windows Kits\10'
if (Test-Path (Join-Path $kits 'Include')) {
  $x = Get-ChildItem (Join-Path $kits 'Include') -Directory | Select-Object -First 1
  $stats.xwin_has_corecrt_math_h = Test-Path (Join-Path $x.FullName 'ucrt\corecrt_math.h')
}

if ($SdkSource -eq 'nuget') {
  # Replace xwin's (pruned) Windows SDK with the complete one from Microsoft's official NuGet packages
  Write-Step 'Fetching Windows SDK from NuGet (Microsoft.Windows.SDK.CPP + .<arch>)'
  $t.Restart()
  if (-not $NugetSdkVersion) {
    $vers = (Invoke-RestMethod 'https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.cpp/index.json').versions | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
    if ($SdkVersion) { $vers = $vers | Where-Object { $_.StartsWith($SdkVersion) } }
    $NugetSdkVersion = $vers[-1]
  }
  Remove-Item -Recurse -Force $kits -ErrorAction SilentlyContinue
  $ng = Join-Path $dl 'nuget'; New-Item -ItemType Directory -Force -Path $ng | Out-Null
  $dlBytes = 0
  foreach ($pkg in @('microsoft.windows.sdk.cpp', "microsoft.windows.sdk.cpp.$Arch")) {
    $f = Join-Path $ng "$pkg.zip"
    Invoke-Download "https://api.nuget.org/v3-flatcontainer/$pkg/$NugetSdkVersion/$pkg.$NugetSdkVersion.nupkg" $f
    $dlBytes += (Get-Item $f).Length
    $x = Join-Path $ng $pkg; New-Item -ItemType Directory -Force -Path $x | Out-Null
    if ($pkg -eq 'microsoft.windows.sdk.cpp') { & tar.exe -xf $f -C $x 'c/Include' } else { & tar.exe -xf $f -C $x 'c/ucrt' 'c/um' }
    if ($LASTEXITCODE -ne 0) { throw "failed to extract $pkg" }
  }
  $incVer = (Get-ChildItem (Join-Path $ng 'microsoft.windows.sdk.cpp\c\Include') -Directory | Select-Object -First 1).Name
  New-Item -ItemType Directory -Force -Path "$kits\Include", "$kits\Lib\$incVer" | Out-Null
  Move-Item (Join-Path $ng "microsoft.windows.sdk.cpp\c\Include\$incVer") "$kits\Include\$incVer"
  Move-Item (Join-Path $ng "microsoft.windows.sdk.cpp.$Arch\c\ucrt") "$kits\Lib\$incVer\ucrt"
  Move-Item (Join-Path $ng "microsoft.windows.sdk.cpp.$Arch\c\um") "$kits\Lib\$incVer\um"
  $stats.nuget_sdk_version = $NugetSdkVersion
  $stats.nuget_download_mb = [math]::Round($dlBytes / 1MB, 1)
  $stats.nuget_s = [math]::Round($t.Elapsed.TotalSeconds, 1)
}
$stats.sysroot_disk_mb = Get-DirSizeMB $sysroot

$vcRoot = Get-ChildItem -Path (Join-Path $sysroot 'VC\Tools\MSVC') -Directory | Sort-Object Name | Select-Object -Last 1
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

# ---------------------------------------------------------------- modulemaps
# The Swift frontend only VFS-overlays its ucrt/winsdk/vcruntime modulemaps onto the SDK when it can
# *locate* the SDK: -windows-sdk-root/-visualc-tools-root flags or the HKLM registry (admin). SwiftPM does
# not forward -Xswiftc flags to every job (e.g. the generated test runner), so instead place the
# modulemaps physically next to the headers (what pre-5.9 Swift installers did) - then clang finds
# the `ucrt`, `WinSDK`, `vcruntime` modules through the INCLUDE search path alone.
if (-not $NoModulemapCopy) {
  $share = Join-Path $sdkRoot 'usr\share'
  $inc = "$kits\Include\$sdkVer"
  foreach ($f in Get-ChildItem $share -File | Where-Object { $_.Extension -in '.modulemap', '.apinotes' }) {
    $n = $f.Name.ToLowerInvariant()
    $dest = switch -regex ($n) {
      '^ucrt\.modulemap$'          { "$inc\ucrt\module.modulemap" }
      '^ucrt\.apinotes$'           { "$inc\ucrt\ucrt.apinotes" }
      '^vcruntime\.modulemap$'     { "$($vcRoot.FullName)\include\module.modulemap" }
      '^vcruntime\.apinotes$'      { "$($vcRoot.FullName)\include\vcruntime.apinotes" }
      '^winsdk\.modulemap$'        { "$inc\um\module.modulemap" }
      '^winsdk_(\w+)\.modulemap$'  { "$inc\$($Matches[1])\module.modulemap" }
      '^winsdk\.apinotes$'         { "$inc\um\WinSDK.apinotes" }
      default                      { $null }
    }
    if ($dest -and (Test-Path (Split-Path $dest))) { Copy-Item $f.FullName $dest -Force; Write-Host "    $($f.Name) -> $dest" }
    else { Write-Host "    (not placed) $($f.Name)" }
  }
}

# ---------------------------------------------------------------- clang default config
# swiftc links through clang.exe, which defaults to MSVC link.exe (absent without VS), and SwiftPM's
# build system does not pass INCLUDE/LIB to every clang job. clang reads <clang-dir>\clang.cfg by
# default, so make lld the default linker and point clang at the /winsysroot-style sysroot.
foreach ($cfg in 'clang.cfg', 'clang++.cfg') {
  Set-Content -Path (Join-Path $toolchainBin $cfg) -Encoding ASCII -Value @(
    '# added by setup-portable-swift.ps1 (no Visual Studio): use lld and the portable MSVC/WinSDK sysroot',
    '-fuse-ld=lld',
    "-Xmicrosoft-windows-sys-root `"$sysroot`"")
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
