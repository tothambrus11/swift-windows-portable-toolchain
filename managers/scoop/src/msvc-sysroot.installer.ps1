# Scoop installer.script of msvc-sysroot (runs inside Scoop: $dir, $version, $architecture, $fname are set).
# Fetches the MSVC C/C++ runtime + Windows SDK from Microsoft into $dir\winsysroot, only after the user
# accepted Microsoft's license terms. Nothing from Microsoft is part of the bucket or of any download URL.
$spArch = if ($architecture -eq 'arm64') { 'arm64' } else { 'x64' }
$spPs = (Get-Process -Id $PID).Path
$spSys = "$dir\winsysroot"
$spMode = if ($env:SWIFT_PORTABLE_MSVC) { $env:SWIFT_PORTABLE_MSVC } else { 'auto' }
$spVs = $null
$spVswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if ($spMode -eq 'auto' -and (Test-Path $spVswhere)) {
    $spComp = if ($spArch -eq 'arm64') { 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' } else { 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' }
    $spVs = & $spVswhere -latest -products * -requires $spComp -property installationPath
}
if ($spVs) {
    New-Item -ItemType Directory -Force $spSys | Out-Null
    [System.IO.File]::WriteAllText("$spSys\sysroot.json", (@{ kind = 'vs'; path = "$spVs" } | ConvertTo-Json))
    Write-Host "msvc-sysroot: using the installed Visual Studio at $spVs - nothing is downloaded from Microsoft." -ForegroundColor Green
    Write-Host 'msvc-sysroot: (set SWIFT_PORTABLE_MSVC=portable and reinstall to use the portable sysroot anyway)'
} else {
    $spOk = "$env:SWIFT_PORTABLE_ACCEPT_MSVC_LICENSE" -match '^(1|true|yes|y)$'
    if (-not $spOk) {
        Write-Host ''
        Write-Host 'msvc-sysroot downloads Microsoft software from Microsoft onto this machine:' -ForegroundColor Yellow
        Write-Host '  - MSVC C/C++ runtime headers and libraries (Visual Studio Build Tools license):'
        Write-Host '      https://go.microsoft.com/fwlink/?LinkId=2179911'
        Write-Host '  - Windows SDK headers and import libraries (Windows SDK license):'
        Write-Host '      https://aka.ms/WinSDKLicenseURL'
        Write-Host ''
        if (-not $env:CI -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
            $spOk = (Read-Host 'Do you accept these license terms? [y/N]') -match '^(y|yes)$'
        }
    }
    if (-not $spOk) {
        throw ('msvc-sysroot: the Microsoft license terms were not accepted, nothing was downloaded. ' +
            'To accept them non-interactively set SWIFT_PORTABLE_ACCEPT_MSVC_LICENSE=1, then run: scoop install msvc-sysroot')
    }
    & $spPs -NoProfile -ExecutionPolicy Bypass -File "$dir\$fname" -Part fetch-sysroot -Target $dir -SysrootDir $spSys -Arch $spArch -NugetSdkVersion $version -AcceptLicense
    if ($LASTEXITCODE) { throw "msvc-sysroot: fetching the MSVC runtime / Windows SDK failed (exit $LASTEXITCODE)" }
}
