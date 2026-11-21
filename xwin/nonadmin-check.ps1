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
  & (Join-Path $PSScriptRoot 'setup-portable-swift.ps1') -Target $Root -AcceptLicense
  . (Join-Path $Root 'activate.ps1')
  $w = Join-Path $env:TEMP 'nonadmin-pkg'
  if (Test-Path $w) { Remove-Item -Recurse -Force $w }
  Copy-Item -Recurse (Join-Path $PSScriptRoot 'tests\swiftpkg') $w
  Set-Location $w
  swift run FoundationDemo; if ($LASTEXITCODE -ne 0) { throw 'swift run failed' }
  swift test; if ($LASTEXITCODE -ne 0) { throw 'swift test failed' }
  Write-Host 'NONADMIN OK'
} catch {
  Write-Host "NONADMIN FAILED: $_"
  Stop-Transcript | Out-Null
  exit 1
}
Stop-Transcript | Out-Null
exit 0
