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

Invoke-Case 'info' { Run swift --version; Run where.exe swift clang lld-link; where.exe cl link vswhere 2>$null; Get-ChildItem env: | Where-Object Name -match '^(INCLUDE|LIB|SDKROOT|VC|Windows|UCRT|Universal)' | Format-Table -AutoSize | Out-String -Width 400 } ''
$plat = Split-Path (Split-Path (Split-Path (Split-Path $env:SDKROOT.TrimEnd('\')))) # ...\Windows.platform
Invoke-Case 'diag-plists' { Get-Content "$plat\Info.plist"; Get-ChildItem $env:SDKROOT -File | ForEach-Object { "--- $($_.Name)"; Get-Content $_.FullName -TotalCount 80 } ; swift build --help | Select-String 'build-system' } ''

$sysroot = Join-Path $Root 'winsysroot'
$kits = Join-Path $sysroot 'Windows Kits\10'
$sdkVer = $env:UCRTVersion; $vcVer = $env:VCToolsVersion
$vcTools = "$sysroot\VC\Tools\MSVC\$vcVer"
# The four driver flags that make the Swift frontend find (and VFS-overlay modulemaps into) the UCRT, WinSDK and VC headers
$F = @('-windows-sdk-root', $kits, '-windows-sdk-version', $sdkVer, '-visualc-tools-root', $vcTools, '-visualc-tools-version', $vcVer)
$libFlags = @(); foreach ($l in $env:LIB.Split(';')) { $libFlags += @('-Xlinker', "/LIBPATH:$l") }
$SPM = @(); foreach ($f in $F) { $SPM += @('-Xswiftc', $f) }
$SPM += $libFlags
$CC = @(); foreach ($i in $env:INCLUDE.Split(';')) { $CC += @('-Xcc', '-isystem', '-Xcc', $i) }

Invoke-Case 'a-hello-swiftc' { Run swiftc hello.swift -o hello.exe; Run .\hello.exe } 'Hello from portable Swift!'
Invoke-Case 'b0-foundation-env-only' { Run swiftc foundation.swift -o foundation0.exe; Run .\foundation0.exe } 'FOUNDATION OK'
Invoke-Case 'b-foundation' { Run swiftc @F foundation.swift -o foundation.exe; Run .\foundation.exe } 'FOUNDATION OK'
Invoke-Case 'b2-foundation-O' { Run swiftc -O @F foundation.swift -o foundation-o.exe; Run .\foundation-o.exe } 'FOUNDATION OK'
Invoke-Case 'c-winsdk' { Run swiftc @F winsdk.swift -o winsdk.exe; Run .\winsdk.exe } 'WINSDK OK'

Push-Location swiftpkg
Invoke-Case 'd1-swiftpm-build' { Run swift build -v @SPM } ''
Invoke-Case 'd2-swiftpm-run' { Run swift run @SPM Hello } 'SWIFTPM OK'
Invoke-Case 'd3-swiftpm-test' { Run swift test @SPM } ''
Invoke-Case 'd4-swiftpm-release' { Run swift build -c release @SPM; Run swift run -c release @SPM Hello } 'SWIFTPM OK'
Invoke-Case 'd5-swiftpm-native' { Run swift build --build-system native --scratch-path .build-native -v @SPM; Run swift run --build-system native --scratch-path .build-native @SPM Hello } 'SWIFTPM OK'
Invoke-Case 'd6-swiftpm-native-test' { Run swift test --build-system native --scratch-path .build-native @SPM } ''
Pop-Location

Push-Location cpkg
Invoke-Case 'e-swiftpm-c-target' { Run swift build -v @SPM @CC; Run swift run @SPM @CC CApp } 'CTARGET OK'
Invoke-Case 'e2-swiftpm-c-native' { Run swift build --build-system native --scratch-path .build-native -v @SPM; Run swift run --build-system native --scratch-path .build-native @SPM CApp } 'CTARGET OK'
Pop-Location

Push-Location cxx
Invoke-Case 'f-cxx-interop' { Run swiftc @F -cxx-interoperability-mode=default -I CxxDemo main.swift -o cxx.exe; Run .\cxx.exe } 'CXX OK'
Pop-Location

Set-Content -Path plain.c -Value '#include <stdio.h>', '#include <math.h>', '#include <windows.h>', 'int main(void){ printf("clang ok %llu %f\n", GetTickCount64(), sqrt(2.0)); return 0; }'
Invoke-Case 'g-plain-clang' { Run clang plain.c -o plain.exe; Run .\plain.exe } 'clang ok'
Invoke-Case 'g2-clang-winsysroot-flag' {
  $i = $env:INCLUDE; $l = $env:LIB; Remove-Item env:INCLUDE, env:LIB
  Run clang -Xmicrosoft-windows-sys-root $sysroot plain.c -o plain2.exe; Run .\plain2.exe
  $env:INCLUDE = $i; $env:LIB = $l } 'clang ok'

# Registry experiments: does the frontend find the SDK via 'Installed Roots' without flags?
function Set-KitsRoot($hive) {
  $k = "${hive}:\SOFTWARE\Microsoft\Windows Kits\Installed Roots"
  New-Item -Path $k -Force | Out-Null
  New-ItemProperty -Path $k -Name KitsRoot10 -Value "$kits\" -PropertyType String -Force | Out-Null
  return $k
}
$k = Set-KitsRoot 'HKCU'
Invoke-Case 'r1-hkcu-registry-winsdk' { Run swiftc winsdk.swift -o winsdk-hkcu.exe; Run .\winsdk-hkcu.exe } 'WINSDK OK'
Remove-Item -Path $k -Recurse -Force
$k = Set-KitsRoot 'HKLM'
Invoke-Case 'r2-hklm-registry-foundation' { Run swiftc foundation.swift -o foundation-hklm.exe; Run .\foundation-hklm.exe } 'FOUNDATION OK'
Push-Location swiftpkg
Invoke-Case 'r3-hklm-registry-swiftpm' { Run swift build --scratch-path .build-reg; Run swift run --scratch-path .build-reg Hello } 'SWIFTPM OK'
Pop-Location
Remove-Item -Path $k -Recurse -Force

# Summary
$md = @("| test | result | time (s) |", "|---|---|---|")
foreach ($r in $results) { $md += "| $($r.name) | $($r.status) | $($r.seconds) |" }
$md = $md -join "`n"
Write-Host $md
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value "### Test matrix ($env:RUNNER_ARCH)`n`n$md`n" }
if ($ResultsFile) { $results | ConvertTo-Json -Depth 4 | Set-Content -Path $ResultsFile -Encoding UTF8 }
$failed = @($results | Where-Object { $_.status -eq 'FAIL' -and $_.name -notmatch '^(f-|g2-|b0-|r|d5|d6|e2|diag)' })
if ($failed.Count -gt 0) { Write-Host "Required failures: $($failed.name -join ', ')"; exit 1 }
exit 0
