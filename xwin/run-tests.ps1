# Runs the test matrix against a portable Swift set up by setup-portable-swift.ps1.
param(
  [Parameter(Mandatory = $true)][string]$Root,      # the -Target passed to setup-portable-swift.ps1
  [string]$Work = "$env:RUNNER_TEMP\xwin-tests",
  [string]$ResultsFile = ''
)
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
. (Join-Path $here 'clean-env.ps1')
. (Join-Path $Root 'activate.ps1')

if (Test-Path $Work) { Remove-Item -Recurse -Force $Work }
Copy-Item -Recurse (Join-Path $here 'tests') $Work
Set-Location $Work

$results = New-Object System.Collections.ArrayList
function Invoke-Case([string]$name, [scriptblock]$body, [string]$expect) {
  Write-Host "::group::$name"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $out = ''
  $ok = $true
  $script:caseFailed = $false
  try {
    $out = & $body 2>&1 | ForEach-Object { "$_" } | Out-String
    if ($script:caseFailed) { $ok = $false }
    if ($expect -and ($out -notmatch [regex]::Escape($expect))) { $ok = $false }
  } catch { $ok = $false; $out += "`nEXCEPTION: $_" }
  Write-Host $out
  Write-Host "::endgroup::"
  $status = if ($ok) { 'PASS' } else { 'FAIL' }
  if (-not $ok) { Write-Host "::error title=$name::$name failed" }
  Write-Host ("[{0}] {1} ({2:n1}s)" -f $status, $name, $sw.Elapsed.TotalSeconds)
  $tail = ($out -split "`n" | Select-Object -Last 40) -join "`n"
  [void]$results.Add([pscustomobject]@{ name = $name; status = $status; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); tail = $tail })
}
# Runs a native command, streaming its output; on failure marks the case failed and skips the rest of it
function Run([string]$exe) {
  if ($script:caseFailed) { return }
  "> $exe $($args -join ' ')"
  & $exe @args 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) { "!! $exe exited with $LASTEXITCODE"; $script:caseFailed = $true }
}

