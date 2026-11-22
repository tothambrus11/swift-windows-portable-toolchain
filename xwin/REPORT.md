# Swift on Windows without Visual Studio: portable toolchain + MSVC CRT + Windows SDK

**Verdict: it works, and Foundation works including optimized builds.** On GitHub `windows-latest` (x64)
and `windows-11-arm` (arm64) runners, Visual Studio, Build Tools, the Windows Kits and their registry keys
were hidden. The official Swift 6.4.3 toolchain then built and ran every required case in the matrix:
- plain `swiftc`, debug and `-O`/`-Osize`
- **Foundation**
- `import WinSDK`
- SwiftPM `build`/`run`/`test` (XCTest and swift-testing), on both build systems
- SwiftPM C targets and plain `clang`
- C++ interop with `<vector>`

How the setup works:
- **Downloads:** everything comes from swift.org, the Visual Studio channel manifest and nuget.org. No VS
  installer, no xwin or other third-party binary, and no registry writes.
- **Admin rights:** none needed. This was verified with a separate standard user account.
- **Cost:** about 115 s (x64) or 180 s (arm64), 2.3 GB of downloads and about 2.9 GB on disk.

Earlier this report listed an `-O`/Foundation link failure. It was **not a Swift or optimizer problem**.
`swiftc foundation.swift -o foundation.exe` makes the linker write `foundation.lib`. That import library then
shadows the SDK's `Foundation.lib` for every later link in the same directory. Visual Studio's `link.exe`
behaves the same way. See [Optimized builds](#optimized-builds-the--o-foundation-link-failure).

**Runs:**
- **Latest all-green run** (4 jobs: x64 minimal, arm64 minimal, x64 full+no-asserts+overlay, control with
  VS present; includes the non-admin check):
  https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44970391938
- **Follow-up investigation runs:**
  - [44963540609](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44963540609): first run of the VS-manifest CRT and minimal components. SwiftPM failed with error 14001 and `libcmt.lib` was missing. The VFS crash was isolated to a forward-slash `clang.cfg`.
  - [44964216949](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44964216949): side-by-side (SxS) manifest diagnosis. FoundationXML and swiftRegexBuilder were missing.
  - [44964875767](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44964875767): the minimal set became green for SwiftPM. The control job with VS showed that `foundation.swift -O` passes in a fresh directory.
  - [44966187313](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44966187313): **root cause of the `-O` failure confirmed** (foundation.lib shadowing). It reproduces with VS too.
  - [44968684638](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44968684638): overlay mode and no-asserts verified. Non-admin got as far as SwiftPM (setup OK, then a `TEMP` path problem).
  - [44969604338](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44969604338): non-admin environment fix, attempt 1.
- **First investigation** (kept for its failure evidence):
  - [44954697438](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44954697438): first green run, using xwin.
  - [44943076851](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44943076851): Burn `/layout` produced no MSIs.
  - [44944519038](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44944519038): `msiexec /a` error 1603 (MAX_PATH).
  - [44945773387](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44945773387): env vars only.
  - [44951635240](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44951635240): driver flags.
  - [44952836955](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44952836955): a backslash in `clang.cfg` broke the path.

## How to use

```powershell
powershell -ExecutionPolicy Bypass -File xwin\setup-portable-swift.ps1 -Target $env:LOCALAPPDATA\swift-portable -AcceptLicense
. $env:LOCALAPPDATA\swift-portable\activate.ps1      # or: call %LOCALAPPDATA%\swift-portable\activate.bat
swift build; swift run; swift test                    # no extra flags needed
```

**License gate.** Before any large download, the script prints the licenses that apply and **refuses to run
without `-AcceptLicense`**. CI verifies that it fails and downloads nothing without the switch.
- Swift: Apache-2.0 with Runtime Library Exception.
- MSVC C++ runtime: the Visual Studio Build Tools license, https://go.microsoft.com/fwlink/?LinkId=2179911.
  This URL is read live from the channel manifest.
- Windows SDK: https://aka.ms/WinSDKLicenseURL, read live from the NuGet `.nuspec`.

`-AcceptMicrosoftLicense` still works as an alias.

Options:

| option | effect |
|---|---|
| `-SwiftVersion 6.4.3` | default: the latest version from `swift.org/api/v1/install/releases.json` |
| `-Arch x64\|arm64` | default: the host architecture |
| `-Components bld,cli,rtl,windows` | default; this is the minimal working set |
| `-Full` | adds `dbg` (lldb), `python`, `ide` (sourcekit-lsp) and `res` |
| `-NoAsserts` | uses the no-asserts toolchain build (about 530 MB smaller) |
| `-KeepOtherArchs` | keeps the x86/other-arch SDK slices and `Redistributables\*.msm` |
| `-NoDedupe` | keeps duplicate binaries instead of hard-linking them |
| `-ModulemapMode copy\|overlay` | `copy` is the default; see below |
| `-CrtSource vsmanifest\|xwin` | the default reads the VS manifest directly |
| `-VsChannelUrl` | channel to read (default `https://aka.ms/vs/17/release/channel`) |
| `-CrtVersion` | pins the MSVC CRT version |
| `-NoStaticCrt` | skips libcmt and friends; `swift` still works, plain `clang foo.c` does not |
| `-IncludeDebugLibs` | keeps the debug CRT libraries |
| `-NugetSdkVersion` / `-SdkVersion <prefix>` | pins the Windows SDK version |
| `-KeepDownloads` | keeps the downloaded files |

## What the script does
1. **Swift toolchain: portable extraction of the official installer.**
   - Downloads `swift-<ver>-RELEASE-windows10[-arm64].exe` (a WiX Burn bundle).
   - Carves its CAB containers out of the PE file. This uses the `.wixburn` section header, and skips the
     Authenticode blob that sits between the containers. The other toolchain flavour's container (650 MB) is skipped.
   - Expands the CABs with `expand.exe`, and maps payload ids to MSI names using the Burn manifest.
   - Extracts each wanted MSI with `msiexec /a` (an administrative install) into a short staging directory,
     because deep paths fail with MAX_PATH error 1603.
   - Merges the per-user `LocalApp\Programs\Swift\...` trees into `<Target>\Swift`, and gives the runtime MSI's
     files their standard `Runtimes\<ver>\usr\bin` home.
2. **Missing side-by-side assemblies are borrowed (new).** The toolchain's Swift tools load their runtime as SxS
   assemblies from `usr\bin\<name>\<name>.dll`.
   - **Packaging bug found:** `swift-build.exe` and `swift-test.exe` (in `cli.msi`) need `FoundationXML` and
     `swiftRegexBuilder`, but only `ide.msi` ships them. Without `ide`, every `swift build` fails with
     `exec error: Unknown error (14001)` ("side-by-side configuration is incorrect").
   - The script reads the manifests of the exes in the toolchain, then extracts just the missing assembly
     directories from `ide`/`dbg`.
   - Result: `sxs_assemblies_borrowed: {FoundationXML: ide.asserts.msi, swiftRegexBuilder: ide.asserts.msi}`.
3. **Pruning (new).**
   - `windows.msi` carries the Swift SDK for x86, x64 and arm64. Only the target architecture is kept: the
     `usr\lib\swift[_static]\windows\<arch>` dirs, the XCTest/Testing `bin32|bin64|bin64a` dirs and the
     `<arch>-unknown-windows-msvc.swift*` files.
   - The `Redistributables` (.msm) are removed.
   - Identical binaries are hard-linked. The installer ships byte-identical copies under several names:
     `swift-frontend`, `swift-autolink-extract`, `swift-api-digester` and `swift-symbolgraph-extract` at 158 MB
     each, plus the clang and lld drivers.
4. **MSVC CRT straight from the Visual Studio channel manifest (new; replaces xwin).**
   - Reads `https://aka.ms/vs/17/release/channel` to find the `VisualStudio.vsman` URL (30 MB of JSON).
   - A regex picks out the payload URLs. This works in Windows PowerShell 5.1 too.
   - Downloads only three packages:
     - `Microsoft.VC.<ver>.CRT.Headers.base` (2 MB): vcruntime and STL headers.
     - `Microsoft.VC.<ver>.CRT.<arch>.Store.base` (28 MB). Despite the name, it holds the *desktop* DLL import
       libs `msvcrt.lib`, `vcruntime.lib`, `msvcprt.lib` and `oldnames.lib`.
     - `Microsoft.VC.<ver>.CRT.<arch>.Desktop.base` (51 MB): the static `libcmt` etc. This is skipped with `-NoStaticCrt`.
   - Each download is checked against the sha256 embedded in its URL.
   - The PDBs (about 150 MB), the debug-CRT libs and the store/uwp/enclave variants are dropped.
   - This removes the xwin binary dependency. xwin is x64-only and ran emulated on arm64. It also downloaded a
     312 MB SDK that was then thrown away.
5. **Windows SDK from Microsoft's NuGet packages.**
   - `Microsoft.Windows.SDK.CPP` provides the headers; only `c/Include` is extracted.
   - `Microsoft.Windows.SDK.CPP.<arch>` provides `c/ucrt` and `c/um`.
   - Version 10.0.28000.2957 was used, laid out as `Windows Kits\10\{Include,Lib}\10.0.28000.0`.
6. **Modulemaps.** Swift's `ucrt`, `winsdk_um`, `winsdk_shared` and `vcruntime` modulemaps (plus
   `vcruntime.apinotes`) must be visible next to the headers.
   - `copy` (default) copies them in.
   - `overlay` (new, verified) leaves the SDK tree untouched. It writes `winsysroot\swift-modulemaps.vfsoverlay.yaml`
     and references it from `clang.cfg` as `-ivfsoverlay`. The Swift ClangImporter honours `clang.cfg`, so
     swiftc, SwiftPM (`swift test` included) and C targets all work.
