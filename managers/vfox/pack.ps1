# Packs the vfox plugin (managers/vfox/swift + managers/common/setup-portable-swift.ps1) into a zip that
# `vfox add --source <zip>` and `mise plugins install` accept. Usage: pack.ps1 [-Out <zip>]
param([string]$Out = (Join-Path $PSScriptRoot 'swift-vfox-plugin.zip'))
$ErrorActionPreference = 'Stop'
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ('vfox-swift-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
Copy-Item -Recurse (Join-Path $PSScriptRoot 'swift') $stage
New-Item -ItemType Directory -Force (Join-Path $stage 'scripts') | Out-Null
Copy-Item (Join-Path $PSScriptRoot '..\common\setup-portable-swift.ps1') (Join-Path $stage 'scripts')
if (Test-Path $Out) { Remove-Item -Force $Out }
# bsdtar writes forward-slash entry names (Windows PowerShell's Compress-Archive writes backslashes)
& "$env:SystemRoot\System32\tar.exe" -a -cf $Out -C $stage metadata.lua hooks lib scripts
if ($LASTEXITCODE) { throw 'packing failed' }
Remove-Item -Recurse -Force $stage
Write-Host "packed $Out"
