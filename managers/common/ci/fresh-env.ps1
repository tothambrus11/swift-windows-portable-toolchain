# Dot-source: the environment a newly opened terminal would get after a user-level install.
# clean-env.ps1's minimal machine PATH (VS-related variables removed) + everything persisted in
# HKCU\Environment (user PATH appended, other user variables set) - what Scoop/the bootstrapper/vfox wrote.
# Like Explorer, REG_EXPAND_SZ values are expanded and REG_SZ values are taken literally: an installer that
# rewrites the user PATH as REG_SZ leaves entries such as %USERPROFILE%\.dotnet\tools unexpanded (relative).
. (Join-Path $PSScriptRoot 'clean-env.ps1')
$k = Get-Item 'HKCU:\Environment'
function Get-UserVar([string]$n) {
  $raw = $k.GetValue($n, '', 'DoNotExpandEnvironmentNames')
  if ($k.GetValueKind($n) -eq 'ExpandString') { [Environment]::ExpandEnvironmentVariables($raw) } else { $raw }
}
foreach ($n in $k.GetValueNames()) {
  if ($n -in 'Path', 'TEMP', 'TMP') { continue }
  Set-Item "env:$n" (Get-UserVar $n)
}
$env:Path = $env:Path + ';' + (Get-UserVar 'Path')
Write-Host "fresh env: user Path is $($k.GetValueKind('Path')); PATH=$env:Path"
Write-Host "fresh env: SDKROOT=$env:SDKROOT INCLUDE=$env:INCLUDE LIB=$env:LIB"