Invoke-Case 'info' { Run swift --version; Run where.exe swift clang lld-link; where.exe cl link vswhere 2>$null; Get-ChildItem env: | Where-Object Name -match '^(INCLUDE|LIB|SDKROOT|VC|Windows|UCRT|Universal)' | Format-Table -AutoSize | Out-String -Width 400; Get-Content (Join-Path (Split-Path (Get-Command clang).Source) 'clang.cfg') } ''
$plat = Split-Path (Split-Path (Split-Path $env:SDKROOT.TrimEnd('\'))) # ...\Windows.platform
Invoke-Case 'diag-platform' { Get-Content "$plat\Info.plist"; Get-ChildItem "$plat\Developer\Library" -Recurse -Depth 2 -Directory | ForEach-Object FullName } ''

$sysroot = Join-Path $Root 'winsysroot'
$kits = Join-Path $sysroot 'Windows Kits\10'
$sdkVer = $env:UCRTVersion; $vcVer = $env:VCToolsVersion
$vcTools = "$sysroot\VC\Tools\MSVC\$vcVer"
# Explicit driver flags (alternative to the physical modulemaps): make the frontend locate UCRT/WinSDK/VC itself
$SdkFlags = @('-windows-sdk-root', $kits, '-windows-sdk-version', $sdkVer, '-visualc-tools-root', $vcTools, '-visualc-tools-version', $vcVer)

# ---- main path: no extra flags at all (activate.ps1 env + modulemaps in sysroot + clang.cfg)
Invoke-Case 'a-hello-swiftc' { Run swiftc hello.swift -o hello.exe; Run .\hello.exe } 'Hello from portable Swift!'
Invoke-Case 'b-foundation-swiftc' { Run swiftc foundation.swift -o foundation.exe; Run .\foundation.exe } 'FOUNDATION OK'
Invoke-Case 'b2-foundation-swiftc-O' { Run swiftc -O foundation.swift -o foundation-o.exe; Run .\foundation-o.exe } 'FOUNDATION OK'
Invoke-Case 'c-winsdk-swiftc' { Run swiftc winsdk.swift -o winsdk.exe; Run .\winsdk.exe } 'WINSDK OK'

Push-Location swiftpkg
Invoke-Case 'd1-swiftpm-build' { Run swift build } ''
Invoke-Case 'd2-swiftpm-run' { Run swift run Hello } 'SWIFTPM OK'
Invoke-Case 'd2b-swiftpm-foundation-demo' { Run swift run FoundationDemo } 'FOUNDATION OK'
Invoke-Case 'd3-swiftpm-test' { Run swift test } ''
Invoke-Case 'd4-swiftpm-release' { Run swift build -c release; Run swift run -c release Hello } 'SWIFTPM OK'
Invoke-Case 'd5-swiftpm-native-run' { Run swift run --build-system native --scratch-path .build-native Hello } 'SWIFTPM OK'
Invoke-Case 'd6-swiftpm-native-test' { Run swift test --build-system native --scratch-path .build-native } ''
Pop-Location

Push-Location cpkg
Invoke-Case 'e-swiftpm-c-target' { Run swift run CApp } 'CTARGET OK'
Invoke-Case 'e2-swiftpm-c-native' { Run swift run --build-system native --scratch-path .build-native CApp } 'CTARGET OK'
Pop-Location

Push-Location cxx
Invoke-Case 'f-cxx-interop' { Run swiftc -cxx-interoperability-mode=default -I CxxDemo main.swift -o cxx.exe; Run .\cxx.exe } 'CXX OK'
Pop-Location

Set-Content -Path plain.c -Value '#include <stdio.h>', '#include <math.h>', '#include <windows.h>', 'int main(void){ printf("clang ok %llu %f\n", GetTickCount64(), sqrt(2.0)); return 0; }'
Invoke-Case 'g-plain-clang' { Run clang plain.c -o plain.exe; Run .\plain.exe } 'clang ok'
Invoke-Case 'g2-clang-no-INCLUDE-LIB' {
  $i = $env:INCLUDE; $l = $env:LIB; Remove-Item env:INCLUDE, env:LIB
  Run clang plain.c -o plain2.exe; Run .\plain2.exe
  $env:INCLUDE = $i; $env:LIB = $l } 'clang ok'

# ---- explicit flags variant (no reliance on INCLUDE for the frontend)
Invoke-Case 'h-flags-foundation-swiftc' { Run swiftc -v @SdkFlags foundation.swift -o foundation-f.exe; Run .\foundation-f.exe } 'FOUNDATION OK'
Invoke-Case 'h2-flags-winsdk-swiftc' { Run swiftc @SdkFlags winsdk.swift -o winsdk-f.exe; Run .\winsdk-f.exe } 'WINSDK OK'

# ---- registry variant (needs admin): hide the physical modulemaps, register the kit in HKLM (32-bit view, as LLVM reads it)
$mm = @(Get-ChildItem $sysroot -Recurse -Filter module.modulemap | ForEach-Object FullName)
Write-Host "physical modulemaps: $($mm -join ', ')"
foreach ($m in $mm) { Rename-Item $m 'module.modulemap.off' }
$regKeys = @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots', 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots')
Invoke-Case 'r0-no-modulemaps-no-registry-foundation' { Run swiftc foundation.swift -o foundation-r0.exe; Run .\foundation-r0.exe } 'FOUNDATION OK'
foreach ($k in $regKeys) { New-Item -Path $k -Force | Out-Null; New-ItemProperty -Path $k -Name KitsRoot10 -Value "$kits\" -PropertyType String -Force | Out-Null }
Invoke-Case 'r1-hklm-registry-foundation' { Run swiftc foundation.swift -o foundation-r1.exe; Run .\foundation-r1.exe } 'FOUNDATION OK'
Push-Location swiftpkg
Invoke-Case 'r2-hklm-registry-swiftpm-test' { Run swift test --scratch-path .build-reg } ''
Pop-Location
foreach ($k in $regKeys) { Remove-Item -Path $k -Recurse -Force }
foreach ($m in $mm) { Rename-Item "$m.off" 'module.modulemap' }

# Summary
$md = @("| test | result | time (s) |", "|---|---|---|")
foreach ($r in $results) { $md += "| $($r.name) | $($r.status) | $($r.seconds) |" }
$md = $md -join "`n"
Write-Host $md
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value "### Test matrix ($env:RUNNER_ARCH)`n`n$md`n" }
if ($ResultsFile) { $results | ConvertTo-Json -Depth 4 | Set-Content -Path $ResultsFile -Encoding UTF8 }
$failed = @($results | Where-Object { $_.status -eq 'FAIL' -and $_.name -notmatch '^(f-|g2-|h|r|d5|d6|e2|diag)' })
if ($failed.Count -gt 0) { Write-Host "Required failures: $($failed.name -join ', ')"; exit 1 }
exit 0
