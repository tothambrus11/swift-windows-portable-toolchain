<#
.SYNOPSIS
  One-line installer for a portable, Visual-Studio-free Swift toolchain (rustup-style baseline).

    # interactive (asks for the Microsoft license terms when no Visual Studio is found):
    irm https://<host>/install.ps1 | iex
    # unattended:
    & ([scriptblock]::Create((irm https://<host>/install.ps1))) -SwiftVersion 6.4.3 -AcceptMsvcLicense

  Layout (per user, no admin):
    %LOCALAPPDATA%\swift-portable\toolchains\<version>\   Swift (prebuilt Swift-only archive, or -Source official)
    %LOCALAPPDATA%\swift-portable\msvc-sysroot-<arch>\    MSVC CRT + Windows SDK, shared by all Swift versions
  The selected version goes onto the user PATH and SDKROOT (HKCU\Environment); re-run with another
  -SwiftVersion to install/switch, -List to list installed versions.
#>
[CmdletBinding()]
param(
  [string]$SwiftVersion = '',
  [ValidateSet('prebuilt', 'official')][string]$Source = 'prebuilt',
  [switch]$AcceptMsvcLicense,
  # auto: use an installed Visual Studio if found; portable: always the portable sysroot; system: never download it
  [ValidateSet('auto', 'portable', 'system')][string]$Msvc = 'auto',
  [string]$Root = (Join-Path $env:LOCALAPPDATA 'swift-portable'),
  # Where setup-portable-swift.ps1 comes from (a release asset in a real distribution)
  [string]$ScriptUrl = 'https://raw.githubusercontent.com/tothambrus11/swift-windows-portable-toolchain/exp/managers/managers/common/setup-portable-swift.ps1',
  [string]$Repo = 'tothambrus11/swift-windows-portable-toolchain',
  [switch]$NoModifyPath,
  [switch]$List
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($List) { Get-ChildItem (Join-Path $Root 'toolchains') -Directory -ErrorAction SilentlyContinue | ForEach-Object Name; return }

$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'x64' }
if (-not $SwiftVersion) { $SwiftVersion = (Invoke-RestMethod 'https://www.swift.org/api/v1/install/releases.json')[-1].name }
if ("$env:SWIFT_PORTABLE_ACCEPT_MSVC_LICENSE" -match '^(1|true|yes)$') { $AcceptMsvcLicense = $true }
$ps = (Get-Process -Id $PID).Path

# 1. decide about the Microsoft part before downloading anything
$vs = $null
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if ($Msvc -eq 'auto' -and (Test-Path $vswhere)) {
  $comp = if ($arch -eq 'arm64') { 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' } else { 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' }
  $vs = & $vswhere -latest -products * -requires $comp -property installationPath
}
$sysroot = Join-Path $Root "msvc-sysroot-$arch"
$needSysroot = $Msvc -ne 'system' -and -not $vs
if ($needSysroot -and -not (Test-Path "$sysroot\sysroot.json") -and -not $AcceptMsvcLicense) {
  Write-Host 'No Visual Studio found. Swift needs the Microsoft C/C++ runtime and Windows SDK to link programs.' -ForegroundColor Yellow
  Write-Host 'They are downloaded from Microsoft onto this machine, under these license terms:'
  Write-Host '  - MSVC C/C++ runtime (Visual Studio Build Tools license): https://go.microsoft.com/fwlink/?LinkId=2179911'
  Write-Host '  - Windows SDK: https://aka.ms/WinSDKLicenseURL'
  if (-not $env:CI -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    $AcceptMsvcLicense = (Read-Host 'Do you accept these license terms? [y/N]') -match '^(y|yes)$'
  }
  if (-not $AcceptMsvcLicense) {
    throw 'License terms not accepted; nothing was downloaded. Re-run with -AcceptMsvcLicense (or SWIFT_PORTABLE_ACCEPT_MSVC_LICENSE=1), or -Msvc system to install Swift alone.'
  }
}

# 2. the setup script
New-Item -ItemType Directory -Force (Join-Path $Root 'toolchains') | Out-Null
$script = Join-Path $Root 'setup-portable-swift.ps1'
Write-Host "==> setup script: $ScriptUrl"
Invoke-WebRequest -UseBasicParsing $ScriptUrl -OutFile $script
function Invoke-Setup([string[]]$a) {
  & $ps -NoProfile -ExecutionPolicy Bypass -File $script @a
  if ($LASTEXITCODE) { throw "setup-portable-swift.ps1 $($a -join ' ') failed (exit $LASTEXITCODE)" }
}

# 3. Swift
$tc = Join-Path $Root "toolchains\$SwiftVersion"
if (Test-Path "$tc\mise-env.json") {
  Write-Host "==> Swift $SwiftVersion is already installed in $tc"
} else {
  $a = @('-Part', 'swift', '-Target', $tc, '-SwiftVersion', $SwiftVersion, '-Arch', $arch)
  if ($Source -eq 'prebuilt') {
    $tag = "swift-$SwiftVersion-portable.0"; $name = "swift-$SwiftVersion-windows-$arch-portable.tar.xz"
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/tags/$tag"
    $asset = $rel.assets | Where-Object name -eq $name
    if (-not $asset) { throw "no prebuilt $name in $Repo release $tag; use -Source official" }
    $a += @('-PrebuiltUrl', $asset.browser_download_url, '-PrebuiltSha256', ($asset.digest -replace '^sha256:', ''))
  }
  Invoke-Setup $a
}

# 4. shared sysroot + link (or use Visual Studio)
if ($needSysroot) {
  if (-not (Test-Path "$sysroot\sysroot.json")) {
    $tmp = Join-Path $Root 'tmp'   # downloads; not inside the sysroot, which the fetch recreates
    Invoke-Setup @('-Part', 'fetch-sysroot', '-Target', $tmp, '-SysrootDir', $sysroot, '-Arch', $arch, '-AcceptLicense')
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
  Invoke-Setup @('-Part', 'link', '-Target', $tc, '-SysrootDir', $sysroot)
} else {
  Write-Host "==> $(if ($vs) { "using the installed Visual Studio at $vs" } else { 'no MSVC/Windows SDK set up (-Msvc system)' })"
  Remove-Item "$tc\Swift\Toolchains\*\usr\bin\clang*.cfg" -ErrorAction SilentlyContinue
  Invoke-Setup @('-Part', 'env', '-Target', $tc)
}

# 5. select it: user PATH + SDKROOT (the other variables are not needed: clang.cfg points clang at the sysroot)
$envj = Get-Content -Raw "$tc\mise-env.json" | ConvertFrom-Json
if (-not $NoModifyPath) {
  # Edit the raw REG_EXPAND_SZ value: [Environment]::SetEnvironmentVariable(.., 'User') would store it as REG_SZ and
  # leave entries like %USERPROFILE%\.dotnet\tools unexpanded, i.e. relative - which makes the asserts toolchain's
  # swift-frontend assert ("virtual path not absolute").
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
  $mine = [regex]::Escape((Join-Path $Root 'toolchains') + '\')
  $userPath = @(("$($key.GetValue('Path', '', 'DoNotExpandEnvironmentNames'))" -split ';') | Where-Object { $_ -and $_ -notmatch "^$mine" })
  $key.SetValue('Path', ((@($envj.path) + $userPath) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
  $key.SetValue('SDKROOT', $envj.env.SDKROOT, [Microsoft.Win32.RegistryValueKind]::String)
  $key.Close()
  # tell Explorer & co. that the environment changed (a no-op SetEnvironmentVariable broadcasts WM_SETTINGCHANGE)
  [Environment]::SetEnvironmentVariable('SWIFT_PORTABLE_ROOT', $Root, 'User')
  $env:Path = (@($envj.path) -join ';') + ';' + $env:Path; $env:SDKROOT = $envj.env.SDKROOT
  Write-Host "==> Swift $SwiftVersion selected (user PATH + SDKROOT). Open a new terminal, then: swift --version" -ForegroundColor Green
} else {
  Write-Host "==> installed; activate with: . '$tc\activate.ps1'"
}