7. **`clang.cfg` and `clang++.cfg` next to the toolchain's `clang.exe`.** They contain `-fuse-ld=lld` and
   `-Xmicrosoft-windows-sys-root "C:\\...\\winsysroot"`, plus `-ivfsoverlay` in overlay mode.
   - **Use escaped backslashes, not forward slashes.** A forward-slash sysroot here crashes the frontend's VFS
     overlay; see [the VFS assertion](#the-vfs-assertion-paths-should-not-contain-traversal-components).
8. **`activate.ps1` / `activate.bat`.** They set `PATH`, `SDKROOT` and the vcvars-style variables.

## Optimized builds: the `-O` Foundation link failure

**Symptom**, from the first report:
`swiftc -O foundation.swift -o foundation-o.exe` failed with
`lld-link: error: undefined symbol: __declspec(dllimport) $s10Foundation13DateFormatterCACycfc`, plus
NumberFormatter, NSString, NSNumber and `String(format:)`. SwiftPM `-c release` passed.

**Hypotheses tested and ruled out** in `xwin/optimize-probe.ps1`, which runs in a fresh directory in both the
portable jobs and the VS control job:
- **Optimizer or cross-module optimization (CMO):** ruled out. In a fresh directory, `-O`, `-Osize`,
  `-O -disable-cmo` and `-Onone -wmo` all link and run, both portable and with VS.
- **Module split** (FoundationEssentials vs Foundation vs FoundationInternationalization): ruled out. The
  `-O` object references `__imp_$s10Foundation13DateFormatterCMa` and `...CACycfc` in `Foundation`. `llvm-nm`
  shows that the SDK's `Foundation.lib` exports exactly these symbols (`T __imp_$s10Foundation13DateFormatterCACycfc`).
  So there is no swiftmodule/import-lib mismatch.
- **An explicit `import FoundationEssentials`, a module name clashing with "foundation", missing `-lFoundation`:**
  all ruled out. These were tested in isolation and all pass in a fresh directory.

**Actual root cause.** The test matrix first ran `swiftc foundation.swift -o foundation.exe` (case b) in the
same working directory.
- A Swift executable exports its public symbols, so the linker also writes an **import library for the
  executable**: `Creating library foundation.lib and object foundation.exp`.
- Every later program in that directory autolinks `Foundation.lib` (from the `/DEFAULTLIB:Foundation.lib`
  directive). Windows file names are case-insensitive, and lld-link, like MSVC link.exe, searches the
  **current directory before `-libpath`**.
- The linker therefore picks up the executable's tiny `foundation.lib` instead of the SDK's, and the Foundation
  symbols are undefined.
- It hit the `-O` cases (b2–b4) only because they ran after b. Debug builds failed the same way when they ran
  after b (cases h, v7 and w1 in runs 44964216949 and 44964875767).
- SwiftPM is immune because products and import libs live under `.build\...`.

The probe proves it. **The same thing happens with Visual Studio installed and the official installer**
(control job, MSVC `link.exe`):
```
shadow 1: swiftc repro.swift -o foundation.exe   ->  "Creating library foundation.lib and object foundation.exp"
shadow 2: swiftc -O    repro.swift -o other1.exe ->  error LNK2019: unresolved external symbol __imp_$s10Foundation13DateFormatterCMa ... (FAIL)
shadow 3: swiftc -Onone repro.swift -o other0.exe -> same (FAIL)
shadow 4: del foundation.lib; swiftc -O ...       ->  OK
shadow 5: swiftc ... -o foundation.exe -Xlinker /noimplib, then swiftc -O ...  ->  OK
```

**Fix in this repo:** the test's executable is now named `fdemo.exe`. With that, all of b, b2 (`-O`), b3
(`-O -disable-cmo`), b4 (`-Osize`), h and v7 pass on x64 and arm64.

**Workarounds for users:**
- Don't name an executable after an SDK module (Foundation, Dispatch, XCTest, WinSDK, ...) in a directory you
  link from.
- Or pass `-Xlinker /noimplib`.
- Or build in separate directories.

**Draft upstream issue (swiftlang/swift-driver; not filed):**
> **Windows: linking an executable named like an SDK module (e.g. `foundation.exe`) breaks later links in the same directory**
>
> ```
> echo import Foundation; print(DateFormatter().dateFormat ?? "") > repro.swift
> swiftc repro.swift -o foundation.exe     # lld/link: "Creating library foundation.lib and object foundation.exp"
> swiftc repro.swift -o other.exe          # error: undefined symbol __imp_$s10Foundation13DateFormatterCMa
> ```
> Swift executables export their public symbols, so the linker emits `<exe>.lib`/`<exe>.exp` next to the
> output. Because `foundation.lib` == `Foundation.lib` on a case-insensitive file system, and the MSVC linker
> searches the CWD before `/LIBPATH`, the autolinked `Foundation.lib` now resolves to the executable's import
> library. This is reproducible with Swift 6.4.3 + VS 2022/2026 (link.exe) and with lld-link.
> **Suggestion:** for `-emit-executable`, have the driver pass `/noimplib` (or emit the import library under the
> temporary/intermediate directory) unless an import library is explicitly requested. Alternatively, diagnose
> an output name that matches an autolinked library.

## The VFS assertion "Paths should not contain traversal components"

**Symptom** (asserts toolchain):
```
Assertion failed: !isTraversalComponent(*Start) && !isTraversalComponent(From->getName()) && "Paths should not
contain traversal components", file ...\llvm-project\llvm\lib\Support\VirtualFileSystem.cpp, line 2348
```
This came from `swift-frontend -frontend -c ...`. It happened when `-windows-sdk-root`/`-visualc-tools-root`
were used on top of our setup.

**Isolation matrix** (the `v*` cases; identical on x64 and arm64):

| case | sysroot given to clang via | spelling | VFS overlay active? | result |
|---|---|---|---|---|
| v1/v2 | no sysroot in `clang.cfg` (lld only) | – | yes (flags) | OK |
| v3 | `clang.cfg` `-Xmicrosoft-windows-sys-root` | `C:/...` forward slashes | yes (flags) | **assertion** |
| v4/v5 | `clang.cfg` | `C:\\...` escaped backslashes | yes (flags), with or without physical modulemaps | OK |
| v6/v7 | `clang.cfg` (backslashes), flags spelled with forward slashes | mixed | yes | OK |
| v10/v11 | `-Xcc -Xmicrosoft-windows-sys-root -Xcc C:/...` (no cfg) | forward / back | yes (flags) | OK (no crash) |
| v12 | `-Xcc` sysroot (forward) + empty `-Xcc -ivfsoverlay` | forward | yes | OK (no crash) |
| (run 44963540609) w1 | `clang.cfg` forward-slash sysroot + `-ivfsoverlay` in cfg, no flags | forward | yes (overlay) | **assertion** |

(v8, v10 and v12 show up as "FAIL" in the tables only because they expect a crash that does not happen.)

**Cause.**
- The crash needs a **forward-slash MSVC sysroot that reaches the clang driver through the config file**, plus a
  Swift-created VFS overlay.
- The Swift ClangImporter builds its own clang driver to compute the MSVC/UCRT include directories it overlays
  its modulemaps onto. That driver reads `clang.cfg` but not `-Xcc` options.
- With a forward-slash sysroot it returns `C:/...`-style paths. These are mixed with backslash file names when
  the RedirectingFileSystem entries are built and looked up, and the asserts build trips over the result.

**Fix in this repo:** write the sysroot with escaped backslashes in `clang.cfg`. A backslash is an escape
character in clang config files, which is why forward slashes were used originally. Path normalization in the
script avoids the crash completely.

**Draft upstream issue (swiftlang/swift; not filed):**
> **[Windows] swift-frontend asserts in RedirectingFileSystem when the MSVC sysroot comes from a clang config file with forward slashes**
>
> Put `-Xmicrosoft-windows-sys-root "C:/sdk/winsysroot"` into `<toolchain>\usr\bin\clang.cfg`, then run
> `swiftc -windows-sdk-root "C:\sdk\winsysroot\Windows Kits\10" -windows-sdk-version 10.0.28000.0 -visualc-tools-root C:\sdk\winsysroot\VC\Tools\MSVC\14.44.35207 -visualc-tools-version 14.44.35207 hello.swift`.
> The asserts toolchain fails `VirtualFileSystem.cpp:2348` ("Paths should not contain traversal components").
> The same sysroot passed via `-Xcc`, or written with backslashes, works.
> Swift's Windows modulemap injection (ClangIncludePaths.cpp) should canonicalize the clang-driver-derived
> include paths (`llvm::sys::path::native` + `remove_dots`) before building the overlay.

## Simplifications: before → after

The "before" column is the first report (run 44954697438). The "after" column is the current default (run
44970391938). Sizes are in MB on the runner. "Unique" counts each hard-linked file once.

| | before x64 | **after x64** | after arm64 | after x64 `-Full -NoAsserts -ModulemapMode overlay` |
|---|---|---|---|---|
| third-party tools needed | xwin (Rust binary, x64 only) | **none** (curl, tar, expand and msiexec ship with Windows) | none | none |
| Swift installer download | 2003 | 2003 | 1551 | 2003 |
| MSVC CRT download | 312 (xwin: CRT + an SDK that was discarded) | **77** (30 with `-NoStaticCrt`) | 106 | 77 |
| Windows SDK download | 204 | 204 | 255 | 204 |
| **total download** | **≈2519** | **≈2284** | ≈1912 | ≈2284 |
| MSIs extracted | 8 (bld, cli, dbg, ide, python, res, rtl, windows) | **4** (bld, cli, rtl, windows) + 2 assembly dirs from ide | 4 + 2 | 8 |
| Swift on disk | 4427 | 3566 after extraction → 2974 after arch pruning → **2276 unique** after dedupe (−698 hard links) | 2107 unique | 2554 unique |
| CRT + SDK on disk | 648 | **642** (CRT 102, SDK 539) | 949 | 642 |
| **total on disk** | **5075** | **2918 unique** (3615 counting hard links twice) | 3056 unique | 3196 unique |
| setup time | 191 s | **114 s** | 182 s | 98 s |
| works as a non-admin user | not tested | **yes** (see below) | – | – |

What is still big, and why:
- The asserts toolchain's `usr\bin` holds full copies of LLVM inside each tool: `_InternalSwiftScan.dll` 158 MB,
  `libclang.dll` 91 MB, `clang-tidy` 67 MB, `LTO.dll` 70 MB, `dsymutil` 48 MB.
- `-NoAsserts` saves about 530 MB more, verified green in the "full" job.
- The download size is dominated by the monolithic Burn bundle, which can't be fetched partially. Downloading
  is fast (about 6 s on a runner); the cost is the extraction (about 80 s).

## Non-admin verification (new)

The x64 job runs the **whole setup plus `swift run FoundationDemo` plus `swift test`** as a freshly created
standard local user, `swiftnonadmin`.
- It was started with `Start-Process -Credential`.
- `whoami /groups` shows `Mandatory Label\Medium Mandatory Level`.
- Writing to `%SystemRoot%` is denied.
- Result: `NONADMIN OK` in 209 s. So the Burn carving, `msiexec /a` (administrative extraction) of 4+1 MSIs,
  the CRT and SDK fetch, and builds and tests all work **without admin rights**.

Note: `Start-Process -Credential` inherits the caller's environment. The test points `TEMP`, `LOCALAPPDATA`,
`APPDATA` and `USERPROFILE` at the user's own directories; the first attempt failed until it did. A scheduled
task with `/rl LIMITED` never started (`Last Result 267011`), because the new account lacks
SeBatchLogonRight. The script itself needs no changes for non-admin use.

## Test matrix (run 44970391938)

The x64, arm64 and x64-full jobs gave identical results for all required cases.

| case | result |
|---|---|
| a hello | PASS |
| b Foundation (`swiftc`, debug): JSON Codable + ISO8601 Date, FileManager, URL, Data/base64, `String(format:)`, DateFormatter, NumberFormatter, `Date.now.formatted()`, UUID | **PASS** |
| b2/b3/b4 Foundation `swiftc -O` / `-O -disable-cmo` / `-Osize` | **PASS** (was FAIL; see root cause) |
| c `import WinSDK` | PASS |
| d1–d4b SwiftPM build/run/test (XCTest: 2 tests, swift-testing: 1 test)/release, FoundationDemo debug + release | PASS |
| d5/d6 `--build-system native` run + test | PASS |
| e/e2 SwiftPM C target (both build systems) | PASS |
| f C++ interop (`std::vector`, `std::string`, CxxStdlib) | PASS |
| g/g2/g3 plain `clang plain.c`: with env, with INCLUDE/LIB unset, explicit `-fms-runtime-lib=dll` | PASS |
| h/h2 explicit `-windows-sdk-root ...` flags on top of the setup | PASS (the VFS assertion is fixed) |
| w1–w4 modulemaps through `-ivfsoverlay` in `clang.cfg` instead of copies (swiftc, `swift test`, C target) | PASS |
| fresh `cmd` with PATH=System32, `call activate.bat`, `swift build -c release && swift run` | PASS |
| license gate without `-AcceptLicense` | refuses, nothing downloaded |
| non-admin setup + build + test (x64) | PASS |
| r0–r2 registry-only variants (informational) | FAIL as before; the registry is not a viable route |

## Recommended upstream changes
Points 1–4 below come from the first report and still apply.
1. **LLVM `MSVCPaths.cpp`:** honour the vcvars environment variables and/or HKCU, so a per-user SDK is found.
2. **Swift driver / SwiftPM:**
   - Provide a persistent way to set the Windows SDK and VC roots, forwarded to every job (link, test runner, swift-build clang jobs).
   - Support a winsysroot-style root.
3. **swiftc:** default to lld when `link.exe` is absent.
4. **Distribution:**
   - Publish the MSIs or a zip.
   - Fix the rtl MSI's admin layout.
   - Consider an official "fetch CRT + SDK" path. NuGet covers the SDK, and three VS-manifest packages cover the CRT.

New from this follow-up:

5. **Installer packaging:** `cli.msi`'s `swift-build`/`swift-test` depend on the `FoundationXML` and
   `swiftRegexBuilder` side-by-side assemblies, which only `ide.msi` ships. Installing without sourcekit-lsp
   gives a toolchain where `swift build` fails with error 14001. Ship those assemblies in `cli.msi`, or make
   `cli` depend on them.
6. **Installer size:** ship the identical tool binaries once, as hard links or a multi-call binary. About 700 MB
   per toolchain is duplicated.
7. **The executable import-library shadowing above:** have the driver pass `/noimplib` for executables.
8. **The VFS path normalization above.**
9. **xwin:** its SDK splat lacks `corecrt_math.h`. It isn't needed any more for this use case, because the CRT
   now comes straight from the VS manifest.

## Files
- `xwin/setup-portable-swift.ps1`: setup script. It covers the license gate, Burn carving, `msiexec /a`, SxS
  assembly borrowing, arch pruning, hard-link dedupe, the VS-manifest CRT, the NuGet SDK, modulemaps (copy or
  overlay), `clang.cfg` and the activate scripts.
- `xwin/run-tests.ps1` and `xwin/tests/`: the test matrix, plus the VFS/overlay/registry/flags probes.
- `xwin/optimize-probe.ps1`: `-O` investigation and the foundation.lib shadowing repro.
- `xwin/nonadmin-check.ps1`: the non-admin end-to-end check.
- `xwin/hide-vs.ps1` and `xwin/clean-env.ps1`: the honest CI environment.
- `.github/workflows/xwin-sysroot.yml`: jobs for x64 minimal, arm64 minimal, x64 full+no-asserts+overlay, and
  the control job with VS present.
