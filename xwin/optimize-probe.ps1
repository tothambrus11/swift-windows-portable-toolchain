# Investigates the `swiftc -O` + Foundation link failure. Needs swiftc on PATH (portable or official install).
param([string]$Work = "$env:RUNNER_TEMP\oprobe")
$ErrorActionPreference = 'Continue'
if (Test-Path $Work) { Remove-Item -Recurse -Force $Work }
New-Item -ItemType Directory -Force $Work | Out-Null
Set-Location $Work
Copy-Item (Join-Path $PSScriptRoot 'tests\foundation.swift') .

# Minimal repro: one Foundation (swift-corelibs) class
Set-Content repro.swift -Value @'
import Foundation
let f = DateFormatter()
f.dateFormat = "yyyy"
print(f.string(from: Date(timeIntervalSince1970: 0)))
'@
# Repro + an explicit `import FoundationEssentials` (as tests/foundation.swift has)
Set-Content repro-ess.swift -Value @'
import Foundation
import FoundationEssentials
let f = DateFormatter()
f.dateFormat = "yyyy"
print(f.string(from: Date(timeIntervalSince1970: 0)))
'@
(Get-Content foundation.swift) | Where-Object { $_ -notmatch 'FoundationEssentials|^#if canImport|^#endif' } | Set-Content foundation-noess.swift
# Same but only FoundationEssentials API (JSONEncoder) via `import Foundation`
Set-Content essentials.swift -Value @'
import Foundation
print(String(decoding: try! JSONEncoder().encode([1, 2]), as: UTF8.self))
'@

function Show($title, [scriptblock]$b) {
  Write-Host "::group::$title"
  $out = & $b 2>&1 | ForEach-Object { "$_" }
  $out | Select-Object -First 60 | ForEach-Object { Write-Host $_ }
  Write-Host "::endgroup::"
  $ok = ($LASTEXITCODE -eq 0)
  Write-Host ("[{0}] {1}" -f $(if ($ok) { 'OK' } else { 'FAIL' }), $title)
}
function Get-Directives($obj) {
  $s = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($obj))
  [regex]::Matches($s, '(?i)[/-]defaultlib:"?[A-Za-z0-9_.+-]+') | ForEach-Object Value | Sort-Object -Unique
}

Show 'swiftc -version' { swiftc -version; where.exe swiftc; $env:SDKROOT }
Show 'repro -Onone (link+run)' { swiftc -Onone repro.swift -o r0.exe; if ($?) { .\r0.exe } }
Show 'repro -O (link+run)' { swiftc -O repro.swift -o r1.exe; if ($?) { .\r1.exe } }
Show 'essentials -O (link+run)' { swiftc -O essentials.swift -o e1.exe; if ($?) { .\e1.exe } }
Show 'repro -Onone -wmo' { swiftc -Onone -wmo repro.swift -o r2.exe; if ($?) { .\r2.exe } }
Show 'repro+import FoundationEssentials -O' { swiftc -O repro-ess.swift -o re1.exe; if ($?) { .\re1.exe } }
Show 'repro+import FoundationEssentials -Onone' { swiftc -Onone repro-ess.swift -o re0.exe; if ($?) { .\re0.exe } }
Show 'foundation.swift -O' { swiftc -O foundation.swift -o f1.exe; if ($?) { .\f1.exe | Select-Object -Last 1 } }
Show 'foundation.swift without FoundationEssentials import -O' { swiftc -O foundation-noess.swift -o f2.exe; if ($?) { .\f2.exe | Select-Object -Last 1 } }
# Hypothesis A: module name. `swiftc foo.swift -o foo-o.exe` names the module after the *input* file when the
# output stem is not an identifier -> module "foundation", which clashes (case-insensitively) with Foundation.
Show 'foundation.swift -O -o foundation-o.exe (module name = foundation)' { swiftc -O foundation.swift -o foundation-o.exe; if ($?) { .\foundation-o.exe | Select-Object -Last 1 } }
Show 'foundation.swift -O -o foundation-o.exe -module-name app' { swiftc -O foundation.swift -o foundation-o2.exe -module-name app; if ($?) { .\foundation-o2.exe | Select-Object -Last 1 } }
Show 'foundation.swift -Onone -o foundation-d.exe (module name = foundation)' { swiftc -Onone foundation.swift -o foundation-d.exe; if ($?) { .\foundation-d.exe | Select-Object -Last 1 } }
Show 'repro as module "foundation" -O' { swiftc -O repro.swift -module-name foundation -o rm1.exe; if ($?) { .\rm1.exe } }
Show 'repro as module "foundation" -Onone' { swiftc -Onone repro.swift -module-name foundation -o rm0.exe; if ($?) { .\rm0.exe } }
Show 'repro as module "foundation" -O, autolink directives' { swiftc -O -c repro.swift -module-name foundation -o "$Work\rm1.o"; Get-Directives "$Work\rm1.o" }
Show 'repro as module "foundation" -Onone, autolink directives' { swiftc -Onone -c repro.swift -module-name foundation -o "$Work\rm0.o"; Get-Directives "$Work\rm0.o" }
Show 'repro as module "foundation" -Onone, link job' { swiftc -Onone repro.swift -module-name foundation -o rm2.exe -driver-print-jobs }
Show 'repro -O -lFoundation' { swiftc -O repro.swift -lFoundation -o r3.exe; if ($?) { .\r3.exe } }
Show 'foundation.swift -O -lFoundation' { swiftc -O foundation.swift -lFoundation -o f3.exe; if ($?) { .\f3.exe } }
Show 'repro -O -driver-print-jobs' { swiftc -O repro.swift -o r4.exe -driver-print-jobs }
Show 'repro -Onone -driver-print-jobs' { swiftc -Onone repro.swift -o r5.exe -driver-print-jobs }

