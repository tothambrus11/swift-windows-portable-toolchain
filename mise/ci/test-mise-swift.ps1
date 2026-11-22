# Builds and runs the test programs with a mise-installed Swift, through `mise exec` only.
#   test-mise-swift.ps1 -Project <dir with mise.toml> -Tool <tool name in mise.toml>
param(
  [Parameter(Mandatory = $true)][string]$Project,
  [string]$Tests = (Join-Path $PSScriptRoot 'tests')
)
$ErrorActionPreference = 'Stop'
$results = [ordered]@{}
function Invoke-Case([string]$name, [scriptblock]$body) {
  Write-Host "::group::$name"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    & $body
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
    $results[$name] = "PASS ($([math]::Round($sw.Elapsed.TotalSeconds))s)"
  } catch {
    $results[$name] = "FAIL: $_"
    Write-Host "::error::$name failed: $_"
  }
  Write-Host '::endgroup::'
}

Push-Location $Project
try {
  Invoke-Case 'swift --version' { mise exec -- swift --version }
  Invoke-Case 'where swift' { mise exec -- where.exe swift }
  Copy-Item (Join-Path $Tests 'foundation.swift') (Join-Path $Project 'foundation.swift') -Force
  Invoke-Case 'swiftc foundation.swift (debug) + run' {
    mise exec -- swiftc foundation.swift -o fdemo.exe; if ($LASTEXITCODE) { throw "swiftc exit $LASTEXITCODE" }
    mise exec -- .\fdemo.exe
  }
  Invoke-Case 'swiftc -O foundation.swift + run' {
    mise exec -- swiftc -O foundation.swift -o fdemo-o.exe; if ($LASTEXITCODE) { throw "swiftc exit $LASTEXITCODE" }
    mise exec -- .\fdemo-o.exe
  }
  $pkg = Join-Path $Project 'swiftpkg'
  if (Test-Path $pkg) { Remove-Item -Recurse -Force $pkg }
  Copy-Item -Recurse (Join-Path $Tests 'swiftpkg') $pkg
  Push-Location $pkg
  try {
    Invoke-Case 'swift build' { mise exec -- swift build }
    Invoke-Case 'swift run Hello' { mise exec -- swift run Hello }
    Invoke-Case 'swift run FoundationDemo' { mise exec -- swift run FoundationDemo }
    Invoke-Case 'swift test (XCTest + swift-testing)' { mise exec -- swift test }
    Invoke-Case 'swift build -c release' { mise exec -- swift build -c release }
  } finally { Pop-Location }
} finally { Pop-Location }

$results | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
$md = "| case | result |`n|---|---|`n" + (($results.Keys | ForEach-Object { "| $_ | $($results[$_]) |" }) -join "`n")
if ($env:GITHUB_STEP_SUMMARY) { "### $env:JOB_LABEL`n$md`n" | Out-File -Append -Encoding utf8 $env:GITHUB_STEP_SUMMARY }
if (@($results.Values | Where-Object { $_ -like 'FAIL*' }).Count -gt 0) { exit 1 }
