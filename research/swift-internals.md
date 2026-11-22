# Swift on Windows: where the toolchain depends on MSVC and the Windows SDK (source-level map)

Snapshot read on 2026-11-21: `swiftlang/swift@9a9c2e9a` (main), `swiftlang/swift-driver@053868d4`, `swiftlang/swift-installer-scripts@868b574f`, `swiftlang/llvm-project@next`, plus `swift-package-manager`, `swift-build` and `swift-corelibs-foundation` at main. Line numbers refer to those revisions. Sizes were measured on this machine: Windows SDK 10.0.22621.0 and MSVC 14.44.35207, both x64.

---

## 1. How the toolchain finds MSVC and the Windows SDK

The toolchain doesn't have one discovery routine. Three separate consumers each run their own lookup, and **all of them end up in LLVM's `llvm/lib/WindowsDriver/MSVCPaths.cpp`**.

### 1a. swift-frontend / ClangImporter (headers and modulemap injection)
- `swift/lib/ClangImporter/ClangIncludePaths.cpp`, `GetWindowsFileMappings()` (l.531). It returns immediately unless `Triple.isWindowsMSVCEnvironment()` (l.538).
  - SDK: `llvm::getWindowsSDKDir(VFS, getWinSDKRoot(), getWinSDKVersion(), /*WinSysRoot*/{}, …)` (l.560).
  - UCRT: `llvm::getUniversalCRTSdkDir(… same …)` (l.621).
  - VC tools: `findVCToolChainViaCommandLine(getVCToolsRoot(), getVCToolsVersion(), {})`, then `findVCToolChainViaEnvironment` (env `VCToolsInstallDir`, then `VCINSTALLDIR`, then a scan of `PATH` for `cl.exe`+`link.exe`), then `findVCToolChainViaSetupConfig` (the COM `ISetupConfiguration` API, i.e. what vswhere uses; it runs with the sandbox disabled) (l.650-664).
- `swift/lib/ClangImporter/ClangImporter.cpp` l.1074-1089 forwards the Swift options to the embedded clang as `-Xmicrosoft-windows-sdk-root/-version` and `-Xmicrosoft-visualc-tools-root/-version`. Upstream clang defines these as GNU-driver aliases of `/winsdkdir`, `/winsdkversion`, `/vctoolsdir` and `/vctoolsversion` (`clang/include/clang/Options/Options.td` ~l.10416). The fifth alias, `-Xmicrosoft-windows-sys-root` (= `/winsysroot`), **has no Swift option**.
- The options are defined in `swift/include/swift/Option/Options.td` l.257-276 (`-windows-sdk-root`, `-windows-sdk-version`, `-visualc-tools-root`, `-visualc-tools-version`) and parsed in `lib/Frontend/CompilerInvocation.cpp` l.2758-2764. They were added in `73cafebaf5` "Driver: introduce additional Windows controls" (2023-03-06, Swift 5.9).
- **Env vars are mostly ignored for the SDK.** In `MSVCPaths.cpp`, `getWindowsSDKDir` (l.417) and `getUniversalCRTSdkDir` (l.481) check the command line first and then **only the registry**: `HKLM\SOFTWARE\Microsoft\Microsoft SDKs\Windows\$VERSION\InstallationFolder` and `…\Windows Kits\Installed Roots\KitsRoot10`. Lines 431 and 493 are literal `FIXME: Try env vars (%WindowsSdkDir%, %UniversalCRTSdkDir%, %UCRTVersion%)`. The only env vars LLVM honors for the VC tools are `VCToolsInstallDir` and `VCINSTALLDIR`.
- Clang's own header search (`clang/lib/Driver/ToolChains/MSVC.cpp`, `AddClangSystemIncludeArgs` ~l.861) honors `%INCLUDE%`/`%EXTERNAL_INCLUDE%`, but only when none of the `/vctoolsdir`/`/winsdkdir`/`/winsysroot` options is given. Otherwise it adds SDK/UCRT include dirs only `if (!VCToolChainPath.empty())`.

