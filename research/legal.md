# Legal research: a portable Swift toolchain on Windows (MSVC, Windows SDK, alternatives)

*Researched 2026-11-21. **This is not legal advice.** Each claim is tagged **[F]** for a fact quoted from a primary source or **[I]** for my interpretation, with a confidence level of H, M or L. Get Microsoft or counsel sign-off before shipping anything that rests on an [I].*

## 1. Visual Studio Build Tools (VSBT) license

The VS 2026 Build Tools license is "Last Updated: October 1, 2025". The installer manifest's license link (`aka.ms/vs/18/stable/channel`, then `go.microsoft.com/fwlink/?LinkId=2327714`) resolves to https://visualstudio.microsoft.com/license-terms/vs2026-ga-diagnostic-buildtools/. The page text lives in the [docx](https://visualstudio.microsoft.com/wp-content/uploads/2025/10/Visual_Studio_2026-License-Diagnostic_and_Build_Tools_ENU.docx). The VS 2022 terms are at the `vs2022-ga-diagnosticbuildtools` URL (LinkId=2179911) and were updated in March 2024.

- **[F, H] A VS license is the baseline.** "The software is licensed as a supplement to Visual Studio Community, Visual Studio Professional, and Visual Studio Enterprise… Use of the software requires a valid license to one of the Visual Studio Products."
- **[F, H] The open-source exception.** "if you don't have a valid license to any of the Visual Studio Products you may still install and use copies of the software to compile and build C++ components that (i) have been released by a third party under an open-source software license approved by the Open Source Initiative; and (ii) are also reasonably required to build your applications ('Open Source Dependencies')." The terms forbid using this right "to develop and test Open Source Dependencies", except for "minor modifications".
  - It was announced on 2022-08-18 in Microsoft's [C++ blog post](https://devblogs.microsoft.com/cppblog/updates-to-visual-studio-build-tools-license-for-c-and-cpp-open-source-projects/): VSBT "can now be used for compiling open-source C++ dependencies from source without requiring a Visual Studio license", including for enterprises with closed-source products. Proprietary C++ work still needs a VS license.
  - The license was reworded again after [vscode-cpptools#11646](https://github.com/microsoft/vscode-cpptools/issues/11646) (closed 2024-07-15).
- **[I, H] The exception does not cover Swift code.** It covers only *C++ components* under OSI licenses. It does not let an enterprise without a VS license compile its own Swift app against MSVC headers and libs. Individuals, OSI-licensed projects and small organizations do qualify for a [Community license](https://visualstudio.microsoft.com/wp-content/uploads/2025/10/Visual_Studio_2026-License-Community_ENU.docx), which in turn makes Build Tools use legitimate for them. Community's "enterprise" threshold is more than 250 PCs or users, or more than $1M revenue.
- **[F, H] Redistributing the tools is prohibited.** The Build Tools scope clause says you may not "share, publish, rent, lease, or otherwise distribute the software or any of its code", nor "provide the software as a stand-alone offering or combined with any of your applications for others to use". The Build Tools license has no Distributable Code section of its own. Copying is allowed only onto your own "Build Devices" (devices you own, Azure, or an Authorized Outsourcer).
- **[F, H] What may be redistributed.** The Distributable List is at [learn.microsoft.com/visualstudio/releases/vs18/redistribution](https://learn.microsoft.com/visualstudio/releases/vs18/redistribution). That page says it applies to Enterprise, Professional, Community "and Visual Studio Build Tools".
  - Allowed: "any of the files within the following folder and its subfolders… `[VisualStudioFolder]\VC\redist`" (vcruntime140*.dll, msvcp140*.dll, concrt, vcomp and so on), the merge modules `Microsoft_VC145_CRT_[arch].msm`, msdia140.dll, and mfcmifc80.dll.
  - Excluded: `debug_nonredist` (debug CRTs).
  - "Distribution of the Visual C++ Runtime Redistributable package… is limited to licensed Visual Studio users."
  - Conditions (Community §DISTRIBUTABLE CODE): object code only, unmodified, "add significant primary functionality", pass on protective terms, and indemnify Microsoft.
- **[I, H] cl.exe, link.exe, vcruntime.lib, msvcrt.lib, libcmt.lib, libvcruntime.lib and the CRT/STL headers from the VS install are not on that list, so they may not be redistributed.**

## 2. Windows SDK license

The license is at [aka.ms/WinSDKLicenseURL, which resolves to sdk_license.rtf](https://download.microsoft.com/download/0/F/F/0FF2B061-47DD-4F55-89B6-FD1D8C44F14D/sdk_license.rtf). The redist list is at [learn.microsoft.com/legal/windows-sdk/redist](https://learn.microsoft.com/en-us/legal/windows-sdk/redist) (updated 2024-10-21).

- **[F, H] Use needs no VS license.** "You may install and use any number of copies of the software on your devices to design, develop and test your programs that run on a Microsoft operating system." Build machines are also allowed (§1c). One copy-related condition: "You must require end users to agree to terms that protect the software as much as these license terms."
- **[F, H] Rehosting is prohibited.** The scope clause says you may not "publish the software for others to copy" or "transfer the software… to any third party".
- **[F, H] The redist list (REDIST.TXT) covers:**
  - Libraries: the .lib files under `Lib\<ver>\um\<arch>` and `Lib\<ver>\ucrt\<arch>` (kernel32.lib, ucrt.lib, libucrt.lib and so on). These come with a hard condition: "For any Distributable Code having a filename extension of .lib, distribute only the results of running such Distributable Code through a linker with your program."
  - DLLs and installers: the UCRT DLLs (`Redist\ucrt\DLLs\<arch>\ucrtbase.dll` and `api-ms-win-*.dll`), the UCRT MSUs, d3dcompiler/dxcompiler, the Debugging Tools DLLs, and SignTool/MakeAppx.
  - **No headers (um/, shared/, ucrt/) are listed.**
- **[I, H] We may not ship SDK headers or import libs inside our toolchain.** Shipping the UCRT DLLs app-locally, and statically linked output, is fine.
- **[F, H] App-local UCRT deployment is "supported, but not recommended".** On Windows 10 and 11 the system copy is always used ([UCRT deployment](https://learn.microsoft.com/en-us/cpp/windows/universal-crt-deployment)).

## 3. Downloader tools (xwin, portable-msvc.py, msvc-wine)

- **[F, H] They all fetch from Microsoft's own channel manifests and show Microsoft's license URL.**
  - The mmozeiko gist reads `aka.ms/vs/{17,18}/…/channel` and prompts "Do you accept Visual Studio license at {license} [Y/N]?", where the URL comes from the manifest. It also has an `--accept-license` flag.
  - [xwin](https://github.com/Jake-Shadle/xwin) has `--accept-license` / `XWIN_ACCEPT_LICENSE=1` to skip its prompt.
  - [msvc-wine](https://github.com/mstorsjo/msvc-wine) says: "As Visual Studio isn't redistributable, the installed toolchain isn't either."
- **[F, M] I found no public record of Microsoft objecting to, or issuing a takedown against, any of these tools.** That is an absence of evidence, not permission.
- **[I, M] What this means for us.**
  - A downloader that runs on the user's machine, pulls straight from Microsoft's CDN and shows the license is the most defensible MSVC route: the user becomes the licensee and nothing passes through us.
  - It does not create a right the user lacks. The user still needs a VS license (Community counts if they qualify), or must limit use to building OSS C++ dependencies.
  - A silent `--accept-license` default is risky. Show the URL and require an explicit opt-in.
  - The "work around any technical limitations" clause is an untested argument against bypassing the installer. I rate that risk low but not zero.
  - We must never cache or mirror the downloaded payloads (for example in a shared CI cache across organizations).

## 4. NuGet-distributed pieces

- **[F, H] The Windows SDK packages are a sanctioned route.** `Microsoft.Windows.SDK.CPP` plus `.x64` / `.arm64` (current 10.0.28000.2957) say: "The Windows SDK available as a NuGet package for more seamless acquisition and CI/CD integration." Their nuspec sets `requireLicenseAcceptance=true` and points at the SDK license above.
  - I checked the package contents directly. The packages contain `Include/<ver>/{um,shared,ucrt,winrt,cppwinrt}`, `ucrt/<arch>/{ucrt,libucrt}.lib`, `um/<arch>/*.lib` and `Redist`. They contain **no** `vcruntime.h` or VC libs.
  - **[I, H]** This is a clean, scriptable way for a user's machine or CI to fetch SDK and UCRT headers and libs without the VS installer. They may not be re-published.
- **[F, M] There is no current official MSVC/VCTools NuGet package.** The only one was Microsoft's 2016 "VC++ toolset as NuGet" experiment, issued under pre-release license terms, and it was discontinued. Packages like `MSVCToolchain` on nuget.org are third-party repackagings. **[I, H]** Treat those as license violations; do not use them.

## 5. Open alternatives

- **[F, H] mingw-w64** is "provided under the Zope Public License (ZPL) Version 2.1", "with exception of certain parts… Public Domain, BSD, or LGPL" ([repo](https://github.com/mingw-w64/mingw-w64)). It provides the headers, CRT startup code and import libraries for both UCRT and msvcrt. Zig ships these as `lib/libc/mingw` (ZPL-2.1).
- **[F/I, H] llvm-mingw, LLVM, libc++, libunwind and compiler-rt** are Apache-2.0 WITH LLVM-exception, so a complete redistributable *-windows-gnu* toolchain is possible.
- **[F, H] Microsoft STL** ([github.com/microsoft/STL](https://github.com/microsoft/STL)) is "Apache-2.0 WITH LLVM-exception", but it "is built atop other compiler support libraries that ship with Windows and Visual Studio" (UCRT, VCRuntime, VCStartup).
- **[I, H] Bundling the GitHub STL headers is OK but not enough.** They `#include` vcruntime.h, which is VS-only, along with the UCRT headers, which come under the SDK license. vcruntime and vcstartup sources are not open source.
  - compnerd: "The problem is that the Windows SDK and ucrt have a dependency on VCRUNTIME… The headers and import libraries are part of Visual Studio" ([forums](https://forums.swift.org/t/swift-on-windows-without-visual-studio/63521)).
  - A fully redistributable *-msvc target would therefore need an open replacement for vcruntime's headers and libs (for example mingw-w64's ucrt-mode CRT pieces). That is engineering work, not a licensing problem.

## 6. Precedents

| Project | What it does | Bundles MSVC bits? |
|---|---|---|
| Rust / rustup | rustup-init "will offer to automatically install the prerequisites… it installs Visual Studio Community edition" through Microsoft's installer, and warns it is "not for… proprietary enterprise software" ([docs](https://rust-lang.github.io/rustup/installation/windows-msvc.html)) [F, H]. The `*-windows-gnu` targets ship self-contained mingw-w64 CRT objects [F, M]. | No |
| Zig | Ships mingw-w64 (ZPL) and targets `-gnu` when no MSVC is found [F, H] | No |
| Go | The compiler needs no C toolchain; cgo uses a user-installed mingw gcc [F, M] | No |
| Chromium | Googlers get an internal packaged VS toolchain. Everyone else must set `DEPOT_TOOLS_WIN_TOOLCHAIN=0` and install VS 2026, and "Community Edition should work if its license is appropriate for you" ([docs](https://chromium.googlesource.com/chromium/src/+/main/docs/windows_build_instructions.md)). `package_from_installed.py` zips *your own* installed VS, for internal use [F, H]. | Internal only |
| LLVM | clang-cl / lld-link use an existing MSVC and SDK; `/winsysroot` accepts xwin- or Chromium-style layouts [F/I, M] | No |
| Python / cibuildwheel | Relies on the VS preinstalled on CI images [I, M] | No |
| conda-forge | `vs2019_win-64` / `vs2022_win-64` are "Activation and version verification" scripts (BSD-3) that require an installed VS. `vc14_runtime` (LicenseRef-MicrosoftVisualCpp2015-2022Runtime) and `ucrt` ship **only redistributable DLLs** [F, H; API metadata] | Redist DLLs only |
| Julia | Builds on mingw-w64/GCC [I, M] | No |

No mainstream open-source project redistributes cl.exe, VC libs/headers or SDK headers. The redistributable runtime DLLs are the only Microsoft binaries that get shipped [I, H].

## 7. Swift project statements

- **[F, H] The official install** is `winget install Microsoft.VisualStudio.2022.Community … --add …Windows11SDK.22621 --add …VC.Tools.x86.x64 --add …VC.Tools.ARM64`, then `Swift.Toolchain` ([swift.org/install/windows](https://www.swift.org/install/windows/)).
- **[F, H] compnerd (2023-03-04)** said the installer cannot bundle VS parts "because the licensing terms do not permit the redistribution of the components", and that "the build tools are sufficient" ([thread](https://forums.swift.org/t/swift-on-windows-without-visual-studio/63521)).
- **[F, H] compnerd (2023-12-01)**: "for the pieces of Visual Studio (VCRuntime) you are bound by Microsoft's licensing terms." Max Desiatov said a MinGW-based SDK is possible but nobody has built it ([thread](https://forums.swift.org/t/swift-licensing-questions-windows-platform/68758)).
- **[F, H] compnerd (2025-07-29)**: the SDK is needed for Windows APIs, and the Build Tools supply the C runtime headers that the Swift runtime needs ([thread](https://forums.swift.org/t/compile-without-msvc/81366)).

## What we can and cannot do

| Action | Verdict | Conf. |
|---|---|---|
| Bundle cl.exe, link.exe, VC headers, vcruntime.lib, msvcrt.lib or libcmt.lib in our download | **Cannot** | H |
| Bundle Windows SDK headers or um/ucrt import libs in our download | **Cannot** (headers aren't redistributable; .lib only as linked output) | H |
| Ship vcruntime140.dll / msvcp140.dll (from `VC\redist`) or UCRT DLLs alongside Swift runtime DLLs or apps | **Can**, under the redist conditions; the shipper must be a licensed VS user | H |
| Have the installer fetch `Microsoft.Windows.SDK.CPP[.arch]` from nuget.org on the user's machine after showing the SDK license | **Can** (sanctioned channel; no VS license needed) | H |
| Have the installer fetch MSVC (VC.Tools / CRT) from Microsoft's channel manifest on the user's machine, xwin-style, after explicit license acceptance | **Probably can.** The user must still hold a VS license (Community if eligible) or stay within the OSS-C++-dependency right. | M |
| Accept the MS license silently or by default on the user's behalf | **Should not** | M |
| Mirror or cache MSVC or SDK payloads on our servers or a shared CI cache | **Cannot** | H |
| Tell enterprises without a VS license that they can build proprietary Swift apps with the downloaded Build Tools | **Cannot**; the OSS exception covers only C++ OSS dependencies | H |
| Ship a fully self-contained `*-windows-gnu` Swift toolchain (llvm-mingw, mingw-w64 CRT/headers, libc++) | **Can** legally; this is the engineering-heavy path | H |
| Ship Microsoft STL headers from GitHub (Apache-2.0) | **Can**, but they still need vcruntime and UCRT headers | H |
| Write and ship our own open replacements for the vcruntime/vcstartup headers and libs (clean-room or mingw-derived) | **Can** legally; this is engineering, plus ABI risk | M |
