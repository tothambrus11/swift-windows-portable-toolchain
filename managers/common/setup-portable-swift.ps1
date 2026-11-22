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
  5. Writes <Target>\activate.ps1 / activate.bat (PATH, SDKROOT, vcvars-style vars) and
     <Target>\mise-env.json (read by the mise/vfox plugin's EnvKeys hook).

  -Part swift   only steps 1 and 5 (Swift is Apache-2.0: no Microsoft license involved)
  -Part sysroot only steps 2-5, on top of an existing -Part swift install in <Target>
  -Part all     everything (default)
  -Part env     only step 5, for a toolchain unpacked from a prebuilt archive (paths are absolute)

  Shared sysroot (one CRT + SDK for every installed Swift version; used by the package-manager
  prototypes in managers/):
  -Part fetch-sysroot  only steps 2-3 into -SysrootDir (default <Target>\winsysroot); no Swift needed.
                       Writes <SysrootDir>\sysroot.json. License-gated like -Part sysroot.
  -Part link           steps 4-5 for the toolchain in <Target> against an existing -SysrootDir, which is
                       only gets Swift's modulemaps copied next to its headers (or, with -ModulemapMode overlay, nothing: a VFS overlay in <Target>).

  This copy lives in managers/common and was adapted from mise/vfox-swift/scripts (branch exp/mise)
  and xwin/setup-portable-swift.ps1 (branch exp/xwin-sysroot).

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
  # Don't replace the installer's duplicate binaries with hard links
  [switch]$NoDedupe,
  # MSVC CRT source: 'vsmanifest' (default, pure PowerShell) or 'xwin'
  [ValidateSet('vsmanifest', 'xwin')][string]$CrtSource = 'vsmanifest',
  [string]$VsChannelUrl = 'https://aka.ms/vs/17/release/channel',
  # e.g. 14.44.17.14 (VS package version); default = newest in the channel manifest
  [string]$CrtVersion = '',
  # Skip the static CRT (libcmt/libcpmt/libvcruntime, +51 MB download). Swift itself links /MD and does not need it,
  # but plain `clang foo.c` does (default /MT; the GNU-style driver always adds -defaultlib:libcmt when linking).
  [switch]$NoStaticCrt,
  # Windows SDK NuGet version (e.g. 10.0.28000.2957) or prefix filter (-SdkVersion 10.0.26100)
  [string]$NugetSdkVersion = '',
  [string]$SdkVersion = '',
  [string]$XwinVersion = '0.10.0',
  [switch]$IncludeDebugLibs,
  # How Swift's ucrt/winsdk/vcruntime modulemaps are made visible: 'copy' next to the headers, or a clang 'overlay'
  [ValidateSet('copy', 'overlay')][string]$ModulemapMode = 'copy',
  [Alias('AcceptMicrosoftLicense')][switch]$AcceptLicense,
  # Keep the downloaded installer / caches (useful for CI caching)
  [switch]$KeepDownloads,
  # Extract SDKs for Android etc. as well (skipped by default)
  [switch]$AllSdks,
  # What to set up (see .DESCRIPTION)
  [ValidateSet('all', 'swift', 'sysroot', 'env', 'fetch-sysroot', 'link')][string]$Part = 'all',
  # Short staging directory for `msiexec /a` (deep paths fail with error 1603). Default: <Target>\_ when
  # <Target> is short, otherwise a fresh directory under %TEMP%.
  [string]$StageDir = '',
  # Where the MSVC CRT + Windows SDK sysroot lives (default <Target>\winsysroot). A sysroot outside <Target>
  # is shared: -Part link only copies the modulemaps into it (nothing at all with -ModulemapMode overlay).
  [string]$SysrootDir = '',
  # Use an already downloaded (and verified) swift.org installer bundle instead of downloading it
  [string]$InstallerPath = '',
  # -Part swift: unpack a prebuilt Swift-only archive (tar.xz with one top-level directory) instead of the
  # official installer. Extracted with the in-box bsdtar, which keeps the archive's hard links.
  [string]$PrebuiltUrl = '',
  [string]$PrebuiltSha256 = '',
  # -Part swift: rename Swift\{Toolchains,Runtimes,Platforms}\<version...> to ...\current, so that tool managers
  # can compute PATH/SDKROOT from the install directory alone (vfox EnvKeys, Scoop env_add_path)
  [switch]$StableNames
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
$doSwift = $Part -in 'all', 'swift'
$doSysroot = $Part -in 'all', 'sysroot', 'fetch-sysroot'   # download the CRT + SDK
$doLink = $Part -in 'all', 'sysroot', 'link'               # configure the toolchain in <Target> for a sysroot
$sysroot = if ($SysrootDir) { [System.IO.Path]::GetFullPath($SysrootDir) } else { Join-Path $Target 'winsysroot' }
$sharedSysroot = -not $sysroot.StartsWith($Target + '\', [System.StringComparison]::OrdinalIgnoreCase)
# Even with a shared sysroot the modulemaps are copied in by default (-Part link writes only these few files);
# -ModulemapMode overlay keeps the sysroot untouched. (Note: the *asserts* toolchain trips an LLVM VFS assertion,
# "virtual path not absolute", whenever SDKROOT/the toolchain is reached through a directory junction or symlink,
# e.g. Scoop's apps\<app>\current or vfox's sdks\<name> link, in either mode - the no-asserts build is fine.)
$stats.part = $Part
if (-not $SwiftVersion -and $doSwift) {
  $rel = Invoke-RestMethod -Uri 'https://www.swift.org/api/v1/install/releases.json'
  $SwiftVersion = $rel[-1].name
}
if ($Part -in 'env', 'link') {
  Write-Host "Writing the environment files for the toolchain in $Target$(if ($Part -eq 'link') { " (sysroot: $sysroot)" })"
} elseif (-not $doSysroot) {
  Write-Host ''
  Write-Host "Installing Swift $SwiftVersion (swift.org, Apache 2.0 with Runtime Library Exception): https://swift.org/LICENSE.txt"
  Write-Host 'The Microsoft C/C++ runtime and Windows SDK are NOT downloaded in this step.'
  Write-Host ''
} else {
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
if ($doSwift) { Write-Host "  - Swift $SwiftVersion (swift.org, Apache 2.0 with Runtime Library Exception): https://swift.org/LICENSE.txt" }
Write-Host "  - Microsoft Visual C++ runtime headers/libraries (from the Visual Studio Build Tools channel): $vsLicense"
Write-Host "  - Microsoft Windows SDK $NugetSdkVersion (NuGet Microsoft.Windows.SDK.CPP): $sdkLicense"
Write-Host ''
if (-not $AcceptLicense) {
  throw 'You must review and accept the license terms above: re-run with -AcceptLicense.'
}
$stats.licenses = [ordered]@{ swift = 'https://swift.org/LICENSE.txt'; msvc = $vsLicense; winsdk = $sdkLicense }
}

if (-not $StageDir) {
  $StageDir = if ($Target.Length -le 48) { Join-Path $Target '_' } else { Join-Path ([System.IO.Path]::GetTempPath()) ('sps' + [guid]::NewGuid().ToString('N').Substring(0, 6)) }
}

# ---------------------------------------------------------------- Swift
if ($doSwift -and $PrebuiltUrl) {
  $t = [System.Diagnostics.Stopwatch]::StartNew()
  Write-Step "Downloading the prebuilt Swift archive"
  $arc = Join-Path $dl 'swift-prebuilt.tar.xz'
  Invoke-Download $PrebuiltUrl $arc
  if ($PrebuiltSha256 -and (Get-FileHash -Algorithm SHA256 $arc).Hash -ne $PrebuiltSha256.ToUpperInvariant()) { throw "sha256 mismatch for $PrebuiltUrl" }
  if (Test-Path (Join-Path $Target 'Swift')) { Remove-Item -Recurse -Force (Join-Path $Target 'Swift') }
  & "$env:SystemRoot\System32\tar.exe" -xf $arc -C $Target --strip-components=1
  if ($LASTEXITCODE) { throw "failed to extract $arc" }
  Remove-Item -Force $arc
  $stats.prebuilt_url = $PrebuiltUrl
  $stats.swift_prebuilt_s = [math]::Round($t.Elapsed.TotalSeconds, 1)
  $doSwift = $false   # already pruned and deduplicated
}
if ($doSwift) {
$stats.swift_version = $SwiftVersion
$suffix = if ($Arch -eq 'arm64') { '-arm64' } else { '' }
$swiftUrl = "https://download.swift.org/swift-$SwiftVersion-release/windows10$suffix/swift-$SwiftVersion-RELEASE/swift-$SwiftVersion-RELEASE-windows10$suffix.exe"
$installer = if ($InstallerPath) { [System.IO.Path]::GetFullPath($InstallerPath) } else { Join-Path $dl "swift-$SwiftVersion-$Arch.exe" }

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
$stage = $StageDir   # keep this short: admin images hit MAX_PATH (error 1603) otherwise
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
}  # doSwift (download + extraction)

$swiftRoot = Join-Path $Target 'Swift'
if ($StableNames -and $Part -in 'all', 'swift') {
  foreach ($sub in 'Toolchains', 'Runtimes', 'Platforms') {
    $d = @(Get-ChildItem (Join-Path $swiftRoot $sub) -Directory)
    if ($d.Count -ne 1) { throw "-StableNames: expected one directory in Swift\$sub, found $($d.Count)" }
    if ($d[0].Name -ne 'current') { Rename-Item $d[0].FullName 'current' }
  }
}
$toolchainBin = $null; $runtimeBin = $null; $sdkRoot = $null
if ($Part -ne 'fetch-sysroot') {
$swiftExe = Get-ChildItem -Path (Join-Path $swiftRoot 'Toolchains') -Recurse -Filter swift.exe -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\Toolchains\\[^\\]+\\usr\\bin\\swift\.exe$' } | Select-Object -First 1
if (-not $swiftExe) { throw "swift.exe not found under $swiftRoot$(if (-not $doSwift) { ' (run -Part swift first)' })" }
$toolchainBin = $swiftExe.DirectoryName

if ($doSwift) {

# The toolchain's Swift tools load their runtime as side-by-side assemblies from usr\bin\<name>\<name>.dll.
# swift-build/swift-test (cli.msi) depend on assemblies (FoundationXML, swiftRegexBuilder) that the installer
# only ships in *other* components (ide/dbg) - so with a minimal component set they fail with error 14001.
# Find what the manifests need and copy just those assembly directories out of the other MSIs.
function Get-MissingAssemblies {
  $need = @()
  foreach ($exe in Get-ChildItem $toolchainBin -Filter *.exe) {
    # The manifest lives in .rsrc near the end of the PE: read only the last 16 MB (whole files are >1 GB in total)
    $fs = [System.IO.File]::OpenRead($exe.FullName)
    try {
      $len = [int][math]::Min($fs.Length, 16MB); $fs.Position = $fs.Length - $len
      $buf = New-Object byte[] $len; [void]$fs.Read($buf, 0, $len)
    } finally { $fs.Dispose() }
    $txt = [System.Text.Encoding]::ASCII.GetString($buf)
    $man = [regex]::Match($txt, '<assembly[\s\S]*?</assembly>').Value
    foreach ($d in [regex]::Matches($man, '<dependentAssembly>[\s\S]*?name="([^"]+)"')) {
      $n = $d.Groups[1].Value
      if ($n -notmatch '^Microsoft\.' -and -not (Test-Path (Join-Path $toolchainBin $n))) { $need += $n }
    }
  }
  return @($need | Select-Object -Unique)
}
$missing = Get-MissingAssemblies
$stats.sxs_assemblies_borrowed = [ordered]@{}
foreach ($extra in 'ide', 'dbg') {
  if ($missing.Count -eq 0) { break }
  $m = $msis | Where-Object { ($_.Name.ToLowerInvariant() -split '\.')[0] -eq $extra -and $(if ($NoAsserts) { $_.Name -match '\.noasserts\.' } else { $_.Name -notmatch '\.noasserts\.' }) } | Select-Object -First 1
  if (-not $m -or $Components -contains $extra) { continue }
  Write-Host "    toolchain tools need assemblies [$($missing -join ', ')]: borrowing them from $($m.Name)"
  $s = "$StageDir-x"
  $p = Start-Process -FilePath msiexec.exe -ArgumentList @('/a', "`"$($m.FullName)`"", '/qn', "TARGETDIR=`"$s`"") -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "msiexec /a $($m.Name) failed: $($p.ExitCode)" }
  $bin = Get-ChildItem (Join-Path $s 'LocalApp\Programs\Swift\Toolchains') -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'usr\bin' } | Select-Object -First 1
  foreach ($n in $missing) {
    if ($bin -and (Test-Path (Join-Path $bin $n))) {
      Copy-Item -Recurse (Join-Path $bin $n) (Join-Path $toolchainBin $n)
      $stats.sxs_assemblies_borrowed[$n] = $m.Name
    }
  }
  Remove-Item -Recurse -Force $s -ErrorAction SilentlyContinue
  $missing = Get-MissingAssemblies
}
if ($missing.Count -gt 0) { Write-Warning "toolchain still misses side-by-side assemblies: $($missing -join ', ')" }
}  # doSwift (SxS assemblies)
$rtDir = if ($SwiftVersion -and (Test-Path (Join-Path $swiftRoot "Runtimes\$SwiftVersion"))) { Join-Path $swiftRoot "Runtimes\$SwiftVersion" } else { Get-ChildItem (Join-Path $swiftRoot 'Runtimes') -Directory -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
$runtimeBin = Join-Path "$rtDir" 'usr\bin'
$platform = Get-ChildItem -Path (Join-Path $swiftRoot 'Platforms') -Recurse -Directory -Filter 'Windows.platform' | Select-Object -First 1
if (-not (Test-Path (Join-Path $runtimeBin 'swiftCore.dll')) -or -not $platform) {
  Get-ChildItem -Path $Target -Recurse -Directory -Depth 6 | Select-Object -ExpandProperty FullName | Write-Host
  throw "runtime ($runtimeBin) or Windows.platform ($platform) not found"
}
$sdkRoot = Join-Path $platform.FullName 'Developer\SDKs\Windows.sdk'
foreach ($x in @($toolchainBin, $runtimeBin, $sdkRoot)) { if (-not $x -or -not (Test-Path $x)) { throw "expected path missing: $x" } }
}  # toolchain lookup
if ($doSwift) {
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

if (-not $NoDedupe) {
  # The installer ships identical copies of the same binary under several names (swift-frontend =
  # swift-autolink-extract = swift-api-digester = swift-symbolgraph-extract, clang = clang++ = clang-cl = ...,
  # lld = lld-link = ld.lld = ...). Replace duplicates with NTFS hard links (no admin needed): ~1.2 GB saved.
  $saved = 0
  $cands = Get-ChildItem $swiftRoot -Recurse -File | Where-Object { $_.Length -ge 1MB } | Group-Object Length | Where-Object { $_.Count -gt 1 }
  foreach ($g in $cands) {
    foreach ($h in $g.Group | Group-Object { (Get-FileHash -Algorithm SHA256 $_.FullName).Hash } | Where-Object { $_.Count -gt 1 }) {
      $keep = $h.Group[0]
      foreach ($dup in $h.Group | Select-Object -Skip 1) {
        if ([System.IO.Path]::GetPathRoot($dup.FullName) -ne [System.IO.Path]::GetPathRoot($keep.FullName)) { continue }
        Remove-Item -LiteralPath $dup.FullName -Force
        New-Item -ItemType HardLink -Path $dup.FullName -Target $keep.FullName | Out-Null
        $saved += $dup.Length
      }
    }
  }
  $stats.dedupe_saved_mb = [math]::Round($saved / 1MB, 1)
  $stats.swift_disk_unique_mb = [math]::Round($stats.swift_disk_mb - $saved / 1MB, 1)
}
}  # doSwift (pruning + dedupe)

$t = [System.Diagnostics.Stopwatch]::StartNew()
$kits = Join-Path $sysroot 'Windows Kits\10'
$envVars = [ordered]@{ SDKROOT = "$sdkRoot\"; SWIFT_PORTABLE_ROOT = $Target }
if ($doSysroot) {
# ---------------------------------------------------------------- MSVC CRT
if (Test-Path $sysroot) { Remove-Item -Recurse -Force $sysroot }
New-Item -ItemType Directory -Force -Path $sysroot | Out-Null
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
  if (-not $NoStaticCrt) { $pkgs += "Microsoft.VC.$CrtVersion.CRT.$vsArch.Desktop.base" }
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
  # PDBs of the static libs (~150 MB) and, unless asked for, the debug CRT variants are not needed
  Get-ChildItem (Join-Path $sysroot 'VC\Tools\MSVC') -Recurse -File -Filter *.pdb | Remove-Item -Force
  if (-not $IncludeDebugLibs) {
    Get-ChildItem (Join-Path $sysroot 'VC\Tools\MSVC') -Recurse -File -Filter *.lib | Where-Object { $_.BaseName -match '^(libcmtd|libcpmtd\d?|libvcruntimed|libconcrtd\d?|msvcrtd|msvcprtd|vcruntimed|concrtd|libompd|vcompd|vcampd|comsuppd|comsuppwd|msvcmrtd.*|ptrustmd)$' } | Remove-Item -Force
  }
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
}  # doSysroot (fetch)

if ($doLink -or $Part -eq 'fetch-sysroot') {
if (-not (Test-Path (Join-Path $sysroot 'VC\Tools\MSVC'))) { throw "no MSVC/WinSDK sysroot in $sysroot (run -Part fetch-sysroot -AcceptLicense first)" }
$vcRoot =Get-ChildItem -Path (Join-Path $sysroot 'VC\Tools\MSVC') -Directory | Sort-Object Name | Select-Object -Last 1
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

if ($Part -eq 'fetch-sysroot') {
  # A shared sysroot: record what it contains; toolchains are configured for it with -Part link
  [ordered]@{ kind = 'portable'; arch = $Arch; msvc_version = $vcVer; winsdk_version = $sdkVer
    nuget_sdk_version = $NugetSdkVersion; licenses_accepted = $stats.licenses; include = ($include -join ';'); lib = ($lib -join ';')
    fetched = (Get-Date).ToUniversalTime().ToString('o') } |
    ConvertTo-Json -Depth 4 | ForEach-Object { [System.IO.File]::WriteAllText((Join-Path $sysroot 'sysroot.json'), $_) }
  if (-not $KeepDownloads) { Remove-Item -Recurse -Force $dl -ErrorAction SilentlyContinue }
  $stats.total_s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  $stats | ConvertTo-Json | Set-Content -Path (Join-Path $sysroot 'setup-stats-fetch-sysroot.json') -Encoding UTF8
  Write-Step "Done: MSVC $vcVer + Windows SDK $sdkVer in $sysroot"
  $stats | Format-Table -AutoSize | Out-String | Write-Host
  return
}

# ---------------------------------------------------------------- modulemaps
# The Swift frontend only VFS-overlays its ucrt/winsdk/vcruntime modulemaps onto the SDK when it can
# *locate* the SDK: -windows-sdk-root/-visualc-tools-root flags or the HKLM registry (admin). SwiftPM does
# not forward -Xswiftc flags to every job (e.g. the generated test runner), so we make them visible ourselves:
#   copy    (default): place them physically next to the headers (what pre-5.9 Swift installers did)
#   overlay          : leave the SDK untouched and map them in with a clang VFS overlay referenced from clang.cfg
$share = Join-Path $sdkRoot 'usr\share'
$inc = "$kits\Include\$sdkVer"
$placements = @()
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
  if ($dest -and (Test-Path (Split-Path $dest))) { $placements += [pscustomobject]@{ src = $f.FullName; dest = $dest } }
  else { Write-Host "    (not placed) $($f.Name)" }
}
$cfgExtra = @()
if ($ModulemapMode -eq 'copy') {
  foreach ($pl in $placements) { Copy-Item $pl.src $pl.dest -Force; Write-Host "    $(Split-Path $pl.src -Leaf) -> $($pl.dest)" }
} else {
  $roots = @()
  foreach ($grp in $placements | Group-Object { Split-Path $_.dest }) {
    $roots += [ordered]@{ name = $grp.Name; type = 'directory'
      contents = @($grp.Group | ForEach-Object { [ordered]@{ name = (Split-Path $_.dest -Leaf); type = 'file'; 'external-contents' = $_.src } }) }
  }
  # A shared sysroot stays untouched: the overlay belongs to this toolchain
  $overlay = Join-Path $(if ($sharedSysroot) { $Target } else { $sysroot }) 'swift-modulemaps.vfsoverlay.yaml'
  [ordered]@{ version = 0; 'case-sensitive' = 'false'; roots = $roots } | ConvertTo-Json -Depth 8 | Set-Content -Path $overlay -Encoding ASCII
  Write-Host "    VFS overlay with $($placements.Count) files: $overlay"
  $cfgExtra += "-ivfsoverlay `"$($overlay.Replace('\', '\\'))`""
}
$stats.modulemap_mode = $ModulemapMode

# ---------------------------------------------------------------- clang default config
# swiftc links through clang.exe, which defaults to MSVC link.exe (absent without VS), and SwiftPM's
# build system does not pass INCLUDE/LIB to every clang job. clang reads <clang-dir>\clang.cfg by
# default (so does the Swift ClangImporter), so make lld the default linker and point clang at the
# /winsysroot-style sysroot.
foreach ($cfg in 'clang.cfg', 'clang++.cfg') {
  Set-Content -Path (Join-Path $toolchainBin $cfg) -Encoding ASCII -Value (@(
    '# added by setup-portable-swift.ps1 (no Visual Studio): use lld and the portable MSVC/WinSDK sysroot',
    '-fuse-ld=lld',
    # NB: backslash is an escape character in clang config files -> double it. Do NOT use forward slashes:
    # a forward-slash sysroot crashes swift-frontend's VFS overlay ("Paths should not contain traversal components").
    "-Xmicrosoft-windows-sys-root `"$($sysroot.Replace('\', '\\'))`"") + $cfgExtra)
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
}  # doLink
if (-not $doLink -and (Test-Path (Join-Path $toolchainBin 'clang.cfg'))) {
  Write-Host '    note: a portable MSVC/WinSDK sysroot from an earlier run is still configured (clang.cfg kept)'
}
if (-not $KeepDownloads) {
  Write-Step 'Removing downloads'
  Remove-Item -Recurse -Force $dl -ErrorAction SilentlyContinue
}
$pathPrefix = "$toolchainBin;$runtimeBin"

# For the mise/vfox plugin's EnvKeys hook: PATH entries + variables, and whether the portable sysroot is set up
$sysrootReady = (Test-Path (Join-Path $toolchainBin 'clang.cfg')) -and (Test-Path $sysroot)
[ordered]@{ path = @($toolchainBin, $runtimeBin); env = $envVars; sysroot = $sysrootReady; arch = $Arch } |
  ConvertTo-Json -Depth 4 | ForEach-Object { [System.IO.File]::WriteAllText((Join-Path $Target 'mise-env.json'), $_) }   # no BOM

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
$stats.total_disk_mb = Get-DirSizeMB $Target   # counts hard links once per name
if ($stats.Contains('dedupe_saved_mb')) { $stats.total_disk_unique_mb = [math]::Round($stats.total_disk_mb - $stats.dedupe_saved_mb, 1) }
$stats | ConvertTo-Json | Set-Content -Path (Join-Path $Target "setup-stats-$Part.json") -Encoding UTF8
Write-Step 'Done'
$stats | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Activate with:  . '$Target\activate.ps1'   (or call `"$Target\activate.bat`" from cmd)"