**If nothing is found:** `GetWindowsFileMappings` quietly injects no modulemaps and emits no diagnostic. Plain C header search may still work through `%INCLUDE%`, but `import ucrt`, `import CRT` and `import WinSDK`, and therefore `_Concurrency`, Foundation and everything else, fail with "no such module". **An xwin/nuget-style sysroot with only `INCLUDE`/`LIB`/`WindowsSdkDir`/`UniversalCRTSdkDir` set is not enough for the importer. It has to receive `-windows-sdk-root`/`-windows-sdk-version` (and `-visualc-tools-root`, or `VCToolsInstallDir`).**

### 1b. swift-driver (new driver) / legacy C++ driver
- `swift-driver/Sources/SwiftDriver/Toolchains/WindowsToolchain.swift`: `defaultSDKPath()` (l.127) reads `SDKROOT`, which is the *Swift* `Windows.sdk` (Platforms/Windows.platform/…), not the Microsoft SDK. `lookupToolPath` (l.72) uses `clang` as the dynamic linker driver and `lld-link` as `.staticLinker`.
- `Jobs/FrontendJobHelpers.swift` l.181-195 forwards the four Windows options **to frontend jobs only**.
- `Jobs/WindowsToolchain+LinkerSupport.swift` `addPlatformSpecificLinkerArgs` (l.44): the link job runs `clang.exe --rsp-quoting=windows -target <triple> -nostartfiles … swiftrt.obj`. It does **not** forward `-windows-sdk-root` or `-visualc-tools-root` to that clang. Clang's `MSVCToolChain` ctor (`MSVC.cpp` ~l.528-555) therefore discovers VC through command line, env, SetupConfig, then registry. It adds `-libpath:` for VC/UCRT/SDK only when `%LIB%` is **unset** (`MSVC.cpp` l.160-184).
- The legacy driver mirrors this in `swift/lib/Driver/WindowsToolChains.cpp` (`constructInvocation(DynamicLinkJobAction)`, linker selection l.67-111) and `lib/Driver/ToolChains.cpp` `addRuntimeLibraryFlags` (l.454).
- **swift-build** (`Sources/SWBWindowsPlatform/VSInstallation.swift`, `Plugin.swift` `WindowsEnvironmentExtension`) runs `vswhere.exe` from the fixed `%ProgramFiles(x86)%\Microsoft Visual Studio\Installer` path and injects `VCToolsInstallDir=<latest VS>\VC\Tools\MSVC\<latest>`. Its README states "you must install any edition of Visual Studio".
- **SwiftPM** (`Sources/PackageModel/UserToolchain.swift` l.598-730) reads `SDKROOT` → `SDKSettings.plist` (default `-libc`) and `Windows.platform/Info.plist` (`SWIFTC_FLAGS`, XCTest/Testing paths). It never mentions the Microsoft SDK.
- **build.ps1** (`swift/utils/build.ps1`) requires VS for building the toolchain: `vswhere` (l.665), `Enter-VsDevShell` (l.1723-1738). There is **precedent for a non-installed SDK**: with `-WinSDKVersion`, if VsDevShell can't resolve that SDK, it `nuget install`s `Microsoft.Windows.SDK.CPP[.<arch>]` (l.2069-2089) and sets `WindowsSdkDir`, `UniversalCRTSdkDir`, `UCRTVersion`, `INCLUDE`, `LIB` and related variables by hand (l.1740-1759). MSVC itself still comes from VS.

## 2. Modulemaps, apinotes and the VFS overlay

Files live in `swift/stdlib/public/Platform/`: `ucrt.modulemap`, `SwiftUCRT.h`, `vcruntime.modulemap` (which also holds `module std` for the MSVC STL), `vcruntime.apinotes`, `winsdk.modulemap` (17 lines: `extern module UM "um.modulemap"`, `Shared`, `WinRT`), `um.modulemap` (752 lines), `shared.modulemap`, `winrt.modulemap`, `SwiftWinRT.h`, `WinSDK.apinotes`. They are installed to `<Windows.sdk>/usr/share/` (`Platform/CMakeLists.txt` l.572-585; installer manifest `platforms/windows/windows.wxs` l.1758-1767).

