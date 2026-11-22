# Swift on Windows without the VS installer: the landscape (as of 2026-11-21)

Scope: what exists today, how far along it is, and how other languages handle the same problem. Licensing (whether Microsoft files may be redistributed) and Swift compiler internals are covered in separate reports. Where a point touches licensing, it is only flagged here.

## TL;DR

- **The official story has not changed.** Swift 6.4.3 (2026-11-19) ships as a WiX Burn `.exe` (x64 and arm64). The user still has to install Visual Studio themselves, with the Windows SDK and the VC tools. The WinGet `Swift.Toolchain` manifest declares only one dependency, `Git.Git`, so VS is never pulled in automatically. Swiftly still does not support Windows; a pitch to add it was posted on 2026-10-26.
- **What Swift actually needs from Microsoft is small.** It needs the MSVC CRT headers and import libraries (`vcruntime`, `msvcrt`, `msvcprt`) and the Windows SDK (UCRT plus `um`/`shared` headers and libs). The compiler, `link.exe` and the IDE are not needed, because Swift ships clang and lld. Measured download sizes for x64:
  - minimal set: about 270 MB;
  - VS installer route: about 1.2 GB download and 2+ GB on disk.
- **Microsoft already ships the Windows SDK half officially on NuGet** (`Microsoft.Windows.SDK.CPP` plus `.x64`/`.arm64`). Only the MSVC CRT half lacks an official standalone channel. The community tools xwin, portable-msvc.py and msvcup fetch it straight from the VS CDN manifests.
- **MinGW is effectively dead for Swift.** MSYS2 closed its "Add mingw-w64-swift" request as *not planned* (2026-10-25). The maintainers (compnerd) have said repeatedly that the port targets the MSVC ABI and MSVC libraries.
- **The most promising model** is a Swift SDK plus a Microsoft sysroot fetched on demand, the way the Android Swift SDK relies on a separately downloaded NDK. The driver already has the flags to point at such a sysroot (`-windows-sdk-root`, `-windows-sdk-version`, `-visualc-tools-root`, `-visualc-tools-version`). The LDC approach (open-source import libs plus a tiny CRT stub) is not enough on its own, because Swift's ClangImporter needs the real headers, not only import libs.

---

## 1. The official install story today

