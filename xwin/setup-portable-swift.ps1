<#
.SYNOPSIS
  Sets up a portable, VS-free Swift toolchain for Windows in a user-local folder.

.DESCRIPTION
  1. Downloads the official swift.org Windows installer (a WiX/Burn bundle), carves
     its CAB containers out (no installer run) and extracts only the needed MSIs with
     an administrative install (`msiexec /a`) - no registry, no VS dependency.
  2. Fetches the MSVC CRT (headers + DLL import libs only, ~30 MB) straight from the
     Visual Studio channel manifest - pure PowerShell, no xwin/Rust binary needed
     (optional: -CrtSource xwin).
  3. Fetches the Windows SDK (headers + UCRT/UM import libs) from Microsoft's official
     NuGet packages Microsoft.Windows.SDK.CPP[.<arch>].
  4. Copies Swift's ucrt/winsdk/vcruntime modulemaps next to the headers and writes
     <toolchain>\usr\bin\clang.cfg (-fuse-ld=lld, -Xmicrosoft-windows-sys-root) so that
     swiftc, SwiftPM (incl. swift test) and clang need no extra flags.
  5. Writes <Target>\activate.ps1 / activate.bat (PATH, SDKROOT, vcvars-style vars).

  The MSVC CRT and Windows SDK are Microsoft software under their license terms; the
  script prints the license URLs and refuses to download them without -AcceptLicense.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File setup-portable-swift.ps1 -Target $env:LOCALAPPDATA\swift-portable -AcceptLicense
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
  # Installer components (MSI base names). Minimal set that builds/runs/tests: bld (compiler, clang, lld),
  # cli (swift-driver, SwiftPM), rtl (runtime DLLs), windows (Windows platform SDK, XCTest, swift-testing).
  [string[]]$Components = @('bld', 'cli', 'rtl', 'windows'),
  # Also install lldb (dbg + python), sourcekit-lsp (ide) and res
  [switch]$Full,
  # Use the no-asserts toolchain build instead of the (default, installer-default) asserts build
  [switch]$NoAsserts,
  # Keep the Windows SDK content for the other architectures (x86/arm64/x64) and the redistributable .msm files
  [switch]$KeepOtherArchs,
  # MSVC CRT source: 'vsmanifest' (default, pure PowerShell) or 'xwin'
  [ValidateSet('vsmanifest', 'xwin')][string]$CrtSource = 'vsmanifest',
  [string]$VsChannelUrl = 'https://aka.ms/vs/17/release/channel',
  # e.g. 14.44.17.14 (VS package version); default = newest in the channel manifest
  [string]$CrtVersion = '',
  # Also fetch the static CRT (libcmt/libcpmt/libvcruntime, +50 MB) - not needed by Swift (uses /MD)
  [switch]$IncludeStaticCrt,
  # Windows SDK NuGet version (e.g. 10.0.28000.2957) or prefix filter (-SdkVersion 10.0.26100)
  [string]$NugetSdkVersion = '',
  [string]$SdkVersion = '',
  [string]$XwinVersion = '0.10.0',
  [switch]$IncludeDebugLibs,
  # Don't copy Swift's ucrt/winsdk/vcruntime modulemaps into the sysroot (then you need the -windows-sdk-root... flags)
  [switch]$NoModulemapCopy,
  [Alias('AcceptMicrosoftLicense')][switch]$AcceptLicense,
  # Keep the downloaded installer / caches (useful for CI caching)
  [switch]$KeepDownloads,
  # Extract SDKs for Android etc. as well (skipped by default)
  [switch]$AllSdks
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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
function Expand-BurnBundle([string]$Bundle, [string]$OutDir, [string]$SkipContainer = 'NoAsserts') {
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
        if ($c.GetAttribute('Id') -match $SkipContainer) { $skip[[int]$c.GetAttribute('AttachedIndex')] = $c.GetAttribute('Id') }
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
$vsArch = if ($Arch -eq 'arm64') { 'ARM64' } else { 'x64' }
if ($Full) { $Components = @($Components) + @('dbg', 'python', 'ide', 'res') | Select-Object -Unique }

$Target = [System.IO.Path]::GetFullPath($Target)
$dl = Join-Path $Target 'downloads'
New-Item -ItemType Directory -Force -Path $Target, $dl | Out-Null
$stats = [ordered]@{ arch = $Arch; components = ($Components -join ',') }
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------- versions + licenses (before any big download)
if (-not $SwiftVersion) {
  $rel = Invoke-RestMethod -Uri 'https://www.swift.org/api/v1/install/releases.json'
  $SwiftVersion = $rel[-1].name
}
if (-not $NugetSdkVersion) {
  $vers = (Invoke-RestMethod 'https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.cpp/index.json').versions | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
  if ($SdkVersion) { $vers = @($vers | Where-Object { $_.StartsWith($SdkVersion) }) }
  $NugetSdkVersion = @($vers)[-1]
}
$nuspec = [xml](Invoke-WebRequest -UseBasicParsing "https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.cpp/$NugetSdkVersion/microsoft.windows.sdk.cpp.nuspec").Content
$sdkLicense = $nuspec.package.metadata.licenseUrl
if (-not $sdkLicense) { $sdkLicense = "https://www.nuget.org/packages/Microsoft.Windows.SDK.CPP/$NugetSdkVersion/License" }
$vsLicense = 'https://go.microsoft.com/fwlink/?LinkId=2086102'
$channel = $null
if ($CrtSource -eq 'vsmanifest') {
  $channel = Invoke-RestMethod -Uri $VsChannelUrl
  $bt = $channel.channelItems | Where-Object { $_.id -eq 'Microsoft.VisualStudio.Product.BuildTools' } | Select-Object -First 1
  $lr = $bt.localizedResources | Where-Object { $_.language -eq 'en-us' } | Select-Object -First 1
  if ($lr -and $lr.license) { $vsLicense = $lr.license }
}
Write-Host ''
Write-Host 'This script downloads third-party software under these licenses:'
Write-Host "  - Swift $SwiftVersion (swift.org, Apache 2.0 with Runtime Library Exception): https://swift.org/LICENSE.txt"
Write-Host "  - Microsoft Visual C++ runtime headers/libraries (from the Visual Studio Build Tools channel): $vsLicense"
Write-Host "  - Microsoft Windows SDK $NugetSdkVersion (NuGet Microsoft.Windows.SDK.CPP): $sdkLicense"
Write-Host ''
if (-not $AcceptLicense) {
  throw 'You must review and accept the license terms above: re-run with -AcceptLicense.'
}
$stats.licenses = [ordered]@{ swift = 'https://swift.org/LICENSE.txt'; msvc = $vsLicense; winsdk = $sdkLicense }

# ---------------------------------------------------------------- Swift
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
# `installer.exe /layout <dir>` only copies the bundle exe for this bundle, so read the Burn containers
# (plain CAB files appended after the engine stub) ourselves. Skip the unused toolchain flavour.
$skipRx = if ($NoAsserts) { '^AssertsToolchainContainer$' } else { 'NoAsserts' }
Expand-BurnBundle -Bundle $installer -OutDir $layout -SkipContainer $skipRx
if (-not $KeepDownloads) { Remove-Item -Force $installer }
$msis = Get-ChildItem -Path $layout -Recurse -Filter *.msi -ErrorAction SilentlyContinue
if (-not $msis) { throw 'no MSIs found in bundle' }
Write-Host ('    MSIs: ' + (($msis | ForEach-Object Name) -join ', '))

$swiftRoot = Join-Path $Target 'Swift'   # will contain Toolchains\, Platforms\, Runtimes\ like %LOCALAPPDATA%\Programs\Swift
$stage = Join-Path $Target '_'   # keep this short: admin images hit MAX_PATH (error 1603) otherwise
foreach ($d in @($swiftRoot, $stage)) { if (Test-Path $d) { Remove-Item -Recurse -Force $d } }
New-Item -ItemType Directory -Force -Path $swiftRoot, $stage | Out-Null
$msiSizes = [ordered]@{}
$msiIdx = 0
foreach ($m in $msis) {
  $n = $m.Name.ToLowerInvariant()
  $comp = ($n -split '\.')[0]          # bld.asserts.msi -> bld, rtl.amd64.msi -> rtl, windows.msi -> windows
  $flavourOk = if ($NoAsserts) { $n -notmatch '\.asserts\.' } else { $n -notmatch '\.noasserts\.' }
  $archOk = $true
  if ($comp -eq 'rtl') { $archOk = $n -match $(if ($Arch -eq 'arm64') { 'arm64|aarch64' } else { 'amd64|x64' }) }
  $wanted = ($Components -contains $comp) -or ($AllSdks -and $comp -eq 'android')
  if (-not ($wanted -and $flavourOk -and $archOk)) { Write-Host "    skip $($m.Name)"; continue }
  $msiIdx++
  $s = Join-Path $stage "$msiIdx"
  Write-Host "    msiexec /a $($m.Name)"
  $p = Start-Process -FilePath msiexec.exe -ArgumentList @('/a', "`"$($m.FullName)`"", '/qn', "TARGETDIR=`"$s`"", '/L*v', "`"$dl\$($m.BaseName).admin.log`"") -Wait -PassThru
  if ($p.ExitCode -ne 0) {
    Select-String -Path "$dl\$($m.BaseName).admin.log" -Pattern 'Return value 3|Error 1|error 1|Note: 1: 1[0-9]{3} 2:' -Context 3,1 | Select-Object -First 8 | Out-String -Width 400 | Write-Host
    throw "msiexec /a $($m.Name) failed: $($p.ExitCode)"
  }
  Get-ChildItem -Path $s -Filter *.msi | Remove-Item -Force   # admin image keeps a copy of the .msi at its root
  $msiSizes[$m.Name] = Get-DirSizeMB $s
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
    if ($comp -eq 'rtl') {
      $rt = Join-Path $swiftRoot "Runtimes\$SwiftVersion\usr\bin"
      New-Item -ItemType Directory -Force -Path $rt | Out-Null
      & robocopy.exe $s $rt /E /MOVE /NFL /NDL /NJH /NJS /NP | Out-Null
    } else {
      Write-Host "      note: $($m.Name) also produced: $(($left | ForEach-Object Name) -join ', ') (ignored)"
    }
  }
}
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
$stats.msi_sizes_mb = $msiSizes
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
$stats.swift_disk_full_mb = Get-DirSizeMB $swiftRoot