**How it works now:** `GetPlatformAuxiliaryFile()` (`ClangIncludePaths.cpp` l.510) locates each file in `<-sdk>/usr/share/` or `<resource-dir>/windows/`. `GetWindowsFileMappings` then maps them onto **virtual** paths inside the real SDK/VC dirs:
- `<SDK>/Include/<ver>/um|shared/module.modulemap`, `…/WinSDK.apinotes`, `…/winrt/module.modulemap`, `…/SwiftWinRT.h`
- `<UCRT>/Include/<ver>/ucrt/module.modulemap` and `…/SwiftUCRT.h`
- `<VCTools>/include/module.modulemap` and `…/vcruntime.apinotes`
- It also adds empty in-memory headers for STL/UCRT headers that older toolsets lack (`kInjectedHeaders`, l.696-718, e.g. `__msvc_*.hpp` for VS 17.x, `stdalign.h` for SDK 20348).

`getClangInvocationFileMapping()` (l.736) writes these into a YAML VFS overlay that clang receives as `-ivfsoverlay`. `ClangImporter.cpp` l.1459-1467 also adds `-fmodule-map-file=<virtual winsdk modulemap>`. Nothing is written to disk, so no admin rights are needed and an SDK update doesn't break anything.

**History:** before this, the installer ran a custom action (`platforms/Windows/CustomActions/SwiftInstaller/.../swift_installer.cc`) that **copied** the modulemaps into the VS and Windows Kits directories. Before that, users had to copy them manually as admin, and the copies broke on every SDK/VS update. The switch came in `swift@67d5deb110` "ClangImporter: inject modulemaps via the VFS" (2023-02-23), whose commit message says it is the "second step towards removal of the content injection into the Visual Studio installation". The options followed in `73cafebaf5` (2023-03-06), and the installer was updated in swift-installer-scripts PR #164 "WiX: Move WinSDK.modulemap into SDK" (merged 2023-03-09). All of this first shipped in **Swift 5.9**. In 2026-08 WinSDK was split into um/shared/winrt (`e96bdabfa0`, `2de797c52a`), and the builtin-header workaround was removed for Windows (`8bf8281136`).

The stdlib build has its own CMake-level overlay: `swift_windows_get_sdk_vfs_overlay` in `stdlib/cmake/modules/AddSwiftStdlib.cmake` l.1780.

## 3. Linking

- **CRT selection:** `-libc MD|MDd|MT|MTd` (aliases `MultiThreadedDLL`/`shared-ucrt` etc.), with `/MD` as the default. swift-driver `FrontendJobHelpers.swift` `addRuntimeLibraryFlags` (l.655-700) and legacy `Driver.cpp` l.1485-1509 / `ToolChains.cpp` l.454-492 make the frontend embed `-autolink-library oldnames` plus `-autolink-library msvcrt|msvcrtd|libcmt|libcmtd`, and add `-Xcc -D_MT [-D_DLL]`. These become `/DEFAULTLIB:` directives in each `.obj`. `msvcrt.lib` in turn pulls in `vcruntime.lib` and `ucrt.lib` (and `libcmt` pulls in `libvcruntime`/`libucrt`). The guard is `targetTriple.isWindows`, **not** `isWindowsMSVC`.
- **Embedded Swift** gets explicit `-l<crt> -loldnames` (`WindowsToolchain+LinkerSupport.swift` l.187-192).
- **C/C++ parts of the runtime:** `AddSwiftStdlib.cmake` l.1786-1789 / l.3293-3295 hard-code `-Xclang --dependent-lib=oldnames` and `--dependent-lib=msvcrt[d]` (comment: "TODO(compnerd) handle /MT, /MTd").
- **SDK import libs the runtime pulls in:**
  - swiftCore privately links `shell32;DbgHelp;Synchronization` (`stdlib/public/core/CMakeLists.txt` l.350-351).
  - `#pragma comment(lib, …)` brings in `DbgHelp.Lib` (`runtime/ImageInspectionCOFF.cpp`, `SymbolInfo.cpp`), `User32.Lib` (`RuntimeErrorReporting.cpp`), `bcrypt.lib` (`stubs/Random.cpp`), `OneCore.Lib` (`Concurrency/Clock.cpp`) and `dispatch.lib`.
  - The `ucrt` module autolinks `legacy_stdio_definitions` (`ucrt.modulemap` l.100). The `um.modulemap` submodules autolink about 50 `*.lib` files (kernel32, User32, AdvAPI32, WS2_32, Ole32, …).
  - CoreFoundation links `shell32 ole32`, and Foundation autolinks `swiftSynchronization`.
