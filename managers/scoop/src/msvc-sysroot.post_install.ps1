# Scoop post_install of msvc-sysroot: point every installed swift-portable version at the (new) shared
# sysroot. Its clang.cfg / modulemap overlay reference versioned paths inside the sysroot.
$spApps = Split-Path (Split-Path $dir)
$spSys = "$spApps\msvc-sysroot\current\winsysroot"
$spPs = (Get-Process -Id $PID).Path
$spKind = (Get-Content -Raw "$spSys\sysroot.json" | ConvertFrom-Json).kind
foreach ($spApp in 'swift-portable', 'swift-portable-official') {
    Get-ChildItem "$spApps\$spApp" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'current' -and (Test-Path "$($_.FullName)\Swift\Toolchains") } | ForEach-Object {
            $spPart = if ($spKind -eq 'portable') { 'link' } else { 'env' }
            Write-Host "msvc-sysroot: re-configuring $spApp $($_.Name) for the new sysroot ($spKind)"
            if ($spKind -ne 'portable') { Remove-Item "$($_.FullName)\Swift\Toolchains\current\usr\bin\clang*.cfg" -ErrorAction SilentlyContinue }
            & $spPs -NoProfile -ExecutionPolicy Bypass -File "$dir\$fname" -Part $spPart -Target $_.FullName -SysrootDir $spSys | Out-Null
        }
}
