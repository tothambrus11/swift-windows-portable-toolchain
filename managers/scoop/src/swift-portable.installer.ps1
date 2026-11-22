# Scoop installer.script of swift-portable / swift-portable-official ($dir, $version, $architecture are set).
# $spSource ('prebuilt' or 'official') is prepended by build-bucket.ps1.
$spArch = if ($architecture -eq 'arm64') { 'arm64' } else { 'x64' }
$spPs = (Get-Process -Id $PID).Path
$spScript = "$dir\setup-portable-swift.ps1"
if ($spSource -eq 'prebuilt') {
    # Swift-only archive (no Microsoft files). The in-box bsdtar keeps its hard links (7-Zip would not).
    & "$env:SystemRoot\System32\tar.exe" -xf "$dir\swift-toolchain.archive" -C $dir --strip-components=1
    if ($LASTEXITCODE) { throw "swift-portable: extracting the toolchain archive failed (exit $LASTEXITCODE)" }
    Remove-Item "$dir\swift-toolchain.archive"
} else {
    # The official swift.org installer bundle (hash-checked by Scoop), unpacked without running it
    # -NoAsserts: the asserts toolchain trips an LLVM VFS assertion when used through Scoop's `current` junction
    & $spPs -NoProfile -ExecutionPolicy Bypass -File $spScript -Part swift -NoAsserts -Target $dir -SwiftVersion $version -Arch $spArch -InstallerPath "$dir\swift-installer.exe"
    if ($LASTEXITCODE) { throw "swift-portable: unpacking the swift.org installer failed (exit $LASTEXITCODE)" }
}
# Version-free directory names, so that the manifest's env_add_path / env_set are static
foreach ($spSub in 'Toolchains', 'Runtimes', 'Platforms') {
    $spD = @(Get-ChildItem "$dir\Swift\$spSub" -Directory)
    if ($spD.Count -ne 1) { throw "swift-portable: expected one directory in Swift\$spSub, found $($spD.Count)" }
    if ($spD[0].Name -ne 'current') { Rename-Item $spD[0].FullName 'current' }
}
# Use the shared MSVC/WinSDK sysroot of the msvc-sysroot app (a dependency), or the installed Visual Studio
$spSys = "$(Split-Path (Split-Path $dir))\msvc-sysroot\current\winsysroot"
$spKind = if (Test-Path "$spSys\sysroot.json") { (Get-Content -Raw "$spSys\sysroot.json" | ConvertFrom-Json).kind } else { 'none' }
$spPart = if ($spKind -eq 'portable') { 'link' } else { 'env' }
& $spPs -NoProfile -ExecutionPolicy Bypass -File $spScript -Part $spPart -Target $dir -SysrootDir $spSys
if ($LASTEXITCODE) { throw "swift-portable: configuring the toolchain failed (exit $LASTEXITCODE)" }
Write-Host "swift-portable: MSVC/Windows SDK: $(if ($spKind -eq 'portable') { "portable sysroot $spSys" } elseif ($spKind -eq 'vs') { 'installed Visual Studio' } else { 'none (install msvc-sysroot)' })"
