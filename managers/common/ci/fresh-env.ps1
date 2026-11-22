# Dot-source: the environment a newly opened terminal would get after a user-level install.
# clean-env.ps1's minimal machine PATH (VS-related variables removed) + everything persisted in
# HKCU\Environment (user PATH appended, other user variables set) - what Scoop/the bootstrapper wrote.
. (Join-Path $PSScriptRoot 'clean-env.ps1')
$k = Get-Item 'HKCU:\Environment'
foreach ($n in $k.GetValueNames()) {
  if ($n -in 'Path', 'TEMP', 'TMP') { continue }
  Set-Item "env:$n" ([Environment]::GetEnvironmentVariable($n, 'User'))
}
$env:Path = $env:Path + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
Write-Host "fresh env: PATH=$env:Path"
Write-Host "fresh env: SDKROOT=$env:SDKROOT INCLUDE=$env:INCLUDE LIB=$env:LIB"
