<#
.SYNOPSIS
  Generates the Scoop bucket manifests (bucket\*.json) from src\*.ps1.

  build-bucket.ps1 [-ScriptUrl <url of setup-portable-swift.ps1>] [-OutDir <dir>]

  The manifests download managers/common/setup-portable-swift.ps1 by URL (pinned by its sha256), so a
  real bucket would point at a tagged release of it. CI points them at the commit under test.
#>
param(
  [string]$ScriptUrl = 'https://raw.githubusercontent.com/tothambrus11/swift-windows-portable-toolchain/exp/managers/managers/common/setup-portable-swift.ps1',
  [string]$ScriptPath = (Join-Path $PSScriptRoot '..\common\setup-portable-swift.ps1'),
  [string]$OutDir = (Join-Path $PSScriptRoot 'bucket'),
  [string]$SwiftVersion = '6.4.3',
  [string]$SdkVersion = '10.0.28000.2957',
  [string]$Repo = 'tothambrus11/swift-windows-portable-toolchain'
)
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot 'src'
function Get-Lines([string]$file, [string[]]$prefix = @()) {
  # Comment lines are dropped to keep the manifests readable
  # [string] casts drop Get-Content's ETS properties (PSPath, PSProvider, ...), which ConvertTo-Json would serialize
  [string[]](@($prefix) + @([System.IO.File]::ReadAllLines((Join-Path $src $file)) | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }))
}
# Line endings must not matter: Scoop hashes the bytes it downloads, and Git may check the file out with CRLF
$lf = [System.Text.Encoding]::UTF8.GetBytes([System.IO.File]::ReadAllText($ScriptPath).Replace("`r`n", "`n"))
$scriptHash = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($lf)) -replace '-', '').ToLowerInvariant()
New-Item -ItemType Directory -Force $OutDir | Out-Null

$licenseNote = @(
  'The MSVC C/C++ runtime and the Windows SDK are Microsoft software. msvc-sysroot downloads them from Microsoft',
  '(Visual Studio channel manifest, nuget.org) on this machine, after you accept their license terms:',
  '  https://go.microsoft.com/fwlink/?LinkId=2179911 (Visual Studio Build Tools) and https://aka.ms/WinSDKLicenseURL',
  'Accept interactively, or set SWIFT_PORTABLE_ACCEPT_MSVC_LICENSE=1 before `scoop install`.',
  'With Visual Studio (VC tools) installed, nothing is downloaded and VS is used (SWIFT_PORTABLE_MSVC=portable overrides).'
)

$sysroot = [ordered]@{
  version     = $SdkVersion
  description = 'MSVC C/C++ runtime + Windows SDK headers and libraries, fetched from Microsoft after license acceptance (for Swift/clang without Visual Studio)'
  homepage    = "https://github.com/$Repo"
  license     = [ordered]@{ identifier = 'Proprietary'; url = 'https://aka.ms/WinSDKLicenseURL' }
  notes       = $licenseNote
  url         = $ScriptUrl
  hash        = $scriptHash
  installer   = [ordered]@{ script = Get-Lines 'msvc-sysroot.installer.ps1' }
  post_install = Get-Lines 'msvc-sysroot.post_install.ps1'
  checkver    = [ordered]@{
    url      = 'https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.cpp/index.json'
    script   = @('$v = (Invoke-RestMethod ''https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.cpp/index.json'').versions | Where-Object { $_ -match ''^\d+\.\d+\.\d+\.\d+$'' }', 'return @($v)[-1]')
    regex    = '([\d.]+)'
  }
  autoupdate  = [ordered]@{ url = $ScriptUrl }
}