**swift.org/install/windows** ([link](https://www.swift.org/install/windows/)) gives two commands:

```
winget install --id Microsoft.VisualStudio.2022.Community --exact --force --custom "--add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.Tools.ARM64" --source winget
winget install --id Swift.Toolchain -e --source winget
```

The page still points at VS **2022 Community**, even though VS 2026 (v18) and `Microsoft.VisualStudio.BuildTools` 18.x are in winget. The Community license is restricted for organizations; see the licensing report.

**WinGet manifest** ([winget-pkgs/manifests/s/Swift/Toolchain/6.4.3](https://github.com/microsoft/winget-pkgs/tree/master/manifests/s/Swift/Toolchain/6.4.3)):
- `InstallerType: burn`, `Scope: user`.
- `Dependencies: Git.Git` only.

**Installer layout**:
- The toolchain goes to `%LOCALAPPDATA%\Programs\Swift\{Toolchains,Platforms,Runtimes}`.
- `Windows.platform\Developer\SDKs\Windows.sdk` holds the Swift SDK.
- Since 5.9 the module maps (`ucrt.modulemap`, `winsdk.modulemap`/`um.modulemap`, `vcruntime.modulemap`) live in the Swift SDK's `usr/share` directory and are injected with `-vfsoverlay`. Before 5.9, users had to copy them into the VS and SDK directories as admin.

**Scoop**: `ScoopInstaller/Main/bucket/swift.json` (6.4.3) unpacks the Burn bundle with `wix burn extract` plus MSI extraction. That is effectively a portable, non-admin toolchain today. Its notes still say "you must have Visual Studio and Windows SDK installed". Chocolatey has no maintained Swift package.

**Swiftly**: 1.2.0 (2026-09-22) supports Linux and macOS only. Issue [#151 "Windows platform support"](https://github.com/swiftlang/swiftly/issues/151) is open. A [pitch to bring Swiftly to Windows](https://forums.swift.org/t/pitch-bringing-swiftly-to-windows/90287) (2026-10-26) proposes:
- OpenAPI over compnerd's WinHTTP transport;
- installing by driving Windows Installer on the bundled MSIs;
- enumerating installs by ProductCode.

It does not address VS acquisition.

**Governance**: a [Windows Workgroup](https://swift.org/blog/announcing-windows-workgroup/) was formed in January 2026 and meets biweekly ([notes](https://forums.swift.org/t/biweekly-windows-workgroup-agenda-notes/89334)). Its current topics are COM interop and SwiftPM platform gaps. I found no agenda item on VS-free installs.

**GitHub Actions**:

| Action | VS handling |
|---|---|
| [compnerd/gha-setup-swift](https://github.com/compnerd/gha-setup-swift) (pushed 2026-10) | Relies on the runner image's preinstalled VS. It calls `gha-setup-vsdevenv` only for Swift < 5.9 or with `update-sdk-modules: true`, which downloads newer modulemaps from the Swift repo. Open issues include a missing `D:\Include\ucrt\module.modulemap` on windows-2019 and the wrong `link.exe` first on `PATH` ([#45](https://github.com/compnerd/gha-setup-swift/issues/45), [#25](https://github.com/compnerd/gha-setup-swift/issues/25)). |
| [SwiftyLab/setup-swift](https://github.com/SwiftyLab/setup-swift) v1.14.2 (2026-10) | Uses vswhere to find VS and exports a `.vsconfig`. If any are missing, it runs the VS setup engine to **add** `VC.Tools.<arch>` and a `WindowsXXSDK.<ver>` matching the toolchain (`src/utils/visual_studio/setup.ts`). It notes that "Swift 5.10 and after does not support caching on Windows". |
| [swift-actions/setup-swift](https://github.com/swift-actions/setup-swift) | v3.0.0-beta.1 (2025-11). Also leans on the runner's VS. |

**Typical failure modes** (all of them come from VS or the SDK drifting under a fixed toolchain):
- **New Windows SDK breaks modulemaps.** SDK 10.0.26100 broke plugin and manifest builds (*"cyclic dependency in module 'ucrt'"*). compnerd's advice was to downgrade the SDK or select it with `-windows-sdk-version`, since "modulemap definitions cannot be updated retroactively" ([thread](https://forums.swift.org/t/swiftpm-plugin-doesnt-work-with-the-latest-visual-studio-version/78183)).
- **VS updates break arm64.** VS 17.14.3 broke Windows on ARM (`_ARM64_BARRIER_ISHST` ambiguous) and x64 (`ucrt -> _Builtin_intrinsics -> ucrt`) ([thread](https://forums.swift.org/t/error-on-windows-11-arm-with-latest-visual-studio-2022-community-components-17-14-3/80250)).
- **No VS at all.** The manifest fails to compile with `_Builtin_intrinsics` / `stdint.h not found`. compnerd replied that the headers are "not possible to redistribute… you are responsible for procuring a copy of Visual Studio" ([2026-10 thread](https://forums.swift.org/t/swift-setup-error-in-windows-11/90001)).
- **winget msstore certificate pinning** blocks the VS install inside VMs. The workaround is `winget settings --enable BypassCertificatePinningForMicrosoftStore` ([thread](https://forums.swift.org/t/windows-setup-failures/83660)).
- **Wrong `link.exe`** first on `PATH` (Git's `link`, or MSVC's when lld is expected), plus VS dev-prompt confusion.
- **Only one toolchain installed at a time** ([thread](https://forums.swift.org/t/is-there-a-reason-we-cant-install-multiple-toolchains-on-windows-simultaneously/76371)).

## 2. Fetching the MSVC CRT and Windows SDK without the VS installer

The x64 sizes below were measured against the VS 18.12.1 channel manifest (MSVC 14.53, SDK 10.0.26100/28000) and NuGet on 2026-11-21.

| Piece | Download |
|---|---|
| `microsoft.vc.14.53.crt.headers.base` | 2.0 MB |
| `microsoft.vc.14.53.crt.x64.desktop.base` (vcruntime/msvcrt/msvcprt `.lib`, release and debug) | 67 MB (arm64: 86 MB) |
| Windows SDK via NuGet `Microsoft.Windows.SDK.CPP` 10.0.28000.2957 (headers, UCRT, tools) | 153 MB |
| `Microsoft.Windows.SDK.CPP.x64` (x64 libs) | 51 MB (`.arm64` is 101 MB) |
| **Minimal x64 total** | **≈ 270 MB download** |
| VS installer: `VC.Tools.x86.x64` closure | ≈ 684 MB download, ≈ 1.9 GB installed |
| VS installer: `Windows11SDK.26100` | ≈ 511 MB download |
| VS installer: Build Tools + VC.Tools.x86.x64 + Win11SDK | **≈ 1.2 GB download, 2–3 GB+ on disk** (adding VC.Tools.ARM64 adds ≈ 0.9 GB) |

The unpacked footprint is reported by xwin as: CRT headers 18 MiB, CRT libs 81 MiB, SDK headers 305 MiB, SDK libs 170 MiB (≈ 575 MiB in total). xwin's `minimize` shows that a real build touches only 3–40% of that.

The tools:

- **[Jake-Shadle/xwin](https://github.com/Jake-Shadle/xwin)** v0.10.0 (2026-08-12) is a Rust CLI. It downloads, unpacks and "splats" the CRT and SDK, supports `--use-winsysroot-style` for clang's `/winsysroot`, and can pin `--sdk-version`/`--crt-version`. It handles VS 18 manifests (since 0.9.0). Prebuilt binaries exist only for Linux and macOS, but `cargo install` works anywhere. Its main purpose is producing a case-insensitive-safe tree for Linux. Caveat: the isomer project (below) reports that xwin's UCRT lacked headers Swift's modulemaps need (e.g. `corecrt_math.h`). This needs verifying; it may be pruning.
- **[mmozeiko portable-msvc.py](https://gist.github.com/mmozeiko/7f3162ec2988e81e56d5c4e22cde9977)** (updated 2026-11-15) is a Python script that understands the VS 2019, 2022 and 2026 channels. It pulls the MSVC tools, CRT and SDK MSIs and unpacks them with `msiexec /a` (or `msiextract` on Linux). It writes `setup_x64.bat`. This is the reference implementation everyone copies.
- **[marler8997/msvcup](https://github.com/marler8997/msvcup)** (370★, active 2026-11) is a Zig tool. It does a hermetic extract with **lock file** pinning (URL plus SHA-256 per payload), a global cache, `vcvars-*.bat`, and an "autoenv" wrapper. It is the closest existing design to "swiftly for the Microsoft half". There is a Rust port at wolfv/msvcup.
- **[loonghao/msvc-kit](https://github.com/loonghao/msvc-kit)** is in winget as `loonghao.msvc-kit`. [PortableBuildTools](https://github.com/Data-Oriented-House/PortableBuildTools) is now archived (2025-02).
- **[mstorsjo/msvc-wine](https://github.com/mstorsjo/msvc-wine)** (active) is a Python downloader plus Wine wrappers for Linux. Its `vsdownload.py` is another manifest parser. Only the downloader is relevant on native Windows.
- **Official Microsoft channels**:
  - The Windows SDK is on NuGet ([Microsoft.Windows.SDK.CPP](https://www.nuget.org/packages/Microsoft.Windows.SDK.CPP)), with millions of downloads and explicitly intended "for CI/CD integration".
  - The MSVC toolset has **no** official NuGet or standalone zip. VS 2026 decoupled MSVC versioning (14.50+) and the Build Tools are in winget (`Microsoft.VisualStudio.BuildTools` 18.x), but that is still the VS installer.
  - Unattended minimal install: `vs_buildtools.exe --quiet --wait --norestart --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.26100` (append `VC.Tools.ARM64` for arm64). This needs admin and about 1.2 GB.

## 3. Swift without MSVC (MinGW / windows-gnu)

- **MSYS2**: there is no Swift compiler package. Only `mingw-w64-{clang-x86_64,clang-aarch64,ucrt-x86_64}-libblocksruntime-swift` 6.1.1 (BlocksRuntime) and `libdispatch` exist. The request to [add mingw-w64-swift](https://github.com/msys2/MINGW-packages/issues/20488) was closed **NOT_PLANNED** on 2026-10-25. MSYS2 is also dropping MINGW64 (msvcrt) builds in favor of UCRT64/CLANG64.
- **Historical ports**: [tinysun212/swift-windows](https://github.com/tinysun212/swift-windows) (Swift 4.1, MinGW/Cygwin) and GunGraveKoga/mingw-w64-swift-pkg are dead. Cygwin/MinGW autolink and stdlib PRs date from 2016–2018.
- **Upstream stance**: in [Swift on Windows without Visual Studio?](https://forums.swift.org/t/swift-on-windows-without-visual-studio/63521?page=3), compnerd said:
  - MinGW headers are re-creations that may not match the SDK;
  - the port will always depend on the MSVC runtime;
  - separating the MSVC runtime headers and libs from Build Tools would allow building without VS.

  On [cross-compiling](https://forums.swift.org/t/how-do-you-compile-to-windows-from-ubuntu-linux-22-04/80348) he said Wine and MinGW lag Microsoft's APIs, and that Swift deliberately imports the real SDK.
- **Open PR**: [#87089](https://github.com/swiftlang/swift/pull/87089) "Various fixes to build with clang gnu driver on Windows" (2026-02, open) concerns the host build driver, not a gnu target.
- **What would break on x86_64-w64-windows-gnu**:
  - C++ interop (libc++ vs MSVC STL, and the Itanium vs MSVC C++ ABI on Windows);
  - SEH and unwinding differences;
  - `long double` is 80-bit;
  - binary incompatibility with every official Swift DLL and with Windows App SDK / COM interop work;
  - Foundation and ICU, dispatch and swift-testing have only been built and tested on msvc;
  - SwiftPM assumes `windows-msvc` triples and `.lib` conventions.

  In short, it would be a second port, and the maintainers don't want it.
- **[llvm-mingw](https://github.com/mstorsjo/llvm-mingw)** (3k★, active) is the obvious sysroot if someone tried anyway. It is UCRT-based, uses clang and lld, and supports arm64.

## 4. How other languages solve this

| Language | Default Windows ABI | Needs VS? | Mechanism | Lesson for Swift |
|---|---|---|---|---|
| **Zig** | `x86_64-windows-gnu` | No (gnu); yes for `-msvc` | Ships mingw-w64 **headers and .def files**, builds the mingw CRT from source on demand, generates import libs from `.def`, and links with lld against UCRT. | Fully self-contained, but only because it adopts the MinGW ABI and headers. |
| **Rust** | `*-pc-windows-msvc` | Yes for msvc | `rustup-init` detects missing VS and **offers to install the VS Build Tools/Community automatically** ([docs](https://rust-lang.github.io/rustup/installation/windows-msvc.html)). `*-windows-gnu` ships self-contained MinGW CRT objects and import libs. `*-windows-gnullvm` uses the llvm-mingw ABI. [cargo-xwin](https://github.com/rust-cross/cargo-xwin) wraps xwin for cross builds. | (a) Automate VS acquisition in the installer, or (b) wrap xwin/msvcup. Pure-Rust crates link only against system DLLs through import libs, so their header needs are near zero. |
| **Go** | Native PE | No | The runtime calls Win32 through `LoadLibrary`/`syscall`, with its own linker and no libc. cgo needs mingw gcc. | Not applicable: Swift's value is direct C/SDK import. |
| **D / LDC** | MSVC ABI | **No** | [ldc-developers/mingw-w64-libs](https://github.com/ldc-developers/mingw-w64-libs): MinGW `.def` files are patched to undo MinGW overrides, aliases are verified against `dumpbin` of the real MS libs, and **MSVC-compatible `.lib` import libs** are generated for the WinSDK DLLs and `vcruntime140`/UCRT. A tiny open-source `msvcrt_*.c` stub provides `mainCRTStartup`, `_DllMainCRTStartup`, ctors and atexit, merged into `vcruntime140.lib`. `driver/linker-msvc.cpp` falls back automatically ("no Visual C++ installation found… falling back to MinGW-based libraries"), adds `/LIBPATH:<lib>/mingw` and links with the built-in lld-link. LDC 1.43.0 (2026-08) still does this. | This is the strongest precedent for "MSVC ABI without Microsoft files". It works for D because D needs **no C headers**. Swift needs headers for `import ucrt`/`WinSDK`/Foundation's C shims, so this covers only the linking half. The header half would need mingw-w64 headers in MSVC mode, which is fragile and exactly what compnerd objects to. |
| **Odin** | MSVC | Yes | Uses `link.exe` and the Windows SDK, and documents installing Build Tools. | Same pain as Swift. |
| **Nim** | MinGW gcc | No | The installer and `finish.exe` download a MinGW distribution. | Downloads a GNU toolchain. |
| **Julia** | MinGW-built binaries | No | Ships the mingw runtime DLLs it was built with. Users don't compile C. | Not comparable. |

## 5. Swift SDK bundles as a distribution model

- SE-0387 artifact bundles (`swift sdk install <url> --checksum`) are mature. swift.org's `releases.json` for 6.4.3 lists the **Static Linux SDK, Wasm SDK and Android SDK, but no Windows SDK bundle**.
- The **Android SDK is the closest analogue**. The bundle contains the Swift parts only. The user downloads NDK r30 and sets `ANDROID_NDK_HOME` ([guide](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)), so the vendor sysroot is never redistributed. A Windows equivalent would contain the Swift `Windows.platform` (stdlib, Foundation, XCTest/Testing, modulemaps, runtime DLLs) plus a fetch step for the Microsoft half (NuGet SDK plus the VS-CDN CRT packages, as with msvcup or xwin).
- **Upstream momentum toward this**:
  - compnerd's [Upcoming changes to Windows Swift SDKs](https://forums.swift.org/t/upcoming-changes-to-windows-swift-sdks/81313) (2025-07) introduced `WindowsExperimental.sdk`, a **static Swift runtime** built with the new build system. It initially had no Foundation (ICU symbol collisions).
  - He stated work "to make the SDK a bit more portable… simply grab the SDK from the Windows builds".
  - PR [#88262 "Add document Swift SDK Build"](https://github.com/swiftlang/swift/pull/88262) is open.
  - [swift-sdk-generator](https://github.com/swiftlang/swift-sdk-generator) does not target Windows.
  - compnerd declined a generator-produced Windows bundle pending legal review.
- **Existing proof that it works**: [AttilaTheFun/isomer `tools/windows`](https://github.com/AttilaTheFun/isomer/tree/main/tools/windows) (very experimental, active 2026-11):
  - extracts swift.org's Windows installer on Linux with 7-Zip and msitools into a Swift SDK tarball;
  - pairs it with a `/winsysroot`-layout tarball of MSVC and the SDK made once on a Windows machine, kept private and never published;
  - adds case-fixing symlinks;
  - builds with host `swiftc -target aarch64-unknown-windows-msvc -sdk … -visualc-tools-root … -windows-sdk-root … -windows-sdk-version …` plus `clang-cl`/`lld-link`.

  The driver flags exist in swift-driver `Options.swift`. The older [WindowsCrossCompile.md](https://github.com/swiftlang/swift/blob/main/docs/WindowsCrossCompile.md) covers clang-based runtime cross builds.

## 6. Other notable pieces

- **[thebrowsercompany/swift-build](https://github.com/thebrowsercompany/swift-build)** publishes daily `installer-{amd64,arm64}.exe` (e.g. 20261118.2). These are often fresher than swift.org and are what compnerd points people to for fixes. They are not portable zips. compnerd/swift-build is the older home.
- There is **no official portable zip.** The de-facto portable routes are Scoop's extraction, or `wix burn extract` plus `msiexec /a` by hand. Runtime redistribution is via the MSM/MSI in the toolchain ([thread](https://forums.swift.org/t/improving-the-distribution-of-swift-on-windows/65358)).
- [tcrun](https://forums.swift.org/t/tcrun-managing-swift-toolchains-on-windows/77580) is a community Windows toolchain selector.

---

## Options matrix

| # | Option | Removes VS installer? | Removes MSVC files entirely? | Maturity | Effort | Main risks |
|---|---|---|---|---|---|---|
| A | Status quo plus a scripted `vs_buildtools --quiet --add VC.Tools.<arch> --add Win11SDK.<pinned>` (the rustup or SwiftyLab approach) | No (automates it) | No | High: works today | Low | Admin rights, ≈1.2 GB, slow on CI. SDK/VS drift breaks modulemaps. VS license terms. |
| B | Portable Swift (Scoop-style extraction) plus **on-demand Microsoft sysroot**: SDK from the official NuGet, CRT from the VS CDN via an msvcup/xwin/portable-msvc-style fetcher with a lock file; point Swift at it with `-windows-sdk-root`/`-visualc-tools-root` or `/winsysroot` | **Yes** | No (downloaded from Microsoft per user) | Medium: every component exists, nobody has packaged it for Swift | Medium | The VS CDN manifest format changes (xwin needed fixes for v18). Need to verify header completeness (isomer's `corecrt_math.h` report). Licensing of automated download; see that report. |
| C | Same as B, packaged as a **Windows Swift SDK artifact bundle** (`swift sdk install`) with a post-install fetch step, the Android/NDK model | **Yes** | No | Low/medium: upstream is moving toward a portable `Windows.sdk`, but no bundle exists | Medium–high | SwiftPM's Windows host still expects VS discovery. Swift SDK bundles and Windows hosts are untested together. Upstream buy-in. |
| D | LDC-style: open-source import libs (from mingw-w64 `.def`) plus a CRT stub, **keeping the Microsoft headers** fetched as in B | Yes | Removes the MS *libs* only | Proven for D only | Medium | Little gain over B, since headers are still needed. Alias and ABI mismatches in generated `.lib`s. |
| E | LDC-style libs **plus mingw-w64 headers** in MSVC mode (`-fms-compatibility`), with custom modulemaps | Yes | **Yes** | Experimental, nobody has done it for Swift | High | Header divergence from the real SDK, and missing APIs (WinRT, newer Win32). Breaks C++ interop and the official Foundation/dispatch builds. Upstream opposed. |
| F | Full MinGW/`windows-gnu` port (llvm-mingw sysroot, MSYS2 packaging) | Yes | Yes | Dead: MSYS2 request closed not-planned | Very high (a new platform port) | ABI-incompatible with all official binaries. No C++ interop parity. Foundation, ICU, dispatch and SwiftPM all untested. No maintainers. |
| G | Cross-compile from Linux/macOS with an xwin-produced sysroot (isomer approach) | N/A on dev machine | No | Experimental (1 project) | Medium | Doesn't meet the "native Windows" requirement for development. Testing still needs Windows. |

**Recommendation from the landscape**:
- **B** is the shortest path to "trivially installable, no VS installer", and it can grow into **C**.
- Pin the SDK and CRT versions with a lock file. This also fixes the most common real-world breakage: VS/SDK updates invalidating Swift's modulemaps.
- Treat **D** as an optional later step to cut the CRT download. **E** and **F** are not worth pursuing given the upstream stance.
