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
  try {
    $out = & $body 2>&1 | ForEach-Object { "$_" } | Out-String
    if ($LASTEXITCODE -ne 0) { $ok = $false }
    if ($expect -and ($out -notmatch [regex]::Escape($expect))) { $ok = $false }
  } catch { $ok = $false; $out += "`nEXCEPTION: $_" }
  Write-Host $out
  Write-Host "::endgroup::"
  $status = if ($ok) { 'PASS' } else { 'FAIL' }
  if (-not $ok) { Write-Host "::error title=$name::$name failed" }
  Write-Host ("[{0}] {1} ({2:n1}s)" -f $status, $name, $sw.Elapsed.TotalSeconds)
  $tail = ($out -split "`n" | Select-Object -Last 25) -join "`n"
  [void]$results.Add([pscustomobject]@{ name = $name; status = $status; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); tail = $tail })
}
function Run([string]$exe) { & $exe @args; if ($LASTEXITCODE -ne 0) { throw "$exe exited with $LASTEXITCODE" } }

Invoke-Case 'info' { swift --version; Run swiftc -print-target-info; where.exe swift clang lld-link; where.exe cl link vswhere 2>$null; $global:LASTEXITCODE = 0 } ''

Invoke-Case 'a-hello-swiftc' { Run swiftc hello.swift -o hello.exe; Run .\hello.exe } 'Hello from portable Swift!'
Invoke-Case 'b-foundation' { Run swiftc foundation.swift -o foundation.exe; Run .\foundation.exe } 'FOUNDATION OK'
Invoke-Case 'c-winsdk' { Run swiftc winsdk.swift -o winsdk.exe; Run .\winsdk.exe } 'WINSDK OK'
Invoke-Case 'c2-winsdk-O' { Run swiftc -O winsdk.swift -o winsdk-o.exe; Run .\winsdk-o.exe } 'WINSDK OK'

Push-Location swiftpkg
Invoke-Case 'd1-swiftpm-build' { Run swift build -v } ''
Invoke-Case 'd2-swiftpm-run' { Run swift run Hello } 'SWIFTPM OK'
Invoke-Case 'd3-swiftpm-test' { Run swift test } ''
Invoke-Case 'd4-swiftpm-release' { Run swift build -c release; Run .\.build\release\Hello.exe } 'SWIFTPM OK'
Pop-Location

Push-Location cpkg
Invoke-Case 'e-swiftpm-c-target' { Run swift build -v; Run swift run CApp } 'CTARGET OK'
Pop-Location

Push-Location cxx
Invoke-Case 'f-cxx-interop' { Run swiftc -cxx-interoperability-mode=default -I CxxDemo main.swift -o cxx.exe; Run .\cxx.exe } 'CXX OK'
Pop-Location

# Plain clang on a C file (no SwiftPM), to check clang alone finds headers + libs
Set-Content -Path plain.c -Value '#include <stdio.h>', '#include <windows.h>', 'int main(void){ printf("clang ok %llu\n", GetTickCount64()); return 0; }'
Invoke-Case 'g-plain-clang' { Run clang plain.c -o plain.exe; Run .\plain.exe } 'clang ok'

# Flags-only mode: no INCLUDE/LIB/VCToolsInstallDir/UniversalCRTSdkDir env vars, only driver flags.
$saved = @{}
foreach ($v in 'INCLUDE','LIB','VCToolsInstallDir','VCToolsVersion','VCINSTALLDIR','UniversalCRTSdkDir','UCRTVersion','WindowsSdkDir','WindowsSDKVersion','WindowsSDKLibVersion') {
  $saved[$v] = [Environment]::GetEnvironmentVariable($v); Remove-Item "env:$v" -ErrorAction SilentlyContinue
}
$sysroot = Join-Path $Root 'winsysroot'
$kits = Join-Path $sysroot 'Windows Kits\10'
$sdkVer = $saved['UCRTVersion']; $vcVer = $saved['VCToolsVersion']
$flags = @('-windows-sdk-root', "$kits", '-windows-sdk-version', $sdkVer,
           '-visualc-tools-root', "$sysroot\VC\Tools\MSVC\$vcVer", '-visualc-tools-version', $vcVer)
Invoke-Case 'h-flags-only-winsdk' { Run swiftc @flags winsdk.swift -o winsdk-flags.exe; Run .\winsdk-flags.exe } 'WINSDK OK'
Invoke-Case 'h2-flags-only-foundation' { Run swiftc @flags foundation.swift -o foundation-flags.exe; Run .\foundation-flags.exe } 'FOUNDATION OK'
foreach ($k in $saved.Keys) { if ($saved[$k]) { Set-Item "env:$k" $saved[$k] } }

# Summary
$md = @("| test | result | time (s) |", "|---|---|---|")
foreach ($r in $results) { $md += "| $($r.name) | $($r.status) | $($r.seconds) |" }
$md = $md -join "`n"
Write-Host $md
if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value "### Test matrix ($env:RUNNER_ARCH)`n`n$md`n" }
if ($ResultsFile) { $results | ConvertTo-Json -Depth 4 | Set-Content -Path $ResultsFile -Encoding UTF8 }
$failed = @($results | Where-Object { $_.status -eq 'FAIL' -and $_.name -notmatch '^(f-|h|g-)' })
if ($failed.Count -gt 0) { Write-Host "Required failures: $($failed.name -join ', ')"; exit 1 }
exit 0