- **Linker choice:** swift-driver's link step invokes clang without `-fuse-ld` unless `-use-ld=lld`, LTO or profiling forces it (`WindowsToolchain+LinkerSupport.swift` l.56-84, l.149-153). Clang's MSVC default is `link.exe` (`MSVC.cpp` l.340-355; `getPreferredLinker()` is empty, and build.ps1 sets no `CLANG_DEFAULT_LINKER`). So **plain `swiftc` uses MSVC `link.exe`, located through the VS toolchain or PATH**. **SwiftPM builds use lld**, because build.ps1 writes `SWIFTC_FLAGS = -use-ld=lld` into `Windows.platform/Info.plist` (`build.ps1` `Write-PlatformInfoPlist` l.4446-4448) and SwiftPM appends it (`UserToolchain.swift` l.725). The **librarian** defaults to `link /LIB` in swift-driver (l.94), and in SwiftPM to `link` unless `-use-ld=` is present (`UserToolchain.swift` l.326-341).
- **`-static-stdlib`:** swift-driver links `swiftrtT.obj` instead of `swiftrt.obj` (l.217-221), against the static SDK variants (build.ps1 `WindowsSDKLinkModes dynamic,static`) and with `-DSWIFT_STATIC_STDLIB`. It still uses `/MD` by default. A fully static exe needs `-libc MT`, which requires `libcmt.lib` (6.2 MB), `libvcruntime.lib` (2.0 MB) and `libucrt.lib` (40.5 MB). The `--dependent-lib=msvcrt` baked into the runtime's C++ objects can then conflict (LNK4098-style).

## 4. C++ interop and the MSVC STL

- `lib/Frontend/CompilerInvocation.cpp` l.408-419 sets `CXXStdlib = Msvcprt` unconditionally for `isOSWindows()`, with the comment "In the future, we should support libc++ on Windows… (D101479)".
- `module std` for the MSVC STL lives in `vcruntime.modulemap` (from l.170) and is mapped into `<VCTools>/include/module.modulemap`. `stdlib/public/Cxx/std` (CxxStdlib) is built for `WINDOWS` against that module (`Cxx/std/CMakeLists.txt` l.86). The `libstdcxx` modulemap is Linux-only. STL headers autolink `msvcprt[d].lib` via `#pragma comment`.
- **libc++:** PR swiftlang/swift#76110 "[cxx-interop][windows] support using a custom libc++ on Windows" (open since 2024-08) uses `-cxx-isystem` and forbids CxxStdlib in that mode because the ABI differs. Even with libc++, the MSVC-ABI target still needs vcruntime (EH, RTTI, `operator new`, `<vcruntime*.h>`) and the UCRT. Swapping the STL doesn't remove the MSVC dependency. Only a MinGW target does that.

## 5. Runtime redistributables and installer behaviour

- The toolchain **bundles the VC++ runtime DLLs privately**. `rtl/dynamic/msi/rtl.dynamic.msi.wxs` has `ComponentGroup VCRuntime_<arch>` with `<Files Include="$(VCRedistDir)\**"/>`, installed into the runtime `usr\bin` and added to the user PATH. `build.ps1` l.6091-6093 fills `VCRedistDir` from `%VCToolsRedistDir%\<arch>\Microsoft.VC*.CRT`, i.e. vcruntime140/140_1 and msvcp140 from the build machine's VS.
- The Python package ships its own `vcruntime140*.dll` (`python/python.wxs` l.48-49).
- `bundle/installer.wixproj` l.6 still defines `VCRedistDownloadUrl` (`aka.ms/vs/<N>/release/vc_redist.<arch>.exe`), but nothing in the current `<Chain>` uses it (`installer.wxs` l.177-206). It looks vestigial.
- Redistributable merge modules for app deployment: `platforms/windows/windows.wxs` l.1777-1796 (`rtl.{dynamic,static}.{shared,private}.<arch>.msm`). Private is the default.
- **No VS/Build Tools prerequisite check or auto-install exists** in the bundle or MSIs; grep for vswhere/VisualStudio/BuildTools finds only the product name "Swift Build Tools". The bundle supports per-user installs (`InstallPerMachine=0`, `InstallRootPerUser`). VS is a documented manual prerequisite that the installer never checks.