if (-not $KeepOtherArchs) {
  # windows.msi carries the Swift SDK for x86, x64 and arm64; keep only the target architecture.
  # Arch-specific dirs: usr\lib\swift[_static]\windows\<x86_64|aarch64|i686>, XCTest/Testing usr\bin32|bin64|bin64a,
  # and <arch>-unknown-windows-msvc.swiftmodule/.swiftinterface/.swiftdoc files inside *.swiftmodule dirs.
  $dropTriples = @('x86_64', 'aarch64', 'i686') | Where-Object { $_ -ne $xwinArch }
  $dropBins = @('bin32', 'bin64', 'bin64a') | Where-Object { $_ -ne $(if ($Arch -eq 'arm64') { 'bin64a' } else { 'bin64' }) }
  $plat = $platform.FullName
  Get-ChildItem $plat -Recurse -Directory | Where-Object { ($dropTriples + $dropBins) -contains $_.Name } |
    Sort-Object { $_.FullName.Length } -Descending | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
  Get-ChildItem $plat -Recurse -File | Where-Object { $nm = $_.Name; @($dropTriples | Where-Object { $nm.StartsWith("$_-unknown-windows-msvc") }).Count -gt 0 } |
    Remove-Item -Force
  # .msm merge modules are only needed to build installers that redistribute the runtime
  Remove-Item -Recurse -Force (Join-Path $swiftRoot 'Redistributables') -ErrorAction SilentlyContinue
}
$stats.swift_disk_mb = Get-DirSizeMB $swiftRoot

