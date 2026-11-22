<#
.SYNOPSIS
  Provides an MSVC CRT + Windows SDK environment (vcvars-equivalent), either from an installed Visual Studio
  or portably (downloaded straight from Microsoft: the Visual Studio channel manifest + NuGet).

.DESCRIPTION
  Implementation of the `setup-msvc` GitHub Action (actions/setup-msvc/action.yml). Inputs are read from
  SMSVC_* environment variables (set by action.yml), so it can also be run locally:

    $env:SMSVC_ACCEPT_LICENSE = 'true'; $env:SMSVC_MODE = 'portable'
    pwsh ./setup-msvc.ps1 -Phase all

  Phases:
    resolve  decide installed vs portable. Installed: run vsdevcmd.bat and export its environment (done).
             Portable: check the license gate, resolve exact package versions/URLs, write a plan file.
    install  portable only: download + lay out the /winsysroot tree (unless already present, e.g. restored by
             actions/cache), create case aliases on case-sensitive file systems, wire a Swift toolchain
             (modulemaps + clang.cfg), export the environment.
    all      resolve + install in one process (for local use).
#>
[CmdletBinding()]
param([ValidateSet('resolve', 'install', 'all')][string]$Phase = 'all')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ------------------------------------------------------------------------------------------------ helpers
function Get-In([string]$name, [string]$default = '') {
  $v = [Environment]::GetEnvironmentVariable("SMSVC_$name")
  if ([string]::IsNullOrWhiteSpace($v)) { return $default } else { return $v.Trim() }
}
function Test-True([string]$v) { return @('true', '1', 'yes', 'on') -contains "$v".ToLowerInvariant() }
function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Set-Out([string]$name, [string]$value) {
  if ($env:GITHUB_OUTPUT) { Add-Content -Path $env:GITHUB_OUTPUT -Value "$name=$value" -Encoding utf8 }
  Write-Host "    output $name=$value"
}
$script:exported = [ordered]@{}
function Export-Var([string]$name, [string]$value) {
  [Environment]::SetEnvironmentVariable($name, $value)
  if ($env:GITHUB_ENV) { Add-Content -Path $env:GITHUB_ENV -Value "$name=$value" -Encoding utf8 }
  $script:exported[$name] = $value
}
function Add-ToPath([string]$dir) {
  $sep = [IO.Path]::PathSeparator
  $env:PATH = "$dir$sep$env:PATH"
  if ($env:GITHUB_PATH) { Add-Content -Path $env:GITHUB_PATH -Value $dir -Encoding utf8 }
  $script:pathAdded += @($dir)
}
$script:pathAdded = @()

function Get-HostArch {
  if ($IsWindows) {
    $a = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    return (ConvertTo-MsArch $a)
  }
  return (ConvertTo-MsArch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()))
}
function ConvertTo-MsArch([string]$a) {
  switch -regex ("$a".ToLowerInvariant()) {
    '^(x64|amd64|x86_64)$' { return 'x64' }
    '^(arm64|aarch64)$'    { return 'arm64' }
    '^(x86|win32|i[3-6]86)$' { return 'x86' }
    '^$'                   { return '' }
    default { throw "unsupported architecture '$a' (use x64, arm64 or x86)" }
  }
}
function Invoke-Download([string]$url, [string]$out) {
  Write-Host "    GET $url"
  $curl = if ($IsWindows) { 'curl.exe' } else { 'curl' }
  & $curl -L --fail --retry 4 --retry-delay 3 --silent --show-error -o $out $url
  if ($LASTEXITCODE -ne 0) { throw "download failed: $url" }
}
# Extracts zip entries below $prefix (a forward-slash path inside the archive) into $dest, stripping the prefix.
# Uses System.IO.Compression so it works the same on Windows, Linux and macOS. VSIX/NuGet entry names are
# percent-encoded (OPC), so decode them.
function Expand-ZipPrefix([string]$zip, [string]$prefix, [string]$dest) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $za = [System.IO.Compression.ZipFile]::OpenRead($zip)
  $n = 0
  try {
    foreach ($e in $za.Entries) {
      $name = [Uri]::UnescapeDataString($e.FullName.Replace('\', '/'))
      if (-not $name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
      $rel = $name.Substring($prefix.Length).TrimStart('/')
      if (-not $rel -or $name.EndsWith('/')) { continue }
      $target = Join-Path $dest $rel
      $dir = Split-Path $target
      if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
      $n++
    }
  } finally { $za.Dispose() }
  return $n
}
function Get-ZipTopDirs([string]$zip, [int]$depth = 2) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $za = [System.IO.Compression.ZipFile]::OpenRead($zip)
  try { return @($za.Entries | ForEach-Object { (($_.FullName -split '/') | Select-Object -First $depth) -join '/' } | Sort-Object -Unique) }
  finally { $za.Dispose() }
}

# ------------------------------------------------------------------------------------------------ inputs
$hostOs = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
$hostArchDetected = Get-HostArch
$arch = ConvertTo-MsArch (Get-In 'ARCH'); if (-not $arch) { $arch = $hostArchDetected }
$hostArch = ConvertTo-MsArch (Get-In 'HOST_ARCH'); if (-not $hostArch) { $hostArch = $hostArchDetected }
$mode = (Get-In 'MODE' 'auto').ToLowerInvariant()
if ($mode -notin 'auto', 'installed', 'portable') { throw "mode must be auto, installed or portable (got '$mode')" }
$winsdk = Get-In 'WINSDK' 'latest'; if ($winsdk -eq 'latest') { $winsdk = '' }
$msvcVersion = (Get-In 'MSVC_VERSION' 'latest').ToLowerInvariant(); if ($msvcVersion -eq 'default') { $msvcVersion = 'latest' }
$vsChannel = Get-In 'VS_CHANNEL' '18'
$channelUrl = switch ($vsChannel) {
  '18' { 'https://aka.ms/vs/18/stable/channel' }
  '17' { 'https://aka.ms/vs/17/release/channel' }
  default { $vsChannel }
}
$crtStatic = Test-True (Get-In 'CRT_STATIC' 'true')
$debugLibs = Test-True (Get-In 'DEBUG_LIBS' 'false')
$acceptLicense = Test-True (Get-In 'ACCEPT_LICENSE' 'false')
$swiftToolchainIn = Get-In 'SWIFT_TOOLCHAIN' 'auto'
$modulemaps = (Get-In 'MODULEMAPS' 'copy').ToLowerInvariant()
$exportCc = (Get-In 'EXPORT_CC' 'false').ToLowerInvariant()
$vsComponents = @((Get-In 'VS_COMPONENTS') -split ';' | Where-Object { $_ })
$tmpRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$installDir = Get-In 'INSTALL_DIR'
if (-not $installDir) {
  $installDir = if ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP 'setup-msvc' } else { Join-Path $HOME '.setup-msvc' }
}
$installDir = [IO.Path]::GetFullPath($installDir)
$planFile = Join-Path $tmpRoot 'setup-msvc-plan.json'
$vsArch = @{ x64 = 'x64'; arm64 = 'ARM64'; x86 = 'x86' }[$arch]

