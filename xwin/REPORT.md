# Swift on Windows without Visual Studio: xwin/NuGet sysroot experiment

**Verdict: it works.** On GitHub `windows-latest` (x64) and `windows-11-arm` (arm64) runners, with
Visual Studio, Build Tools, the Windows Kits and their registry keys hidden, the official Swift 6.4.3
toolchain builds and runs everything in the test matrix: plain `swiftc`, **Foundation**, `import WinSDK`,
SwiftPM `build`/`run`/`test` (XCTest and swift-testing), SwiftPM C targets, and C++ interop with `<vector>`.
The setup runs without the VS installer and without registry writes. It needs about 190 s and about 2.5 GB
of downloads.

The one remaining gap is a link failure with single-file `swiftc -O`/`-Osize` and Foundation's formatter
classes. SwiftPM `-c release` builds the same code and runs it fine. Details below.

- Green run (all required cases pass, both arches): https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44954697438
- Earlier runs, kept for the failure evidence quoted below:
  - [44943076851](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44943076851): `/layout` did not extract the MSIs.
  - [44944519038](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44944519038): MAX_PATH error 1603.
  - [44945773387](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44945773387): env-vars-only; no ucrt module, and link.exe was missing.
  - [44951635240](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44951635240): driver flags; SwiftPM worked but the test runner did not.
  - [44952836955](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44952836955): a backslash in `clang.cfg` broke everything.
  - [44953402244](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44953402244): first run where almost everything passed.

## How to use

```powershell
powershell -ExecutionPolicy Bypass -File xwin\setup-portable-swift.ps1 -Target $env:LOCALAPPDATA\swift-portable -AcceptMicrosoftLicense
. $env:LOCALAPPDATA\swift-portable\activate.ps1      # or: call %LOCALAPPDATA%\swift-portable\activate.bat
swift build; swift run; swift test                    # no extra flags needed
```

