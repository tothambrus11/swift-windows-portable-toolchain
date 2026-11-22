<#
.SYNOPSIS
  Installs the official swift.org Windows toolchain portably (no installer run, no registry, no admin):
  carves the WiX Burn bundle, extracts the needed MSIs with `msiexec /a`, borrows missing side-by-side
  assemblies, prunes other architectures and hard-links duplicate binaries.
  Implementation of actions/setup-swift-portable (adapted from xwin/setup-portable-swift.ps1; Swift part only).
  Pair it with actions/setup-msvc (mode portable/auto) for the MSVC CRT + Windows SDK.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Target,
  [string]$SwiftVersion = '',
  [ValidateSet('', 'x64', 'arm64')][string]$Arch = '',
  [string[]]$Components = @('bld', 'cli', 'rtl', 'windows'),
  [switch]$Full,
  [switch]$NoAsserts,
  [switch]$KeepOtherArchs,
  [switch]$NoDedupe,
  [switch]$KeepDownloads,
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
if (-not $SwiftVersion) {
  $rel = Invoke-RestMethod -Uri 'https://www.swift.org/api/v1/install/releases.json'
  $SwiftVersion = $rel[-1].name
}
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
  if ($comp -eq 'rtl' -and @($msis | Where-Object { $_.Name -match '^rtl\.' }).Count -gt 1) { $archOk = $n -match $(if ($Arch -eq 'arm64') { 'arm64|aarch64' } else { 'amd64|x64' }) }
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
  $s = Join-Path $Target '_x'
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

# ---------------------------------------------------------------- outputs / environment
$stats.total_s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
if (-not $KeepDownloads) { Remove-Item -Recurse -Force $dl -ErrorAction SilentlyContinue }
$stats | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $Target 'setup-stats.json') -Encoding UTF8
$stats | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
$env:Path = "$toolchainBin;$runtimeBin;$env:Path"
$env:SDKROOT = "$sdkRoot\"
if ($env:GITHUB_PATH) {
  # GITHUB_PATH prepends each line, so the last line written ends up first
  Add-Content -Path $env:GITHUB_PATH -Value $runtimeBin -Encoding utf8
  Add-Content -Path $env:GITHUB_PATH -Value $toolchainBin -Encoding utf8
}
if ($env:GITHUB_ENV) { Add-Content -Path $env:GITHUB_ENV -Value "SDKROOT=$sdkRoot\" -Encoding utf8 }
if ($env:GITHUB_OUTPUT) {
  Add-Content -Path $env:GITHUB_OUTPUT -Encoding utf8 -Value @("toolchain-bin=$toolchainBin", "runtime-bin=$runtimeBin", "sdkroot=$sdkRoot\", "swift-version=$SwiftVersion", "root=$swiftRoot")
}
Write-Step "Swift $SwiftVersion ready: $toolchainBin"