# ------------------------------------------------------------------------------------------------ installed VS
function Get-KitsRoot {
  foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots') {
    $p = Get-ItemProperty -Path $k -Name KitsRoot10 -ErrorAction SilentlyContinue
    if ($p -and $p.KitsRoot10) { return $p.KitsRoot10.TrimEnd('\') }
  }
  $d = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
  if (Test-Path $d) { return $d }
  return $null
}

# Returns @{ ok; reason; installPath; toolset; sdk } for the newest VS instance satisfying the request.
function Find-InstalledVS {
  $r = @{ ok = $false; reason = '' }
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path $vswhere)) { $r.reason = "vswhere.exe not found ($vswhere)"; return $r }
  $req = @($vsComponents)
  if ($msvcVersion -eq 'latest') {
    $req += $(if ($arch -eq 'arm64') { 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' } else { 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' })
  }
  $vsArgs = @('-nologo', '-products', '*', '-format', 'json', '-utf8')
  foreach ($c in $req) { $vsArgs += @('-requires', $c) }
  $json = & $vswhere @vsArgs | Out-String
  $instances = @($json | ConvertFrom-Json | Sort-Object { [version]$_.installationVersion } -Descending)
  if ($instances.Count -eq 0) { $r.reason = "no Visual Studio instance with: $($req -join ', ')"; return $r }
  $hostDir = @{ x64 = 'Hostx64'; arm64 = 'HostARM64'; x86 = 'Hostx86' }[$hostArch]
  $kitsRoot = Get-KitsRoot
  $sdkOk = $false; $sdkVer = ''
  if ($kitsRoot) {
    $sdks = @(Get-ChildItem (Join-Path $kitsRoot 'Include') -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^10\.' -and (Test-Path (Join-Path $_.FullName 'um\windows.h')) -and
        (Test-Path (Join-Path $kitsRoot "Lib\$($_.Name)\um\$arch\kernel32.lib")) } | Sort-Object { [version]$_.Name })
    if ($winsdk) { $hit = @($sdks | Where-Object { $_.Name -eq $winsdk }) } else { $hit = $sdks }
    if ($hit.Count -gt 0) { $sdkOk = $true; $sdkVer = $hit[-1].Name }
  }
  if (-not $sdkOk) {
    $have = if ($kitsRoot) { (Get-ChildItem (Join-Path $kitsRoot 'Include') -Directory -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', ' } else { 'none' }
    $r.reason = "Windows SDK $(if ($winsdk) { $winsdk } else { '(any)' }) for $arch not installed (installed: $have)"; return $r
  }
  $reasons = @()
  foreach ($inst in $instances) {
    $msvcRoot = Join-Path $inst.installationPath 'VC\Tools\MSVC'
    if (-not (Test-Path $msvcRoot)) { $reasons += "$($inst.installationPath): no VC\Tools\MSVC"; continue }
    $toolsets = @(Get-ChildItem $msvcRoot -Directory | Where-Object { Test-Path (Join-Path $_.FullName "bin\$hostDir\$arch\cl.exe") } | Sort-Object { [version]$_.Name })
    if ($msvcVersion -eq 'latest') {
      $defFile = Join-Path $inst.installationPath 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt'
      $def = if (Test-Path $defFile) { (Get-Content $defFile -Raw).Trim() } else { '' }
      $pick = @($toolsets | Where-Object { $_.Name -eq $def })
    } else {
      $pick = @($toolsets | Where-Object { $_.Name -eq $msvcVersion -or $_.Name.StartsWith("$msvcVersion.") })
    }
    if ($pick.Count -eq 0) {
      $reasons += "$($inst.installationPath): toolset $msvcVersion ($hostDir\$arch) not installed (have: $(($toolsets | ForEach-Object Name) -join ', '))"
      continue
    }
    return @{ ok = $true; reason = ''; installPath = $inst.installationPath; toolset = $pick[-1].Name; sdk = $sdkVer; displayName = $inst.displayName }
  }
  $r.reason = $reasons -join '; '
  return $r
}

