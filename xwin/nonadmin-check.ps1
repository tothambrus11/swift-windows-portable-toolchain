# Runs the whole portable setup + a SwiftPM build/run/test as a NON-elevated process.
# CI: launched via `PsExec64 -l` (restricted token: Administrators group = deny-only, medium integrity).
param([string]$Root, [string]$Log)
$ErrorActionPreference = 'Stop'
Start-Transcript -Path $Log -Force | Out-Null
try {
  Write-Host '== token'
  whoami /groups | Select-String 'Mandatory Label|BUILTIN\\Administrators' | ForEach-Object { Write-Host $_ }
  try { New-Item -ItemType File -Path "$env:SystemRoot\nonadmin-probe.txt" -ErrorAction Stop | Out-Null; Write-Host 'WARNING: could write to %SystemRoot% (process is still elevated)'; Remove-Item "$env:SystemRoot\nonadmin-probe.txt" }
  catch { Write-Host 'OK: cannot write to %SystemRoot% -> not elevated' }

  . (Join-Path $PSScriptRoot 'clean-env.ps1')
  # Start-Process -Credential inherits the *caller's* environment: point the per-user dirs at this user's profile
  # (GetFolderPath still resolves to the caller's profile here, so use directories next to -Root)
  $base = Split-Path $Root
  $env:USERPROFILE = Join-Path $base 'home'
  $env:LOCALAPPDATA = Join-Path $base 'home\AppData\Local'
  $env:APPDATA = Join-Path $base 'home\AppData\Roaming'
  $env:TEMP = $env:TMP = Join-Path $base 'home\AppData\Local\Temp'
  foreach ($d in $env:LOCALAPPDATA, $env:APPDATA, $env:TEMP) { New-Item -ItemType Directory -Force $d | Out-Null }
  Write-Host "user=$(whoami) LOCALAPPDATA=$env:LOCALAPPDATA TEMP=$env:TEMP"
  & (Join-Path $PSScriptRoot 'setup-portable-swift.ps1') -Target $Root -AcceptLicense
  . (Join-Path $Root 'activate.ps1')
  $w = Join-Path $env:TEMP 'nonadmin-pkg'
  if (Test-Path $w) { Remove-Item -Recurse -Force $w }
  Copy-Item -Recurse (Join-Path $PSScriptRoot 'tests\swiftpkg') $w
  Set-Location $w
  swift run FoundationDemo; if ($LASTEXITCODE -ne 0) { throw 'swift run failed' }
  swift test; if ($LASTEXITCODE -ne 0) { throw 'swift test failed' }
  Write-Host 'NONADMIN OK'
  $rc = 0
} catch {
  Write-Host "NONADMIN FAILED: $_"
  $rc = 1
}
Stop-Transcript | Out-Null
Set-Content -Path "$Log.done" -Value $rc
exit $rc
