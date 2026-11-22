# Swift smoke tests for the setup-msvc test workflow (uses the test sources in xwin/tests).
# Runs in the current environment (setup-msvc + a Swift toolchain on PATH). Exits 1 if any case fails.
param(
  [string]$Work = (Join-Path $env:RUNNER_TEMP 'swift-smoke'),
  [string[]]$Cases = @('hello', 'foundation', 'winsdk', 'swiftpm', 'ctarget', 'cxx', 'clang'),
  [string]$Label = ''
)
$ErrorActionPreference = 'Continue'
$src = Join-Path $PSScriptRoot '..\..\xwin\tests'
if (Test-Path $Work) { Remove-Item -Recurse -Force $Work }
Copy-Item -Recurse $src $Work
Set-Location $Work

$results = New-Object System.Collections.ArrayList
function Invoke-Case([string]$name, [scriptblock]$body, [string]$expect) {
  Write-Host "::group::$name"
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $script:caseFailed = $false
  $out = ''
  try { $out = & $body 2>&1 | ForEach-Object { "$_" } | Out-String } catch { $script:caseFailed = $true; $out += "`nEXCEPTION: $_" }
  $ok = -not $script:caseFailed -and (-not $expect -or $out -match [regex]::Escape($expect))
  Write-Host $out
  Write-Host '::endgroup::'
  $st = if ($ok) { 'PASS' } else { 'FAIL' }
  if (-not $ok) { Write-Host "::error title=$name::$Label $name failed" }
  Write-Host ("[{0}] {1} ({2:n1}s)" -f $st, $name, $sw.Elapsed.TotalSeconds)
  [void]$results.Add([pscustomobject]@{ case = $name; result = $st; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) })
}
function Run([string]$exe) {
  if ($script:caseFailed) { return }
  "> $exe $($args -join ' ')"
  & $exe @args 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) { "!! $exe exited with $LASTEXITCODE"; $script:caseFailed = $true }
}

Invoke-Case 'info' {
  Run swift --version
  where.exe swift clang lld-link cl link 2>$null
  '--- runtime DLL resolution (PATH order):'
  where.exe swiftCore.dll Foundation.dll swiftWinSDK.dll swiftCRT.dll vcruntime140.dll 2>$null
  Get-ChildItem env: | Where-Object Name -match '^(INCLUDE|LIB|LIBPATH|SDKROOT|VC|Windows|UCRT|Universal|WINSYSROOT)' | Format-Table -AutoSize | Out-String -Width 400
  $cfg = Join-Path (Split-Path (Get-Command swift).Source) 'clang.cfg'
  if (Test-Path $cfg) { "--- $cfg"; Get-Content $cfg } else { '(no clang.cfg)' }
} ''
if ($Cases -contains 'hello') { Invoke-Case 'hello-swiftc' { Run swiftc hello.swift -o hello.exe; Run .\hello.exe } 'Hello from portable Swift!' }
if ($Cases -contains 'foundation') {
  Invoke-Case 'foundation-swiftc' { Run swiftc foundation.swift -o fdemo.exe; Run .\fdemo.exe } 'FOUNDATION OK'
  Invoke-Case 'foundation-swiftc-O' { Run swiftc -O foundation.swift -o fdemo-o.exe; Run .\fdemo-o.exe } 'FOUNDATION OK'
}
if ($Cases -contains 'winsdk') { Invoke-Case 'winsdk-swiftc' { Run swiftc winsdk.swift -o winsdk.exe; Run .\winsdk.exe } 'WINSDK OK' }
if ($Cases -contains 'swiftpm') {
  Push-Location swiftpkg
  Invoke-Case 'swiftpm-build' { Run swift build } ''
  Invoke-Case 'swiftpm-run' { Run swift run Hello } 'SWIFTPM OK'
  Invoke-Case 'swiftpm-foundation-run' { Run swift run FoundationDemo } 'FOUNDATION OK'
  Invoke-Case 'swiftpm-test' { Run swift test } ''
  Invoke-Case 'swiftpm-release' { Run swift build -c release; Run swift run -c release Hello } 'SWIFTPM OK'
  Pop-Location
}
if ($Cases -contains 'ctarget') { Push-Location cpkg; Invoke-Case 'swiftpm-c-target' { Run swift run CApp } 'CTARGET OK'; Pop-Location }
if ($Cases -contains 'cxx') { Push-Location cxx; Invoke-Case 'cxx-interop' { Run swiftc -cxx-interoperability-mode=default -I CxxDemo main.swift -o cxx.exe; Run .\cxx.exe } 'CXX OK'; Pop-Location }
if ($Cases -contains 'clang') {
  Set-Content -Path plain.c -Value '#include <stdio.h>', '#include <math.h>', '#include <windows.h>', 'int main(void){ printf("clang ok %llu %f\n", GetTickCount64(), sqrt(2.0)); return 0; }'
  Invoke-Case 'clang-plain-c' { Run clang plain.c -o plain.exe; Run .\plain.exe } 'clang ok'
}
if ($Cases -contains 'cl') {
  Set-Content -Path clhello.c -Value '#include <stdio.h>', '#include <windows.h>', 'int main(void){ printf("cl ok %d\n", _MSC_VER); return 0; }'
  Invoke-Case 'cl-hello' { Run cl.exe /nologo clhello.c /Fe:clhello.exe; Run .\clhello.exe } 'cl ok'
}

$results | Format-Table -AutoSize | Out-String | Write-Host
if ($env:GITHUB_STEP_SUMMARY) {
  $md = @("### Swift smoke $Label", '', '| case | result | s |', '|---|---|---|') + ($results | ForEach-Object { "| $($_.case) | $($_.result) | $($_.seconds) |" })
  Add-Content $env:GITHUB_STEP_SUMMARY -Value ($md + '')
}
if ($results | Where-Object result -eq 'FAIL') { exit 1 }
exit 0
