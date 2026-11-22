# Builds and runs the test programs with an installed Swift.
#   test-swift.ps1 -Project <work dir> [-Exec 'vfox exec swift@6.4.3 --']   (prefix for every command)
param(
  [Parameter(Mandatory = $true)][string]$Project,
  [string]$Exec = '',
  [string]$Tests = (Join-Path $PSScriptRoot 'tests')
)
$ErrorActionPreference = 'Stop'
$results = [ordered]@{}
$prefix = @($Exec -split ' ' | Where-Object { $_ })
function X {
  $cmd = @($args)
  # vfox 1.1.0 `exec` looks a bare name up in the SDK's PATH without PATHEXT (it stats <dir>\swift, not
  # swift.exe) and then falls back to the parent's PATH: name the .exe explicitly
  if ($prefix.Count -and $cmd[0] -in 'swift', 'swiftc') { $cmd[0] = "$($cmd[0]).exe" }
  $all = @($prefix) + $cmd
  & $all[0] @($all | Select-Object -Skip 1)
  if ($LASTEXITCODE) { throw "exit code $LASTEXITCODE" }
}
function Invoke-Case([string]$name, [scriptblock]$body) {
  Write-Host "::group::$name"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    & $body
    $results[$name] = "PASS ($([math]::Round($sw.Elapsed.TotalSeconds))s)"
  } catch {
    $results[$name] = "FAIL: $_"
    Write-Host "::error::$name failed: $_"
  }
  Write-Host '::endgroup::'
}

New-Item -ItemType Directory -Force $Project | Out-Null
Push-Location $Project
try {
  Invoke-Case 'swift --version' { X swift --version }
  Invoke-Case 'where swift' { X where.exe swift }
  Invoke-Case 'env (SDKROOT, INCLUDE, LIB)' { X cmd /c 'echo SDKROOT=%SDKROOT% & echo INCLUDE=%INCLUDE% & echo LIB=%LIB%' }
  Copy-Item (Join-Path $Tests 'foundation.swift') (Join-Path $Project 'foundation.swift') -Force
  Invoke-Case 'swiftc foundation.swift + run' { X swiftc foundation.swift -o fdemo.exe; X .\fdemo.exe }
  Invoke-Case 'swiftc -O foundation.swift + run' { X swiftc -O foundation.swift -o fdemo-o.exe; X .\fdemo-o.exe }
  $pkg = Join-Path $Project 'swiftpkg'
  if (Test-Path $pkg) { Remove-Item -Recurse -Force $pkg }
  Copy-Item -Recurse (Join-Path $Tests 'swiftpkg') $pkg
  Push-Location $pkg
  try {
    Invoke-Case 'swift build' { X swift build }
    Invoke-Case 'swift run FoundationDemo' { X swift run FoundationDemo }
    Invoke-Case 'swift test (XCTest + swift-testing)' { X swift test }
  } finally { Pop-Location }
} finally { Pop-Location }

$results | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
$md = "| case | result |`n|---|---|`n" + (($results.Keys | ForEach-Object { "| $_ | $($results[$_]) |" }) -join "`n")
if ($env:GITHUB_STEP_SUMMARY) { "### $env:JOB_LABEL`n$md`n" | Out-File -Append -Encoding utf8 $env:GITHUB_STEP_SUMMARY }
if (@($results.Values | Where-Object { $_ -like 'FAIL*' }).Count -gt 0) { exit 1 }