## 6. Existing MinGW / windows-gnu support

There are leftover pieces, but nothing works end to end:
- **Triples:** swift-driver `Utilities/Triple.swift` l.110-147 normalizes `mingw32`/`cygwin` triples, and `Triple+Platforms.swift` l.412-417 maps `.gnu` to platform name `"mingw"`. The C++ side does the same in `lib/Basic/Platform.cpp` l.274-279 (GNU→`mingw`, Cygnus→`cygwin`). `lib/Basic/LangOptions.cpp` l.564-568 makes MinGW `os(Windows)`.
- **Toolchain selection:** swift-driver `Driver.swift` `toolchainType` l.3790 returns `WindowsToolchain` for any `.win32` (MSVC-specific). The legacy `Driver.cpp` l.442-445 routes only Cygwin to `toolchains::Cygwin` (GenericUnix) and sends MinGW to `toolchains::Windows`.
- **IRGen already has MinGW branches:**
  - `Linking.cpp` l.78-80 `useDllStorage()` is **false for CygMing**, so no dllimport/dllexport.
  - `IRGenModule.cpp` l.2096-2108 uses autolink-extract for CygMing.
  - `GenFunc.cpp` l.3175 and `IRGen.cpp` l.1286 have Cygwin cases.
  - The legacy `Driver.cpp` l.1866 schedules autolink-extract for CygMing. swift-driver doesn't (`AutolinkExtractJob.swift` l.20 `// FIXME: Also handle Cygwin and MinGW`).
- **stdlib:** there is a `CYGWIN` SDK (Glibc overlay, `Platform/CMakeLists.txt` l.13; `Concurrency` `SWIFT_MODULE_DEPENDS_CYGWIN Glibc`) but **no MINGW SDK**. `swiftCRT` (`ucrt.swift`, `@_exported import ucrt`) is `TARGET_SDKS WINDOWS` only.
- `GetWindowsFileMappings` bails out for non-MSVC, and `ClangImporter.cpp` l.835 adds `<sdk>/usr/include` only for MSVC.
- The runtime is mostly `_WIN32`-gated with `!defined(__CYGWIN__)` exclusions. There are only 3 `_MSC_VER` uses in `stdlib/public`, and no `__MINGW32__` anywhere.
- **Source-level conditionals:** nothing anywhere uses `canImport(MinGW)`. corelibs-foundation uses `#if os(Windows)` (98 sites) with `import WinSDK` (12 files) and `@_exported import CRT`/`import CRT`; `canImport(CRT)`/`canImport(WinSDK)` appear in only a few places. A MinGW port should therefore **provide modules named `CRT`, `ucrt` and `WinSDK`** over mingw-w64 headers to avoid touching the ecosystem.

## 7. Minimum MSVC + SDK file set (x64; measured SDK 10.0.22621, MSVC 14.44)