function Invoke-InstalledMode($vs) {
  Write-Step "Using installed $($vs.displayName) at $($vs.installPath) (toolset $($vs.toolset), Windows SDK $($vs.sdk))"
  $vsdevcmd = Join-Path $vs.installPath 'Common7\Tools\VsDevCmd.bat'
  # Same arguments as compnerd/gha-setup-vsdevenv
  $hostArg = @{ x64 = 'amd64'; arm64 = 'arm64'; x86 = 'x86' }[$hostArch]
  $a = @("-host_arch=$hostArg", "-arch=$(@{ x64 = 'amd64'; arm64 = 'arm64'; x86 = 'x86' }[$arch])")
  if ($msvcVersion -ne 'latest') { $a += "-vcvars_ver=$msvcVersion" }
  if ($winsdk) { $a += "-winsdk=$winsdk" }
  $cmdFile = Join-Path $tmpRoot "setup-msvc-vsdevcmd-$PID.cmd"
  Set-Content -Path $cmdFile -Encoding ascii -Value @(
    '@echo off',
    "call `"$vsdevcmd`" -no_logo $($a -join ' ')",
    'if errorlevel 1 exit /b 1',
    'echo ---SETUP-MSVC-ENV---',
    'set')
  Write-Host "    > VsDevCmd.bat $($a -join ' ')"
  $out = & cmd.exe /d /c $cmdFile
  $code = $LASTEXITCODE
  Remove-Item $cmdFile -Force -ErrorAction SilentlyContinue
  $idx = [array]::IndexOf($out, '---SETUP-MSVC-ENV---')
  if ($code -ne 0 -or $idx -lt 0 -or ($out -match '^\[ERROR:')) { $out | Write-Host; throw "VsDevCmd.bat failed ($code)" }
  if ($idx -gt 0) { $out[0..($idx - 1)] | Where-Object { $_ } | Write-Host }
  $old = @{}; Get-ChildItem env: | ForEach-Object { $old[$_.Name] = $_.Value }
  foreach ($line in $out[($idx + 1)..($out.Count - 1)]) {
    $eq = $line.IndexOf('='); if ($eq -le 0) { continue }
    $k = $line.Substring(0, $eq); $v = $line.Substring($eq + 1)
    if ($k -in 'PROMPT', 'CMDCMDLINE', 'ERRORLEVEL') { continue }
    if ($old.ContainsKey($k) -and $old[$k] -ceq $v) { continue }
    Export-Var $k $v   # includes Path, exactly like gha-setup-vsdevenv
  }
  $vcTools = "$env:VCToolsInstallDir".TrimEnd('\')
  $toolsVer = "$env:VCToolsVersion"
  $sdkVer = "$env:WindowsSDKVersion".TrimEnd('\')
  if ($msvcVersion -ne 'latest' -and -not ($toolsVer -eq $msvcVersion -or $toolsVer.StartsWith("$msvcVersion."))) { throw "VsDevCmd selected toolset $toolsVer, not $msvcVersion" }
  if ($winsdk -and $sdkVer -ne $winsdk) { throw "VsDevCmd selected Windows SDK $sdkVer, not $winsdk" }
  Set-Out 'mode' 'installed'
  Set-Out 'msvc-version' $toolsVer
  Set-Out 'winsdk-version' $sdkVer
  Set-Out 'vc-tools-dir' $vcTools
  Set-Out 'winsdk-dir' "$env:WindowsSdkDir".TrimEnd('\')
  Set-Out 'vs-install-path' $vs.installPath
  Set-Out 'sysroot' ''
  Set-Out 'install-dir' ''
  Set-Out 'cache-key' ''
  if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content $env:GITHUB_STEP_SUMMARY -Value "setup-msvc: **installed** $($vs.displayName), MSVC $toolsVer, Windows SDK $sdkVer ($hostArch -> $arch)"
  }
}

# ------------------------------------------------------------------------------------------------ portable: resolve
function Resolve-Portable {
  Write-Step "Resolving portable MSVC CRT ($msvcVersion, channel $channelUrl) + Windows SDK ($(if ($winsdk) { $winsdk } else { 'latest' })) for $arch"
  $dl = Join-Path $tmpRoot 'setup-msvc-dl'; New-Item -ItemType Directory -Force -Path $dl | Out-Null
  # --- Visual Studio channel + package manifest
  $chFile = Join-Path $dl 'channel.json'
  Invoke-Download $channelUrl $chFile
  $channel = Get-Content -Raw $chFile | ConvertFrom-Json
  $vsLicense = 'https://visualstudio.microsoft.com/license-terms/'
  $bt = @($channel.channelItems | Where-Object { $_.id -eq 'Microsoft.VisualStudio.Product.BuildTools' })[0]
  if ($bt -and $bt.PSObject.Properties['localizedResources']) {
    $lr = @($bt.localizedResources | Where-Object { $_.language -eq 'en-us' })[0]
    if ($lr -and $lr.PSObject.Properties['license'] -and $lr.license) { $vsLicense = $lr.license }
  }
  $manItem = @($channel.channelItems | Where-Object { $_.id -eq 'Microsoft.VisualStudio.Manifests.VisualStudio' })[0]
  if (-not $manItem) { throw "no VisualStudio manifest in channel $channelUrl" }

  # --- Windows SDK (NuGet) version
  $nugetVersions = @((Invoke-RestMethod 'https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.cpp/index.json').versions |
    Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Sort-Object { [version]$_ })
  if (-not $winsdk) { $nugetVer = $nugetVersions[-1] }
  elseif ($nugetVersions -contains $winsdk) { $nugetVer = $winsdk }
  else {
    $pfx = (($winsdk -split '\.') | Select-Object -First 3) -join '.'
    $c = @($nugetVersions | Where-Object { $_.StartsWith("$pfx.") })
    if ($c.Count -eq 0) { throw "Windows SDK $winsdk is not available on NuGet (Microsoft.Windows.SDK.CPP). Available: $($nugetVersions -join ', ')" }
    $nugetVer = $c[-1]
  }
  $nuspec = [xml](Invoke-WebRequest -UseBasicParsing "https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.cpp/$nugetVer/microsoft.windows.sdk.cpp.nuspec").Content
  $sdkLicense = "$($nuspec.package.metadata.licenseUrl)"
  if (-not $sdkLicense) { $sdkLicense = "https://www.nuget.org/packages/Microsoft.Windows.SDK.CPP/$nugetVer/License" }

  Write-Host ''
  Write-Host 'setup-msvc (portable mode) downloads Microsoft software, directly from Microsoft, under these licenses:'
  Write-Host "  - Microsoft Visual C++ runtime headers/libraries (Visual Studio Build Tools): $vsLicense"
  Write-Host "    Use of the MSVC libraries requires a valid Visual Studio license (Community is fine for individuals,"
  Write-Host "    open source and small teams; see https://visualstudio.microsoft.com/vs/community/)."
  Write-Host "  - Microsoft Windows SDK $nugetVer (NuGet Microsoft.Windows.SDK.CPP): $sdkLicense"
  Write-Host ''
  if (-not $acceptLicense) { throw "Review the license terms above and set 'accept-license: true' to accept them (portable mode)." }

  $vsman = Join-Path $dl 'VisualStudio.vsman'
  Invoke-Download $manItem.payloads[0].url $vsman
  $doc = [System.Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($vsman), [System.Text.Json.JsonDocumentOptions]::new())
  $pk = @{}
  try {
    foreach ($p in $doc.RootElement.GetProperty('packages').EnumerateArray()) {
      $id = $p.GetProperty('id').GetString()
      if ($id -notmatch '^Microsoft\.(VC\.[\d.]+\.CRT\.|VisualCpp\.CRT\.Headers$)') { continue }
      $o = @{ id = $id; version = $p.GetProperty('version').GetString(); payloads = @(); deps = @() }
      # (JsonElement.TryGetProperty's out parameter does not bind from PowerShell: enumerate instead)
      $props = @{}; foreach ($pp in $p.EnumerateObject()) { $props[$pp.Name] = $pp.Value }
      if ($props.ContainsKey('payloads')) {
        foreach ($x in $props['payloads'].EnumerateArray()) {
          $xp = @{}; foreach ($pp in $x.EnumerateObject()) { $xp[$pp.Name] = $pp.Value }
          $o.payloads += @{
            url = $xp['url'].GetString()
            sha256 = $(if ($xp.ContainsKey('sha256')) { $xp['sha256'].GetString() } else { $null })
            size = $(if ($xp.ContainsKey('size')) { $xp['size'].GetInt64() } else { 0 }) }
        }
      }
      if ($props.ContainsKey('dependencies')) { foreach ($d in $props['dependencies'].EnumerateObject()) { $o.deps += $d.Name } }
      if (-not $pk.ContainsKey($id.ToLowerInvariant())) { $pk[$id.ToLowerInvariant()] = $o }
    }
  } finally { $doc.Dispose() }
  Remove-Item $vsman -Force

  $headerIds = @($pk.Values | Where-Object { $_.id -match '^Microsoft\.VC\.([\d.]+)\.CRT\.Headers\.base$' })
  $avail = @($headerIds | ForEach-Object { $_.version } | Sort-Object { [version]$_ } -Unique)
  if ($msvcVersion -eq 'latest') {
    $alias = $pk['microsoft.visualcpp.crt.headers']
    $hid = @($alias.deps | Where-Object { $_ -match '\.CRT\.Headers\.base$' })[0]
    if (-not $hid) { throw 'cannot determine the default toolset (Microsoft.VisualCpp.CRT.Headers)' }
    $hdr = $pk[$hid.ToLowerInvariant()]
  } else {
    $cands = @($headerIds | Where-Object { $_.version -eq $msvcVersion -or $_.version.StartsWith("$msvcVersion.") })
    if ($cands.Count -eq 0) {
      # "14.44.35207" (toolset dir) vs package version 14.44.35220: fall back to major.minor
      $mm = (($msvcVersion -split '\.') | Select-Object -First 2) -join '.'
      $cands = @($headerIds | Where-Object { $_.version.StartsWith("$mm.") })
      if ($cands.Count -gt 0) { Write-Host "::warning::MSVC $msvcVersion not found exactly; using the newest $mm toolset" }
    }
    if ($cands.Count -eq 0) { throw "MSVC toolset $msvcVersion not in $channelUrl. Available: $($avail -join ', ')" }
    $hdr = $cands | Sort-Object { [version]$_.version } | Select-Object -Last 1
  }
  $stem = [regex]::Match($hdr.id, '^Microsoft\.VC\.([\d.]+)\.CRT\.Headers\.base$').Groups[1].Value   # e.g. 14.44.17.14 or 14.52
  $ids = @("Microsoft.VC.$stem.CRT.Headers.base", "Microsoft.VC.$stem.CRT.$vsArch.Store.base")
  if ($crtStatic) { $ids += "Microsoft.VC.$stem.CRT.$vsArch.Desktop.base" }
  $pkgs = @()
  foreach ($id in $ids) {
    $p = $pk[$id.ToLowerInvariant()]
    if (-not $p -or $p.payloads.Count -eq 0) { throw "package $id not found in the VS manifest" }
    $pay = $p.payloads[0]
    $sha = $pay.sha256
    if (-not $sha) { $sha = [regex]::Match($pay.url, '/([0-9a-fA-F]{64})/').Groups[1].Value }
    $pkgs += [ordered]@{ id = $id; version = $p.version; url = $pay.url; sha256 = $sha; size = $pay.size }
  }
  Write-Host "    MSVC CRT packages: $(($pkgs | ForEach-Object { "$($_.id) ($($_.version))" }) -join ', ')"
  Write-Host "    Windows SDK NuGet: $nugetVer"
  $key = "setup-msvc-v1-$hostOs-$arch-crt$($hdr.version)-sdk$nugetVer-static$([int]$crtStatic)-dbg$([int]$debugLibs)"
  $plan = [ordered]@{
    key = $key; arch = $arch; hostArch = $hostArch; msvcPackageVersion = $hdr.version; msvcStem = $stem; crt = $pkgs
    nugetVersion = $nugetVer; licenses = [ordered]@{ msvc = $vsLicense; winsdk = $sdkLicense }; installDir = $installDir
  }
  $plan | ConvertTo-Json -Depth 6 | Set-Content -Path $planFile -Encoding utf8
  Set-Out 'mode' 'portable'
  Set-Out 'install-dir' $installDir
  Set-Out 'cache-key' $key
  Set-Out 'msvc-package-version' $hdr.version
}

# ------------------------------------------------------------------------------------------------ portable: install
function Test-CaseSensitive([string]$dir) {
  $f = Join-Path $dir '.CaseProbe'
  Set-Content -Path $f -Value x
  $cs = -not (Test-Path -LiteralPath (Join-Path $dir '.caseprobe'))
  Remove-Item -LiteralPath $f -Force
  return $cs
}

# On case-sensitive file systems the Windows SDK/CRT need alias names: headers include each other with
# inconsistent case (<WinDef.h> vs windef.h, ...) and linkers look for kernel32.lib / OLDNAMES.lib etc.
# Like xwin: scan the #include directives and create symlinks for every spelling that is used, plus
# lower-case aliases for all headers and libraries.
function New-CaseAliases([string]$sysroot, [string[]]$incDirs, [string[]]$libDirs) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $made = 0
  $dirIndex = @{}   # dir -> hashtable(lower name -> actual name)
  function Get-Index([string]$d) {
    if (-not $dirIndex.ContainsKey($d)) {
      $h = @{}
      foreach ($c in [IO.Directory]::EnumerateFileSystemEntries($d)) { $n = [IO.Path]::GetFileName($c); $l = $n.ToLowerInvariant(); if (-not $h.ContainsKey($l)) { $h[$l] = $n } }
      $dirIndex[$d] = $h
    }
    return $dirIndex[$d]
  }
  function New-Alias([string]$dir, [string]$alias, [string]$actual) {
    $p = Join-Path $dir $alias
    if ([IO.File]::Exists($p) -or [IO.Directory]::Exists($p)) { return }
    [void][IO.File]::CreateSymbolicLink($p, $actual)
    $script:aliasCount++
  }
  $script:aliasCount = 0
  # 1. lower-case aliases for every header / lib
  foreach ($root in @($incDirs + $libDirs)) {
    foreach ($f in [IO.Directory]::EnumerateFiles($root, '*', [IO.SearchOption]::AllDirectories)) {
      $n = [IO.Path]::GetFileName($f); $l = $n.ToLowerInvariant()
      if ($l -cne $n) { New-Alias ([IO.Path]::GetDirectoryName($f)) $l $n }
      if ($l.EndsWith('.lib')) {
        # Foo.Lib -> foo.lib already; also UPPERCASE.lib (#pragma comment(lib, "OLDNAMES"), "MSVCRT", ...)
        $stem = [IO.Path]::GetFileNameWithoutExtension($n)
        New-Alias ([IO.Path]::GetDirectoryName($f)) ($stem.ToUpperInvariant() + '.lib') $n
        if ([IO.Path]::GetExtension($n) -cne '.lib') { New-Alias ([IO.Path]::GetDirectoryName($f)) ($stem + '.lib') $n }
      }
    }
  }
  # 2. every #include spelling that does not resolve exactly but does resolve case-insensitively
  $rx = [regex]'(?m)^\s*#\s*include\s*[<"]([^>"]+)[>"]'
  $searchDirs = @($incDirs)
  foreach ($root in $incDirs) {
    foreach ($f in [IO.Directory]::EnumerateFiles($root, '*', [IO.SearchOption]::AllDirectories)) {
      $txt = [IO.File]::ReadAllText($f)
      if ($txt.IndexOf('#') -lt 0) { continue }
      foreach ($m in $rx.Matches($txt)) {
        $inc = $m.Groups[1].Value.Replace('\', '/').Trim()
        if (-not $inc -or $inc.StartsWith('/') -or $inc.Contains('..')) { continue }
        $parts = $inc.Split('/')
        foreach ($base in @([IO.Path]::GetDirectoryName($f)) + $searchDirs) {
          if ([IO.File]::Exists((Join-Path $base $inc))) { break }
          $cur = $base; $ok = $true
          for ($i = 0; $i -lt $parts.Count; $i++) {
            $want = $parts[$i]; $cand = Join-Path $cur $want
            if (-not ([IO.File]::Exists($cand) -or [IO.Directory]::Exists($cand))) {
              $act = (Get-Index $cur)[$want.ToLowerInvariant()]
              if (-not $act) { $ok = $false; break }
              New-Alias $cur $want $act
            }
            $cur = $cand
            if ($i -lt $parts.Count - 1 -and -not [IO.Directory]::Exists($cur)) { $ok = $false; break }
          }
          if ($ok) { break }
        }
      }
    }
  }
  Write-Host ("    case aliases: {0} symlinks in {1:n1}s" -f $script:aliasCount, $sw.Elapsed.TotalSeconds)
  return $script:aliasCount
}

function Install-Portable {
  if (-not (Test-Path $planFile)) { throw "plan file $planFile missing: run the resolve phase first" }
  $plan = Get-Content -Raw $planFile | ConvertFrom-Json
  $sysroot = $plan.installDir
  $marker = Join-Path $sysroot '.setup-msvc.json'
  $kits = Join-Path $sysroot 'Windows Kits/10'
  $cached = $false
  if (Test-Path $marker) {
    $m = Get-Content -Raw $marker | ConvertFrom-Json
    if ($m.key -eq $plan.key) { $cached = $true; Write-Step "Sysroot $sysroot already present ($($plan.key)); skipping downloads" }
  }
  $t = [Diagnostics.Stopwatch]::StartNew()
  if (-not $cached) {
    if (Test-Path $sysroot) { Remove-Item -Recurse -Force $sysroot }
    New-Item -ItemType Directory -Force -Path $sysroot | Out-Null
    $dl = Join-Path $tmpRoot 'setup-msvc-dl'; New-Item -ItemType Directory -Force -Path $dl | Out-Null
    Write-Step "Fetching MSVC CRT $($plan.msvcPackageVersion) ($($plan.arch)) from the Visual Studio manifest"
    $bytes = 0
    foreach ($p in $plan.crt) {
      $vsix = Join-Path $dl "$($p.id).vsix"
      Invoke-Download $p.url $vsix
      if ($p.sha256) {
        $h = (Get-FileHash -Algorithm SHA256 $vsix).Hash
        if ($h -ne $p.sha256.ToUpperInvariant()) { throw "sha256 mismatch for $($p.id): $h != $($p.sha256)" }
      }
      $bytes += (Get-Item $vsix).Length
      $n = Expand-ZipPrefix $vsix 'Contents/VC/' (Join-Path $sysroot 'VC')
      Write-Host "      $($p.id): $n files"
      Remove-Item $vsix -Force
    }
    $msvcTools = Join-Path $sysroot 'VC/Tools/MSVC'
    Get-ChildItem $msvcTools -Recurse -File -Filter *.pdb | Remove-Item -Force
    if (-not (Test-True (Get-In 'DEBUG_LIBS' 'false'))) {
      Get-ChildItem $msvcTools -Recurse -File | Where-Object { $_.Extension -ieq '.lib' -and $_.BaseName -match '^(libcmtd|libcpmtd\d?|libvcruntimed|libconcrtd\d?|msvcrtd|msvcprtd|vcruntimed|concrtd|libompd|vcompd|vcampd|comsuppd|comsuppwd|msvcmrtd.*|ptrustmd)$' } | Remove-Item -Force
    }
    Get-ChildItem $msvcTools -Recurse -Directory | Where-Object { $_.Name -in 'store', 'uwp', 'enclave', 'onecore' } | Sort-Object { $_.FullName.Length } -Descending |
      Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    Write-Step "Fetching Windows SDK $($plan.nugetVersion) from NuGet (Microsoft.Windows.SDK.CPP + .$($plan.arch))"
    foreach ($pkg in @('microsoft.windows.sdk.cpp', "microsoft.windows.sdk.cpp.$($plan.arch)")) {
      $f = Join-Path $dl "$pkg.nupkg"
      Invoke-Download "https://api.nuget.org/v3-flatcontainer/$pkg/$($plan.nugetVersion)/$pkg.$($plan.nugetVersion).nupkg" $f
      $bytes += (Get-Item $f).Length
      if ($pkg -eq 'microsoft.windows.sdk.cpp') {
        $n = Expand-ZipPrefix $f 'c/Include/' (Join-Path $kits 'Include')
        $ver = (Get-ChildItem (Join-Path $kits 'Include') -Directory | Select-Object -First 1).Name
        # SDK tools (rc.exe, mt.exe, ...) of this SDK version only
        if ($IsWindows) { $n += Expand-ZipPrefix $f "c/bin/$ver/" (Join-Path $kits "bin/$ver") }
      } else {
        $n = Expand-ZipPrefix $f 'c/ucrt/' (Join-Path $kits "Lib/$ver/ucrt")
        $n += Expand-ZipPrefix $f 'c/um/' (Join-Path $kits "Lib/$ver/um")
      }
      Write-Host "      ${pkg}: $n files"
      Remove-Item $f -Force
    }
    Remove-Item -Recurse -Force $dl -ErrorAction SilentlyContinue
    Write-Host ("    downloaded {0:n0} MB in {1:n1}s" -f ($bytes / 1MB), $t.Elapsed.TotalSeconds)
  }

  $vcRoot = Get-ChildItem (Join-Path $sysroot 'VC/Tools/MSVC') -Directory | Sort-Object { [version]$_.Name } | Select-Object -Last 1
  $sdkVer = (Get-ChildItem (Join-Path $kits 'Include') -Directory | Sort-Object { [version]$_.Name } | Select-Object -Last 1).Name
  $vc = $vcRoot.FullName
  $a = $plan.arch
  $incDirs = @("$vc/include") + @('ucrt', 'shared', 'um', 'winrt', 'cppwinrt' | ForEach-Object { Join-Path $kits "Include/$sdkVer/$_" }) | Where-Object { Test-Path $_ }
  $libDirs = @("$vc/lib/$a", (Join-Path $kits "Lib/$sdkVer/ucrt/$a"), (Join-Path $kits "Lib/$sdkVer/um/$a"))
  foreach ($l in $libDirs) { if (-not (Test-Path $l)) { throw "library directory missing: $l" } }

  if (-not $cached -and (Test-CaseSensitive $sysroot)) {
    Write-Step 'Case-sensitive file system: creating alias symlinks'
    $aliasInc = @($incDirs | Where-Object { $_ -notmatch '(winrt|cppwinrt)$' })
    [void](New-CaseAliases $sysroot $aliasInc $libDirs)
  }
  if (-not $cached) {
    [ordered]@{ key = $plan.key; msvc = $vcRoot.Name; winsdk = $sdkVer; nuget = $plan.nugetVersion; created = (Get-Date).ToString('o') } |
      ConvertTo-Json | Set-Content -Path $marker -Encoding utf8
  }

  # ---- Swift toolchain wiring (modulemaps + clang.cfg)
  $toolchainBin = $null
  if ($swiftToolchainIn -and $swiftToolchainIn -notin 'none', 'false') {
    if ($swiftToolchainIn -eq 'auto') {
      if ($IsWindows) {
        $sw = Get-Command swift.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sw -and (Test-Path (Join-Path (Split-Path $sw.Source) 'clang.exe'))) { $toolchainBin = Split-Path $sw.Source }
      }
    } else {
      $p = $swiftToolchainIn
      if (Test-Path (Join-Path $p 'usr/bin')) { $p = Join-Path $p 'usr/bin' }
      if (-not (Test-Path $p)) { throw "swift-toolchain '$swiftToolchainIn' does not exist" }
      $toolchainBin = (Resolve-Path $p).Path
    }
  }
  $placed = @()
  if ($toolchainBin) {
    Write-Step "Wiring Swift toolchain $toolchainBin to the portable sysroot"
    $sdkRoot = $env:SDKROOT
    if (-not $sdkRoot -or -not (Test-Path $sdkRoot)) {
      # <root>\Toolchains\<ver>\usr\bin -> <root>\Platforms\*\Windows.platform\Developer\SDKs\Windows.sdk
      $root = Split-Path (Split-Path (Split-Path (Split-Path $toolchainBin)))
      $sdkRoot = Get-ChildItem (Join-Path $root 'Platforms') -Recurse -Directory -Filter 'Windows.sdk' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    }
    $cfgExtra = @()
    if ($sdkRoot -and (Test-Path (Join-Path $sdkRoot 'usr/share')) -and $modulemaps -ne 'none') {
      $inc = Join-Path $kits "Include/$sdkVer"
      foreach ($f in Get-ChildItem (Join-Path $sdkRoot 'usr/share') -File | Where-Object { $_.Extension -in '.modulemap', '.apinotes' }) {
        $n = $f.Name.ToLowerInvariant()
        $dest = switch -regex ($n) {
          '^ucrt\.modulemap$'         { Join-Path $inc 'ucrt/module.modulemap' }
          '^ucrt\.apinotes$'          { Join-Path $inc 'ucrt/ucrt.apinotes' }
          '^vcruntime\.modulemap$'    { Join-Path $vc 'include/module.modulemap' }
          '^vcruntime\.apinotes$'     { Join-Path $vc 'include/vcruntime.apinotes' }
          '^winsdk\.modulemap$'       { Join-Path $inc 'um/module.modulemap' }
          '^winsdk_(\w+)\.modulemap$' { Join-Path $inc "$($Matches[1])/module.modulemap" }
          '^winsdk\.apinotes$'        { Join-Path $inc 'um/WinSDK.apinotes' }
          default                     { $null }
        }
        if ($dest -and (Test-Path (Split-Path $dest))) { $placed += [pscustomobject]@{ src = $f.FullName; dest = $dest } }
      }
      if ($modulemaps -eq 'overlay') {
        $roots = @()
        foreach ($grp in $placed | Group-Object { Split-Path $_.dest }) {
          $roots += [ordered]@{ name = $grp.Name; type = 'directory'
            contents = @($grp.Group | ForEach-Object { [ordered]@{ name = (Split-Path $_.dest -Leaf); type = 'file'; 'external-contents' = $_.src } }) }
        }
        $overlay = Join-Path $sysroot 'swift-modulemaps.vfsoverlay.yaml'
        [ordered]@{ version = 0; 'case-sensitive' = 'false'; roots = $roots } | ConvertTo-Json -Depth 8 | Set-Content -Path $overlay -Encoding ascii
        $cfgExtra += "-ivfsoverlay `"$($overlay.Replace('\', '\\'))`""
        Write-Host "    modulemaps: VFS overlay $overlay ($($placed.Count) files)"
      } else {
        foreach ($pl in $placed) { Copy-Item $pl.src $pl.dest -Force; Write-Host "    $(Split-Path $pl.src -Leaf) -> $($pl.dest)" }
      }
    } else { Write-Host "    (no Swift SDK modulemaps found; SDKROOT=$sdkRoot) - only clang.cfg is written" }
    # clang (and swiftc, which links and imports C through clang) reads <clang dir>/clang.cfg by default.
    # Backslashes must be doubled; forward slashes crash swift-frontend's VFS ("Paths should not contain traversal components").
    # The MSVC STL refuses older clangs (yvals_core.h: STL1000 "expected Clang NN or newer"), e.g. 14.52 needs
    # clang 22 while Swift 6.4's clang is older. C++ interop / C++ targets then fail; allow the mismatch.
    $clangExe = @('clang.exe', 'clang') | ForEach-Object { Join-Path $toolchainBin $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
    $yvals = Join-Path $vc 'include/yvals_core.h'
    if ($clangExe -and (Test-Path $yvals)) {
      $cv = [regex]::Match((& $clangExe --version | Out-String), 'clang version (\d+)')
      $sv = [regex]::Match((Get-Content -Raw $yvals), '__clang_major__\s*<\s*(\d+)')
      if ($cv.Success -and $sv.Success -and [int]$cv.Groups[1].Value -lt [int]$sv.Groups[1].Value) {
        Write-Host "::warning title=setup-msvc::MSVC STL $($vcRoot.Name) expects clang $($sv.Groups[1].Value)+, the Swift toolchain has clang $($cv.Groups[1].Value): adding -D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH to clang.cfg (or pick an older msvc-version, e.g. 14.44)"
        $cfgExtra += '-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH'
        Set-Out 'stl-mismatch' 'true'
      }
    }
    $sysNative = [IO.Path]::GetFullPath($sysroot)
    if ($IsWindows) { $sysNative = $sysNative.Replace('/', '\') }
    foreach ($cfg in 'clang.cfg', 'clang++.cfg') {
      $cfgPath = Join-Path $toolchainBin $cfg
      Set-Content -Path $cfgPath -Encoding ascii -Value (@(
        '# written by setup-msvc (portable mode): use lld and the portable MSVC CRT / Windows SDK sysroot',
        '-fuse-ld=lld',
        "-Xmicrosoft-windows-sys-root `"$($sysNative.Replace('\', '\\'))`"") + $cfgExtra)
      Write-Host "    wrote $cfgPath"
    }
    Set-Out 'swift-toolchain' $toolchainBin
  }

  # ---- environment (vcvars equivalent)
  $sep = ';'   # clang-cl (INCLUDE) and lld-link (LIB) split on ';' on every host OS
  $nat = { param($p) if ($IsWindows) { $p.Replace('/', '\') } else { $p } }
  $kitsN = & $nat $kits; $vcN = & $nat $vc; $sysN = & $nat $sysroot
  $ds = [IO.Path]::DirectorySeparatorChar
  $hostArchP = $plan.hostArch
  Write-Step 'Exporting the vcvars-style environment'
  Export-Var 'INCLUDE' (($incDirs | ForEach-Object { & $nat $_ }) -join $sep)
  Export-Var 'EXTERNAL_INCLUDE' (($incDirs | ForEach-Object { & $nat $_ }) -join $sep)
  Export-Var 'LIB' (($libDirs | ForEach-Object { & $nat $_ }) -join $sep)
  Export-Var 'LIBPATH' (& $nat "$vc/lib/$a")
  Export-Var 'VCINSTALLDIR' (& $nat "$sysroot/VC$ds")
  Export-Var 'VCToolsInstallDir' "$vcN$ds"
  Export-Var 'VCToolsVersion' $vcRoot.Name
  Export-Var 'WindowsSdkDir' "$kitsN$ds"
  Export-Var 'WindowsSDKVersion' "$sdkVer$ds"
  Export-Var 'WindowsSDKLibVersion' "$sdkVer$ds"
  Export-Var 'UniversalCRTSdkDir' "$kitsN$ds"
  Export-Var 'UCRTVersion' $sdkVer
  Export-Var 'VSCMD_ARG_TGT_ARCH' $a
  Export-Var 'VSCMD_ARG_HOST_ARCH' $hostArchP
  Export-Var 'WINSYSROOT' $sysN
  if ($IsWindows) {
    $sdkBin = Join-Path $kits "bin/$sdkVer/$hostArchP"
    foreach ($cand in "bin/$hostArchP", "bin/$sdkVer/$a", "bin/$a") { if (-not (Test-Path $sdkBin)) { $sdkBin = Join-Path $kits $cand } }
    if (Test-Path $sdkBin) { Add-ToPath (& $nat $sdkBin); Export-Var 'WindowsSdkBinPath' ((& $nat (Join-Path $kits 'bin')) + $ds); Export-Var 'WindowsSdkVerBinPath' ((& $nat (Split-Path $sdkBin)) + $ds) }
  }
  if ($exportCc -and $exportCc -notin 'false', 'none', 'no') {
    $cc = $null
    if ($exportCc -in 'true', 'clang-cl') {
      if ($toolchainBin -and (Test-Path (Join-Path $toolchainBin 'clang-cl.exe'))) { $cc = Join-Path $toolchainBin 'clang-cl.exe' }
      elseif (Get-Command clang-cl -ErrorAction SilentlyContinue) { $cc = (Get-Command clang-cl | Select-Object -First 1).Source }
      else { throw 'export-cc: clang-cl not found (set swift-toolchain or put clang-cl on PATH)' }
    } else { $cc = $exportCc }
    Export-Var 'CC' $cc; Export-Var 'CXX' $cc
  }
  if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content $env:GITHUB_STEP_SUMMARY -Value "setup-msvc: **portable** MSVC CRT $($vcRoot.Name) + Windows SDK $sdkVer (NuGet $($plan.nugetVersion)) for $a at ``$sysN``$(if ($cached) { ' (reused)' })"
  }
  # activation scripts for local use
  $ps = @('# generated by setup-msvc: dot-source this file')
  foreach ($k in $script:exported.Keys) { $ps += ('$env:{0} = ''{1}''' -f $k, ($script:exported[$k] -replace "'", "''")) }
  foreach ($p in $script:pathAdded) { $ps += ('$env:PATH = ''{0}'' + [IO.Path]::PathSeparator + $env:PATH' -f $p) }
  Set-Content -Path (Join-Path $sysroot 'activate.ps1') -Value $ps -Encoding utf8

  Set-Out 'mode' 'portable'
  Set-Out 'sysroot' $sysN
  Set-Out 'install-dir' $sysN
  Set-Out 'msvc-version' $vcRoot.Name
  Set-Out 'winsdk-version' $sdkVer
  Set-Out 'vc-tools-dir' $vcN
  Set-Out 'winsdk-dir' $kitsN
  Set-Out 'vs-install-path' ''
  Set-Out 'cache-hit' $(if ($cached) { 'true' } else { 'false' })
}

# ------------------------------------------------------------------------------------------------ main
Write-Host "setup-msvc: host $hostOs/$hostArch, target $arch, mode $mode, msvc $msvcVersion, winsdk $(if ($winsdk) { $winsdk } else { 'latest' })"
if ($Phase -in 'resolve', 'all') {
  if (Test-Path $planFile) { Remove-Item $planFile -Force }
  $chosen = $mode
  if (-not $IsWindows) {
    if ($mode -eq 'installed') { throw "mode 'installed' needs a Windows host" }
    $chosen = 'portable'
  } elseif ($mode -in 'auto', 'installed') {
    $vs = Find-InstalledVS
    if ($vs.ok) { $chosen = 'installed' }
    elseif ($mode -eq 'installed') { throw "no suitable Visual Studio installation: $($vs.reason)" }
    else { Write-Host "::notice title=setup-msvc::No suitable Visual Studio ($($vs.reason)); using portable mode"; $chosen = 'portable' }
  }
  if ($chosen -eq 'installed') { Invoke-InstalledMode $vs } else { Resolve-Portable }
}
if ($Phase -in 'install', 'all') {
  if ($Phase -eq 'all' -and -not (Test-Path $planFile)) { return }   # installed mode: nothing left to do
  Install-Portable
}