# ---------------------------------------------------------------- MSVC CRT
$sysroot = Join-Path $Target 'winsysroot'
if (Test-Path $sysroot) { Remove-Item -Recurse -Force $sysroot }
New-Item -ItemType Directory -Force -Path $sysroot | Out-Null
$kits = Join-Path $sysroot 'Windows Kits\10'
$t.Restart()
if ($CrtSource -eq 'vsmanifest') {
  Write-Step "Fetching MSVC CRT from the Visual Studio channel manifest ($VsChannelUrl)"
  $item = $channel.channelItems | Where-Object { $_.id -eq 'Microsoft.VisualStudio.Manifests.VisualStudio' } | Select-Object -First 1
  $vsman = Join-Path $dl 'VisualStudio.vsman'
  Invoke-Download $item.payloads[0].url $vsman
  # The manifest is ~30 MB of JSON; payload URLs end in <package id>.vsix, so a regex is enough (and works in PS 5.1)
  $text = [System.IO.File]::ReadAllText($vsman).Replace('\/', '/')
  $rxOpt = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  if (-not $CrtVersion) {
    $vers = [regex]::Matches($text, '/Microsoft\.VC\.(\d+\.\d+\.\d+\.\d+)\.CRT\.Headers\.base\.vsix"', $rxOpt) | ForEach-Object { [version]$_.Groups[1].Value } | Sort-Object -Unique
    $CrtVersion = "$(@($vers)[-1])"
  }
  $pkgs = @("Microsoft.VC.$CrtVersion.CRT.Headers.base", "Microsoft.VC.$CrtVersion.CRT.$vsArch.Store.base")
  if ($IncludeStaticCrt) { $pkgs += "Microsoft.VC.$CrtVersion.CRT.$vsArch.Desktop.base" }
  $crtBytes = 0
  foreach ($id in $pkgs) {
    $mt = [regex]::Match($text, '"(https://[^"]+/([0-9a-f]{64})/' + [regex]::Escape($id) + '\.vsix)"', $rxOpt)
    if (-not $mt.Success) { throw "package $id not found in the VS manifest" }
    $vsix = Join-Path $dl "$id.vsix"
    Invoke-Download $mt.Groups[1].Value $vsix
    $hash = (Get-FileHash -Algorithm SHA256 $vsix).Hash
    if ($hash -ne $mt.Groups[2].Value.ToUpperInvariant()) { throw "sha256 mismatch for $id" }
    $crtBytes += (Get-Item $vsix).Length
    $x = Join-Path $dl "crt-$id"; New-Item -ItemType Directory -Force -Path $x | Out-Null
    & tar.exe -xf $vsix -C $x 'Contents/VC'
    if ($LASTEXITCODE -ne 0) { throw "failed to extract $id" }
    & robocopy.exe (Join-Path $x 'Contents\VC') (Join-Path $sysroot 'VC') /E /MOVE /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $id" }
  }
  # Store.base also carries UWP/store variants that Swift never uses
  Get-ChildItem (Join-Path $sysroot 'VC\Tools\MSVC') -Recurse -Directory | Where-Object { $_.Name -in 'store', 'uwp', 'enclave', 'onecore' } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  $stats.crt_source = 'vsmanifest'
  $stats.crt_packages = $pkgs
  $stats.crt_download_mb = [math]::Round($crtBytes / 1MB, 1)
} else {
  Write-Step "Fetching MSVC CRT with xwin $XwinVersion"
  $xwinDir = Join-Path $dl "xwin-$XwinVersion"
  $xwinExe = Join-Path $xwinDir "xwin-$XwinVersion-x86_64-pc-windows-msvc\xwin.exe"
  New-Item -ItemType Directory -Force -Path $xwinDir | Out-Null
  $tgz = Join-Path $xwinDir 'xwin.tar.gz'
  Invoke-Download "https://github.com/Jake-Shadle/xwin/releases/download/$XwinVersion/xwin-$XwinVersion-x86_64-pc-windows-msvc.tar.gz" $tgz
  & tar.exe -xzf $tgz -C $xwinDir
  if ($LASTEXITCODE -ne 0) { throw 'failed to extract xwin' }
  $xcache = Join-Path $dl 'xwin-cache'
  $xargs = @('--accept-license', '--arch', $xwinArch, '--cache-dir', $xcache)
  if ($CrtVersion) { $xargs += @('--crt-version', $CrtVersion) }
  $xargs += @('splat', '--output', (Join-Path $dl 'xwin-out'), '--use-winsysroot-style', '--preserve-ms-arch-notation', '--disable-symlinks')
  if ($IncludeDebugLibs) { $xargs += '--include-debug-libs' }
  & $xwinExe @xargs
  if ($LASTEXITCODE -ne 0) { throw "xwin failed: $LASTEXITCODE" }
  Move-Item (Join-Path $dl 'xwin-out\VC') (Join-Path $sysroot 'VC')   # its SDK half is incomplete (no corecrt_math.h): not used
  $stats.crt_source = "xwin $XwinVersion"
  $stats.crt_download_mb = Get-DirSizeMB (Join-Path $xcache 'dl')
}
$stats.crt_s = [math]::Round($t.Elapsed.TotalSeconds, 1)

# ---------------------------------------------------------------- Windows SDK (NuGet)
Write-Step "Fetching Windows SDK $NugetSdkVersion from NuGet (Microsoft.Windows.SDK.CPP + .$Arch)"
$t.Restart()
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
$stats.sysroot_disk_mb = Get-DirSizeMB $sysroot

$vcRoot = Get-ChildItem -Path (Join-Path $sysroot 'VC\Tools\MSVC') -Directory | Sort-Object Name | Select-Object -Last 1
$sdkInc = Get-ChildItem -Path (Join-Path $kits 'Include') -Directory | Sort-Object Name | Select-Object -Last 1
$vcVer = $vcRoot.Name; $sdkVer = $sdkInc.Name
$stats.msvc_version = $vcVer; $stats.winsdk_version = $sdkVer
$msArch = $Arch  # x64 / arm64 (MS naming)
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
    # NB: backslash is an escape character in clang config files -> use forward slashes
    "-Xmicrosoft-windows-sys-root `"$($sysroot.Replace('\', '/'))`"")
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