| Need | (a) hello world | (b) Foundation program | (c) SwiftPM package |
|---|---|---|---|
| UCRT headers `Include\<v>\ucrt` (1.0 MB) | yes: implicit `_Concurrency` depends on `CRT` (`Concurrency/CMakeLists.txt` l.273), which imports `ucrt` | yes | yes |
| MSVC `include` (14.8 MB; vcruntime headers plus STL, needed for `module std`/C++) | yes (UCRT includes `vcruntime.h`) | yes | yes |
| SDK `um` (121 MB) + `shared` (11.2 MB) headers | no | yes (Foundation/Dispatch `import WinSDK`) | yes (manifests import PackageDescription → Foundation) |
| SDK `winrt` (125 MB), `cppwinrt` (59 MB) | no | probably not (WinSDK's `extern module WinRT` may require the dir to exist; untested) | same |
| MSVC libs: `msvcrt.lib` 7.7 MB, `vcruntime.lib` 0.27, `oldnames.lib` 0.15, `legacy_stdio_definitions.lib` 0.45 | yes | yes | yes, plus `msvcprt.lib` 3.9 MB for C++ targets |
| UCRT `ucrt.lib` 0.27 MB | yes | yes | yes |
| SDK import libs: kernel32 0.30, user32, shell32, ole32, advapi32, dbghelp, synchronization, bcrypt, onecore 2.2, ws2_32, uuid 8.1 … | kernel32 at least | about 15-25 small libs (~5-15 MB) | same, plus whatever C targets use |
| Linker | `link.exe` (VC bin, 70 MB host dir) **or** `-use-ld=lld` (in the Swift toolchain) | same | lld by default (Info.plist) |
| Static `-libc MT` extras | `libcmt` 6.2, `libvcruntime` 2.0, `libucrt` 40.5 MB | | |

Rough totals: **(a) about 25 MB**, **(b)/(c) about 160-175 MB** with full um/shared headers and a pruned lib set. The full MSVC `lib\x64` is 295 MB, mostly static, debug and store/uwp variants, and the full SDK `um\x64` libs are 111 MB, so pruning matters a lot. The headers can't be trimmed below what `um.modulemap` lists, because a missing header in a module fails the module build. Runtime DLLs (vcruntime140*.dll, msvcp140.dll) are already shipped by the Swift runtime MSI.

---

## Concrete code changes

### (A) Seamless user-local MSVC + SDK sysroot (xwin / nuget layout, no VS)

1. **Add `-windows-sys-root <dir>`** (and an env or SDKSettings default; see 5) to `swift/include/swift/Option/Options.td` and swift-driver `Options.swift`. Store it in `SearchPathOptions`. In `ClangIncludePaths.cpp`, pass it as the currently hard-coded `{}` WinSysRoot argument of `getWindowsSDKDir` (l.560), `getUniversalCRTSdkDir` (l.621) and `findVCToolChainViaCommandLine` (l.650). In `ClangImporter.cpp` (next to l.1074), emit `-Xmicrosoft-windows-sys-root`. This matches clang's `/winsysroot` layout (`VC/Tools/MSVC/<v>`, `Windows Kits/10`), which `xwin splat --use-winsysroot-style` produces.
2. **Forward the Windows options to the link job.** In `WindowsToolchain+LinkerSupport.swift` `addPlatformSpecificLinkerArgs` (and legacy `WindowsToolChains.cpp`), append `-Xmicrosoft-windows-sdk-root/-version`, `-Xmicrosoft-visualc-tools-root/-version` and `-Xmicrosoft-windows-sys-root` to the clang link command. Clang then emits the right `-libpath:` values without `%LIB%` or VS.
3. **Make lld the default on Windows.** Set `bUseLLD` default true, or `-fuse-ld=lld` unless `-use-ld` is given (`WindowsToolchain+LinkerSupport.swift` l.80-84, legacy `WindowsToolChains.cpp` l.92-97). Default the librarian to `lld-link /lib` (l.89-95) and SwiftPM's to `lld-link` (`UserToolchain.swift` l.341); swift-build's tool lookup needs the same. Alternatively, build clang with `CLANG_DEFAULT_LINKER=lld` in build.ps1. This removes the need for `link.exe` and the 70 MB VC `bin`.
4. **Env-var fallback.** Implement the `FIXME`s in `llvm/lib/WindowsDriver/MSVCPaths.cpp` l.431 and l.493 (`WindowsSdkDir`, `UniversalCRTSdkDir`, `UCRTVersion`/`WindowsSDKVersion`) as an upstream LLVM patch. Without it, Swift could read those variables itself in `CompilerInvocation.cpp` when the options are absent. Today a vcvars-like environment without registry keys fails module injection silently.
5. **Discovery default from the Swift SDK.** Add keys such as `WINDOWS_SYSROOT`, `WINDOWS_SDK_VERSION` and `VISUALC_TOOLS_VERSION` to `Windows.sdk/SDKSettings.plist` or the platform `Info.plist` (SwiftPM already parses both, `UserToolchain.swift` l.598-730). The driver would resolve a relative path against the toolchain, for example `<install>/Sysroot/` populated by an xwin-style downloader, so `swiftc hello.swift` works with no flags.
6. **Diagnose missing SDK/VC.** Add a warning in `GetWindowsFileMappings` when UCRT or VCTools can't be located, so users don't hit a bare "no such module 'ucrt'".
7. **swift-build:** `SWBWindowsPlatform/Plugin.swift` should not override a user-provided `VCToolsInstallDir`, and should pass explicit `-windows-*`/sysroot settings instead of relying only on vswhere.
8. **Runtime static link:** make the hard-coded `--dependent-lib=msvcrt` in `AddSwiftStdlib.cmake` follow `SWIFT_STDLIB_MSVC_RUNTIME_LIBRARY`, so static-SDK and `-libc MT` builds don't mix CRTs.
9. **Packaging and case:** xwin lowercases file names and adds symlinks. The VFS targets are computed from the discovered roots, so this is fine on NTFS. For cross-compiling from Linux, check that the modulemap header names and `link "Foo.Lib"` spellings resolve, or have xwin generate the case variants.

### (B) MinGW / `x86_64-w64-windows-gnu` target

1. **Driver:**
   - In swift-driver `toolchainType` (`Driver.swift` l.3790), return a new `MinGWToolchain` (GenericUnix-like: `clang -target x86_64-w64-mingw32 -fuse-ld=lld`, `.exe`/`.dll`/`lib*.a`, `swiftrt.obj` equivalent) for `.win32` + `.gnu`.
   - Change the `addRuntimeLibraryFlags` guard (`FrontendJobHelpers.swift` l.656) and the legacy `Driver.cpp` l.1485 from `isWindows` to `isWindowsMSVC`.
   - Enable `isAutolinkExtractJobNeeded` for CygMing (`AutolinkExtractJob.swift`) to match IRGen.
   - Route GNU to a MinGW toolchain in the legacy `Driver.cpp` l.442.
2. **ClangImporter:**
   - Add a MinGW branch in `getClangInvocationFileMapping` (`ClangIncludePaths.cpp` l.736+) that maps a new `mingw.modulemap` (exposing modules **`ucrt`** and an overlay **`CRT`**) and a flat-layout `WinSDK` modulemap over the mingw-w64 `include/` dir.
   - Relax `ClangImporter.cpp` l.835 (`-isystem <sdk>/usr/include`) to cover GNU too.
   - Pick libc++ (llvm-mingw) instead of forcing `Msvcprt` in `CompilerInvocation.cpp` l.412.
3. **IRGen ABI decision:** `useDllStorage()` (`Linking.cpp` l.79) currently disables dllimport/dllexport for MinGW. Swift metadata uses relative and indirect pointers that rely on `__imp_` symbols across DLLs, which the MSVC path gets via dllimport. MinGW auto-import and pseudo-relocations probably can't fix 32-bit relative references, so this most likely needs to be **true for MinGW too**, or the port is limited to static linking. This needs validation.
4. **stdlib build:**
   - Add a `MINGW` SDK (or Windows + GNU env) to `stdlib/cmake`. Build `swiftCRT` for it (`Platform/CMakeLists.txt` l.84-100) and set `SWIFT_MODULE_DEPENDS_MINGW CRT` in Concurrency and other libraries.
   - Drop the `--dependent-lib=msvcrt/oldnames` flags (`AddSwiftStdlib.cmake` l.1786-1789, l.3293-3295) for GNU.
   - Audit the 5 `#pragma comment(lib)` sites (clang/lld in MinGW mode generally honor `.drectve -defaultlib`, but needs verification), plus `SwiftRT-COFF.cpp` section registration, and SEH/`__try` and `_MSC_VER` uses.
5. **Core libraries:** keep the `#if os(Windows)` + `import WinSDK`/`CRT` code paths unchanged by providing same-named modules. Fix places that assume MSVC-only headers (`<crtdbg.h>`, `_set_invalid_parameter_handler`, etc.). libdispatch, Foundation, ICU, curl and libxml2 need MinGW builds; llvm-mingw is the natural host toolchain.
6. **build.ps1 / installer:** add a non-VS path that builds with llvm-mingw clang (no `Enter-VsDevShell`, vswhere or `VCRedistDir`) and drops the VCRuntime component for MinGW-target runtimes.