The `-AcceptMicrosoftLicense` switch is required. The MSVC CRT and Windows SDK are covered by the Visual Studio
license (https://go.microsoft.com/fwlink/?LinkId=2086102). The script refuses to run without the switch, and only
then does it pass `--accept-license` to xwin.

Script options:
- `-SwiftVersion 6.4.3` (default: latest from `swift.org/api/v1/install/releases.json`)
- `-Arch x64|arm64`
- `-SdkSource nuget|xwin`
- `-NugetSdkVersion`, `-CrtVersion`, `-SdkVersion`
- `-IncludeDebugLibs`
- `-KeepDownloads`
- `-NoModulemapCopy`

## What the script does (and why each step is needed)

### 1. Swift toolchain: portable extraction of the official installer
- **What:** downloads `swift-6.4.3-RELEASE-windows10[-arm64].exe` from download.swift.org.
- **Why not `/layout`:** the file is a WiX Burn bundle, and `installer.exe /layout <dir> /quiet` only copied the bundle
  exe. All packages were planned with "cache: No" (run 44943076851).
- **How the bundle is read:** `Expand-BurnBundle` parses the bundle in a few lines of PowerShell.
  - It reads the PE `.wixburn` section to get the stub size and the container sizes.
  - It locates each CAB. The Authenticode blob sits between the UX container and the attached containers.
  - It extracts each CAB with `expand.exe`. libarchive's `tar` fails on these LZX CABs with `LZX decompression failed (-25)`.
  - It maps payload ids to file names through the Burn manifest in UX file `0`.
- **Packages:** the bundle contains `bld/cli/dbg/ide.{asserts,noasserts}.msi`, `python.msi`, `res.msi`,
  `rtl.<arch>.msi`, `android.msi` and `windows.msi`. The MSIs are tiny and use external `.cab`s. The NoAsserts
  container (650 MB) and `android.msi` are skipped.
- **Extraction:** `msiexec /a <msi> /qn TARGETDIR=<short dir>`, an administrative install. It writes no registry
  entries, runs no custom actions and has no VS check. Each MSI is staged in its own short directory, because
  `windows.msi` failed with **1603 caused by MAX_PATH** when staged under a longer path.
  - The per-user MSIs land in `<TARGETDIR>\LocalApp\Programs\Swift\...`. They are merged (robocopy /MOVE) into
    `<Target>\Swift\{Toolchains,Platforms,Redistributables,...}`.
  - `rtl.<arch>.msi` puts its DLLs directly into TARGETDIR. They are moved to the standard
    `Swift\Runtimes\6.4.3\usr\bin`.
- **Not verified:** `msiexec /a` normally works without elevation, but the runner is admin, so non-admin was not tested.
- **Result layout:** the same as a real per-user install (`Toolchains\6.4.3+Asserts\usr\bin`,
  `Platforms\6.4.3\Windows.platform\Developer\SDKs\Windows.sdk`, `Runtimes\6.4.3\usr\bin`).

### 2. MSVC CRT + Windows SDK
- **MSVC CRT** comes from `xwin 0.10.0` (official windows-msvc release binary):
  `xwin --accept-license --arch x86_64|aarch64 splat --use-winsysroot-style --preserve-ms-arch-notation --disable-symlinks`.
  This produces `VC\Tools\MSVC\14.44.17.14\{include,lib\x64}`.
  - The prebuilt xwin binary is x64 only. On arm64 it runs under emulation without problems.
- **Windows SDK** comes from Microsoft's NuGet packages, the default (`-SdkSource nuget`):
  - `Microsoft.Windows.SDK.CPP` provides headers (`c/Include/<ver>` only is extracted).
  - `Microsoft.Windows.SDK.CPP.<arch>` provides `c/ucrt/<arch>` and `c/um/<arch>` libs.
  - They are placed as `Windows Kits\10\{Include,Lib}\10.0.28000.0\...`, so the whole tree is a `/winsysroot`
    layout. The version used was 10.0.28000.2957.
- **Why not xwin's SDK:** **xwin's Windows SDK is missing `ucrt\corecrt_math.h`** (`xwin_has_corecrt_math_h: false`),
  and the Swift `ucrt.modulemap` requires it:
  `ucrt.modulemap:237:12: error: header 'corecrt_math.h' not found` (run 44945773387).
  NuGet's SDK is complete and officially published.
- **Improvement:** xwin still downloads its SDK, which is then discarded (about 200 MB wasted). A CRT-only fetch
  (portable-msvc.py style, or a future xwin option) would save that.

### 3. Making Swift use it (the important part)
Three mechanisms are needed. All of them are written by the setup script, so nothing has to be passed by hand.

| Problem (observed error) | Fix |
|---|---|
| `swiftc hello.swift` -> `clang: error: unable to execute command: program not executable`. swiftc links through `clang.exe`, which defaults to MSVC `link.exe`. | Write `clang.cfg`/`clang++.cfg` next to the toolchain's `clang.exe` with `-fuse-ld=lld`. clang loads `<bindir>\clang.cfg` by default. |
| SwiftPM C targets: `'stdio.h' file not found`. The swift-build build system does not pass `INCLUDE`/`LIB` to its clang jobs. | Add `-Xmicrosoft-windows-sys-root "C:/.../winsysroot"` to the same `clang.cfg`. This gives headers and libs for compile **and** link, even with no env vars (case `g2`). **Use forward slashes**: backslash is an escape character in clang config files. |
| `error: missing required modules: '_complex', 'ucrt'` and `cannot load underlying module for 'WinSDK'`. The frontend VFS-overlays its `ucrt/winsdk_um/winsdk_shared/vcruntime` modulemaps only when it can *locate* the SDK, through `-windows-sdk-root` flags or the HKLM registry. `UniversalCRTSdkDir`/`UCRTVersion` env vars are ignored. | Copy `Windows.sdk\usr\share\{ucrt,winsdk_um,winsdk_shared,vcruntime}.modulemap` and `vcruntime.apinotes` *physically* to `ucrt\`, `um\`, `shared\` and `VC\...\include\` as `module.modulemap`. This is what old Swift installers did. Combined with `clang.cfg`, the importer finds `ucrt`, `WinSDK` and `vcruntime` without any flag. |

`activate.ps1` and `activate.bat` also set vcvars-style variables for other tools (for example `INCLUDE` for plain
clang). With the mechanisms above, swiftc and SwiftPM no longer depend on them.
- `PATH` gets the toolchain `usr\bin` and `Runtimes\...\usr\bin`.
- Variables set: `SDKROOT`, `INCLUDE`, `LIB`, `VCToolsInstallDir`, `VCToolsVersion`, `UniversalCRTSdkDir`,
  `UCRTVersion`, `WindowsSdkDir`, `WindowsSDKVersion`.

Things that do **not** fully work:
- **Driver flags.** `-windows-sdk-root <kits> -windows-sdk-version <ver> -visualc-tools-root <vc> -visualc-tools-version <ver>`,
  plus `-Xlinker /LIBPATH:...` for linking, made `swiftc` and `swift build`/`run` work (run 44951635240). But
  SwiftPM does **not** forward `-Xswiftc` to every job, so `swift test` fails:
  - With swift-build, `test_anchor.swift` fails with `'stdlib.h' file not found`.
  - With the native build system, `runner.swift` fails with `missing required modules: '_complex', 'ucrt'`.
- **Driver flags combined with the physical modulemaps and `clang.cfg`.** The asserts frontend crashes
  (`h-*` cases):
  `Assertion failed: !isTraversalComponent(*Start) && ... "Paths should not contain traversal components", file ...\llvm\lib\Support\VirtualFileSystem.cpp, line 2348`.
  This is worth an upstream bug report.
- **Registry.** Writing `KitsRoot10` into `HKLM\SOFTWARE\[WOW6432Node\]Microsoft\Windows Kits\Installed Roots`
  (needs admin) with the physical modulemaps removed was *not* enough:
  - `cannot load underlying module for 'WinSDK'`.
  - SwiftPM failed with `could not build C module 'CDispatch'` / `missing '#include <stdint.h>'`.
  - `HKCU` is not consulted at all.

## Test matrix (green run 44954697438, both x64 and arm64 identical)

| case | x64 | arm64 | notes |
|---|---|---|---|
| a `swiftc hello.swift` + run | PASS | PASS | |
| b `swiftc foundation.swift` + run (debug) | **PASS** | **PASS** | JSONEncoder/Decoder + Date ISO8601, FileManager tmp write/read/remove, URL, Data/base64, `String(format:)` with `%@`, DateFormatter, NumberFormatter, `Date.now.formatted()`, UUID |
| b2/b3/b4 `swiftc -O` / `-O -Xfrontend -disable-cmo` / `-Osize` foundation | FAIL | FAIL | link: `lld-link: error: undefined symbol: __declspec(dllimport) $s10Foundation13DateFormatterCACycfc` (also NumberFormatter, NSString, NSNumber). Same code via SwiftPM `-c release` passes (d4b). Not checked against a machine with VS, so it may be a general 6.4.3 single-file `-O` issue. |
| c `import WinSDK` (GetTickCount64, GetSystemInfo, GetSystemDirectoryW) | PASS | PASS | |
| d1/d2 SwiftPM `swift build` / `swift run` (lib + exe, Foundation) | PASS | PASS | default build system is swift-build in 6.4 |
| d2b SwiftPM `swift run FoundationDemo` (same Foundation program as b) | **PASS** | **PASS** | |
| d3 `swift test` (XCTest + swift-testing) | PASS | PASS | "Executed 2 tests, with 0 failures"; "Test run with 1 test ... passed" |
| d4/d4b `swift build -c release`, `swift run -c release FoundationDemo` | PASS | PASS | |
| d5/d6 `--build-system native` run + test | PASS | PASS | |
| e/e2 SwiftPM C target (stdio, math, windows.h, malloc) build + run, both build systems | PASS | PASS | |
| f C++ interop `-cxx-interoperability-mode=default`, `std::vector`, `std::string`, `CxxStdlib` | PASS | PASS | |
| g plain `clang plain.c` (windows.h, math) | PASS | PASS | |
| g2 plain clang with INCLUDE/LIB unset (only clang.cfg) | PASS | PASS | |
| fresh `cmd` shell: PATH=System32 only, `call activate.bat`, `swift build -c release && swift run` | PASS | PASS | |
| h driver-flags variant on top of the default setup | FAIL | FAIL | VFS assertion above (informational) |
| r0/r1/r2 registry variants | FAIL | FAIL | informational (see above) |

VS was really gone, and the verify step fails the job otherwise:
- `cl`, `link`, `vswhere`, `clang` and `gcc` were not on PATH (MinGW, Strawberry and LLVM were stripped from PATH).
- These directories were renamed (about 7 s): `C:\Program Files\Microsoft Visual Studio`, `C:\Program Files (x86)\Microsoft Visual Studio`
  (which contains vswhere), `C:\Program Files (x86)\Windows Kits`, `C:\ProgramData\Microsoft\VisualStudio`
  and `C:\Program Files\LLVM`.
- These registry keys were renamed: `HKLM\...\Windows Kits`, `Microsoft SDKs\Windows`, `VisualStudio`
  (both views), and the VS Setup COM CLSID `{177F0C4A-...}`.

## Sizes and timings (setup-stats.json from the runs)

| | x64 | arm64 |
|---|---|---|
| Swift installer download | 2003 MB (about 6 s on runner) | 1551 MB |
| Swift extract (carve + expand + msiexec /a) | 88 s | 81 s |
| Swift on disk (asserts toolchain, lldb, python, sourcekit-lsp, Windows SDK for all 3 arches) | 4.4 GB | 4.2 GB |
| xwin download (CRT + its SDK, SDK then discarded) | 312 MB, 85 s | 357 MB, 72 s |
| NuGet SDK download (headers + arch libs) | 204 MB, 10 s | 255 MB, 9 s |
| sysroot on disk (CRT + SDK) | 648 MB | 967 MB |
| **total setup** | **191 s, 5.1 GB on disk** | **170 s, 5.1 GB** |
| MSVC / Windows SDK versions | 14.44.17.14 / 10.0.28000.0 | same |

The disk footprint could be cut a lot by not extracting `dbg`/`ide`/`python` and by trimming the non-host SDK
arches from `windows.msi`.

## Pitfalls hit along the way
1. Burn `/layout` does not produce the MSIs. Carve the containers instead.
2. libarchive (Windows `tar.exe`) fails on the LZX CABs; `expand.exe -F:*` works.
3. Burn puts the original signature between the UX and attached containers. Search for `MSCF` with the expected size.
4. `msiexec /a` error 1603 was caused by MAX_PATH. Stage in a short directory.
5. The runtime MSI's admin image puts its files at the TARGETDIR root, not under `Runtimes\`.
6. The Swift 6.4 SDK ships `winsdk_um.modulemap` + `winsdk_shared.modulemap`. There is no single `winsdk.modulemap`
   any more.
7. Backslashes in `clang.cfg` are escapes. A Windows path silently turned into garbage, and *every* compile failed,
   including the Swift ClangImporter, which also reads `clang.cfg`.
8. PowerShell variables are case-insensitive. `foreach ($f in $F)` clobbers `$F`. This was a test-harness bug,
   not a Swift bug.

## Recommended upstream changes (to make this seamless)
1. **LLVM `MSVCPaths.cpp`:** honour `UniversalCRTSdkDir`/`UCRTVersion`/`WindowsSdkDir`/`WindowsSDKVersion`
   (the vcvars variables) when locating the UCRT/WinSDK, and/or read `HKCU`. Today only flags or the HKLM registry
   (admin) work, so a per-user SDK is invisible to the Swift frontend's modulemap injection.
2. **Swift driver / SwiftPM:**
   - Add a persistent way to set the Windows SDK and VC roots for all jobs. Options include an environment variable
     (e.g. `SWIFT_WINDOWS_SDK_ROOT`), a Swift SDK `toolset.json`, or keys in the Windows platform `Info.plist`
     or `SDKSettings.json`.
   - Forward them to the link job and to generated jobs (the test runner and `test_anchor`), and to swift-build's
     clang jobs.
   - Support `/winsysroot`-style roots directly (a single `-windows-sys-root`).
3. **swiftc linking:** default to `-use-ld=lld` on Windows when `link.exe` is not found, as SwiftPM already does.
   The `program not executable` error is opaque.
4. **Fix the VFS overlay assertion** ("Paths should not contain traversal components") when the overlaid modulemap
   already exists on disk and `-windows-sdk-root`/`-visualc-tools-root` are also given.
5. **Distribution:**
   - Publish the MSIs/CABs (or a zip) alongside the bundle so a portable install doesn't need Burn carving.
   - Fix the `rtl` MSI's admin-image directory layout.
   - Consider shipping a "fetch CRT + SDK" helper (NuGet for the SDK + CRT from the VS manifest) as an
     officially supported alternative to the VS dependency.
6. **xwin:** its SDK splat drops `corecrt_math.h` (and possibly more), so it is not usable as-is with Swift's
   `ucrt.modulemap`. Report this to xwin, or keep using NuGet for the SDK.

## Files
- `xwin/setup-portable-swift.ps1`: setup script (portable Swift + CRT/SDK + modulemaps + clang.cfg + activate scripts).
- `xwin/hide-vs.ps1`: CI-only VS/SDK hider. `xwin/clean-env.ps1`: minimal fresh-shell environment.
- `xwin/run-tests.ps1`, `xwin/tests/`: the test matrix.
- `.github/workflows/xwin-sysroot.yml`: x64 + arm64 matrix (push to `exp/xwin-sysroot`, workflow_dispatch).