function New-SwiftManifest([string]$source) {
  $m = [ordered]@{
    version     = $SwiftVersion
    description = "Swift toolchain for Windows without Visual Studio ($(if ($source -eq 'prebuilt') { 'repackaged swift.org no-asserts build, Swift-only archive' } else { 'official swift.org installer, unpacked without running it' }))"
    homepage    = "https://github.com/$Repo"
    license     = 'Apache-2.0'
    depends     = 'msvc-sysroot'
    notes       = @('Swift links through the shared msvc-sysroot app (or an installed Visual Studio).',
                    'Run `scoop reset swift-portable@<version>` to switch between installed Swift versions.')
  }
  $arch = [ordered]@{}
  foreach ($a in @(@{ k = '64bit'; n = 'x64'; s = ''; h = 'a4f1369833f77de28dbac998c8debe1c1d6044410dc6380238ae61a0d7ce5f77'; p = '99934abc33c978d6550e0750b45b5b4bd3636c9c1cd3aa197b4e0943769d1444' },
                   @{ k = 'arm64'; n = 'arm64'; s = '-arm64'; h = 'ef45204347252878d867549171ad54cb95f26996dbcd3b881a95809b55b914e3'; p = '73e9f0c1fffc67bf1273255dcd988494ac6c2303b94aaabdd8dcdadd7410475f' })) {
    $u = if ($source -eq 'prebuilt') {
      "https://github.com/$Repo/releases/download/swift-$SwiftVersion-portable.0/swift-$SwiftVersion-windows-$($a.n)-portable.tar.xz#/swift-toolchain.archive"
    } else {
      "https://download.swift.org/swift-$SwiftVersion-release/windows10$($a.s)/swift-$SwiftVersion-RELEASE/swift-$SwiftVersion-RELEASE-windows10$($a.s).exe#/swift-installer.exe"
    }
    $arch[$a.k] = [ordered]@{ url = @($u, $ScriptUrl); hash = @($(if ($source -eq 'prebuilt') { $a.p } else { $a.h }), $scriptHash) }
  }
  $m.architecture = $arch
  $m.installer = [ordered]@{ script = Get-Lines 'swift-portable.installer.ps1' -prefix @("`$spSource = '$source'") }
  $m.env_add_path = @('Swift\Toolchains\current\usr\bin', 'Swift\Runtimes\current\usr\bin')
  $m.env_set = [ordered]@{ SDKROOT = '$dir\Swift\Platforms\current\Windows.platform\Developer\SDKs\Windows.sdk\' }
  if ($source -eq 'prebuilt') {
    $m.checkver = [ordered]@{ github = "https://github.com/$Repo"; regex = 'swift-([\d.]+)-portable\.0' }
    $au = [ordered]@{}
    foreach ($a in @(@{ k = '64bit'; n = 'x64' }, @{ k = 'arm64'; n = 'arm64' })) {
      $au[$a.k] = [ordered]@{ url = @("https://github.com/$Repo/releases/download/swift-`$version-portable.0/swift-`$version-windows-$($a.n)-portable.tar.xz#/swift-toolchain.archive", $ScriptUrl) }
    }
    $m.autoupdate = [ordered]@{ architecture = $au; hash = [ordered]@{ url = '$url.sha256' } }
  } else {
    $m.checkver = [ordered]@{ github = 'https://github.com/swiftlang/swift'; regex = 'swift-([\d.]+)-RELEASE' }
    $m.autoupdate = [ordered]@{ architecture = [ordered]@{
      '64bit' = [ordered]@{ url = @('https://download.swift.org/swift-$version-release/windows10/swift-$version-RELEASE/swift-$version-RELEASE-windows10.exe#/swift-installer.exe', $ScriptUrl) }
      arm64   = [ordered]@{ url = @('https://download.swift.org/swift-$version-release/windows10-arm64/swift-$version-RELEASE/swift-$version-RELEASE-windows10-arm64.exe#/swift-installer.exe', $ScriptUrl) } } }
  }
  return $m
}

$out = @{ 'msvc-sysroot' = $sysroot; 'swift-portable' = (New-SwiftManifest 'prebuilt'); 'swift-portable-official' = (New-SwiftManifest 'official') }
foreach ($name in $out.Keys) {
  $json = $out[$name] | ConvertTo-Json -Depth 10
  # Windows PowerShell 5.1 escapes these needlessly
  foreach ($c in "'", '<', '>', '&') { $json = $json.Replace(('\u{0:x4}' -f [int][char]$c), $c) }
  [System.IO.File]::WriteAllText((Join-Path $OutDir "$name.json"), $json.Replace("`r`n", "`n") + "`n")
  Write-Host "wrote $OutDir\$name.json"
}