# Object-level comparison: autolink directives and undefined Foundation symbols
foreach ($src in 'repro', 'repro-ess') { foreach ($o in 'Onone', 'O') {
  swiftc "-$o" -c "$src.swift" -o "$Work\$src-$o.o" 2>&1 | Out-Null
  Show "autolink directives $src -$o" { Get-Directives "$Work\$src-$o.o" }
} }
Show 'SwiftPM release link command for FoundationDemo' {
  Copy-Item -Recurse (Join-Path $PSScriptRoot 'tests\swiftpkg') "$Work\pkg"
  Push-Location "$Work\pkg"
  swift build -c release -v --product FoundationDemo 2>&1 | Select-String -SimpleMatch 'FoundationDemo.exe' | Select-Object -First 3 | ForEach-Object { $_.Line.Substring(0, [math]::Min(3000, $_.Line.Length)) }
  Pop-Location
}
$nm = Get-Command llvm-nm -ErrorAction SilentlyContinue
if ($nm) {
  Show 'undefined Foundation symbols -Onone' { llvm-nm -u "$Work\repro-ess-Onone.o" | Select-String '10Foundation|Foundation' }
  Show 'undefined Foundation symbols -O' { llvm-nm -u "$Work\repro-ess-O.o" | Select-String '10Foundation|Foundation' }
  $libdir = Get-ChildItem (Join-Path $env:SDKROOT 'usr\lib\swift\windows') -Recurse -Filter Foundation.lib | Select-Object -First 1
  Show "Foundation import libs ($($libdir.DirectoryName))" { Get-ChildItem $libdir.DirectoryName -Filter 'Foundation*.lib' | ForEach-Object { "$($_.Name) $($_.Length)" } }
  foreach ($lib in 'Foundation.lib', 'FoundationEssentials.lib', 'FoundationInternationalization.lib') {
    $p = Join-Path $libdir.DirectoryName $lib
    if (Test-Path $p) {
      Show "$lib exports DateFormatter symbols?" { llvm-nm $p 2>$null | Select-String 'DateFormatterC(Ma|ACycfc|ACycfC)$' | Select-Object -First 6 }
    }
  }
} else { Write-Host 'llvm-nm not in toolchain' }

# Which Foundation.swiftmodule does the compiler load?
Show 'module loading trace (-Onone)' { swiftc -Onone -typecheck repro.swift -Xfrontend -debug-time-function-bodies 2>&1 | Out-Null; swiftc -typecheck repro.swift -Rmodule-loading 2>&1 | Select-String 'Foundation' | Select-Object -First 8 }
