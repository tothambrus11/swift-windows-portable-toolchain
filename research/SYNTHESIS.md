# Portable Swift on Windows: findings and recommendation

*2026-11-22. Combines five research/prototype tracks. Not legal advice.*

## Bottom line

**The official Swift 6.4.3 toolchain already works without Visual Studio.** The Microsoft parts it needs (the MSVC C runtime, about 77 MB, and the Windows SDK, about 200 MB) can be downloaded straight from Microsoft onto the user's machine. A PowerShell script then sets everything up in about 2–3 minutes, with no admin rights, no registry writes and no VS installer.

The CI test matrix is green on **x64 and arm64**, on runners where VS, the Windows Kits and LLVM were removed and PATH was cut down to System32. It covers:

- Foundation, via `swiftc` (debug, `-O`, `-Osize`) and SwiftPM
- `import WinSDK`
- SwiftPM build, run, test and release, on both build systems
- C targets and C++ interop
- a fresh `cmd` shell

Final run: https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44971517530 (branch `exp/xwin-sysroot`, `xwin/setup-portable-swift.ps1`).

**Recommended path:**
1. Keep the official swift.org binaries; don't build from source.
2. Repackage each release once in CI into a deduplicated archive and publish it on GitHub Releases.
3. Fetch the MSVC CRT and Windows SDK from Microsoft on the user's machine, after the user explicitly accepts the license.
4. Push the remaining rough edges upstream.

MSVC-free (mingw-w64) is a viable *fallback* for Foundation-level work. It is not the primary path.

## What the user needs from Microsoft, and how we get it

| Piece | Source | Size (x64) | Legal basis |
|---|---|---|---|
| MSVC CRT headers + `vcruntime`/`msvcrt`/`libcmt` libs | VS channel manifest, 3 packages, sha256-checked. A ~200-line PowerShell parser does this, so no xwin or Rust binary is needed. | ~77 MB (30 MB with `-NoStaticCrt`) | User-side download under the VS license. Covered by the free Community license for individuals, OSS and small organizations; enterprises need a paid VS license. **We may not redistribute it.** |
| Windows SDK (UCRT, um, shared) | NuGet `Microsoft.Windows.SDK.CPP` + `.CPP.<arch>`. xwin's copy lacks `corecrt_math.h`. | ~204 MB | Sanctioned channel for CI; SDK license; no VS license needed. **We may not re-host it.** |
| VC++ runtime DLLs (`vcruntime140`, `msvcp140`, …) | Already inside the Swift runtime MSI | small | Redistributable under VS redist terms |

The license gate: `-AcceptLicense` prints the Swift, MSVC and SDK license URLs, and the script refuses to run without it. Never accept on the user's behalf; never mirror or share-cache Microsoft payloads.

## How the Swift toolchain itself is obtained

| Option | Verdict |
|---|---|
| Build from source (`build.ps1`) | **No.** About 916 job-minutes per release on 64-core runners; doesn't fit free 4-vCPU runners (6 h limit); high upkeep. Its benefits are all available more cheaply. |
| Extract the official bundle at install time | **Works now.** Range-fetch only the NoAsserts and Shared containers (1.2 GB of 2.0 GB on x64, 0.85 of 1.55 GB on arm64), then `msiexec /a` 4 MSIs. No admin needed. |
| **Repackaged archive on GitHub Releases** (CI, once per release) | **Recommended default.** Minimal NoAsserts layout, about 2.0 GB unique on disk (x64) after hardlinking the duplicated swift-frontend/clang/lld copies (−612 MB). Download sizes measured: **7z -mx9 324 MB**, tar.xz 464 MB, tar.zst 674 MB, zip 946 MB. arm64: 275 / 387 / 595 / 827 MB. Legal: Swift is Apache-2.0 and the VC++ DLLs are redistributable; no MSVC/SDK files go in. |
| The Browser Company nightlies | Optional snapshot source only (not release builds; no stability promise). |
| Upstream: swift.org publishes a zip / loose MSIs + Windows Swift SDK bundle | The real long-term fix; it also unblocks the swiftly-on-Windows pitch. |

## What makes it work (technical core)

1. **`clang.cfg` next to the toolchain's clang:** `-fuse-ld=lld` and `-Xmicrosoft-windows-sys-root "<root>"`, with escaped backslashes because forward slashes trigger a VFS assertion. Swift's ClangImporter reads this file too, so the setting reaches swiftc, SwiftPM, the test runner and C targets. Driver flags (`-windows-sdk-root` …) don't reach the link job or the `swift test` runner.
2. **Swift's modulemaps:** copied next to the SDK headers, or mapped in with `-ModulemapMode overlay` through `clang.cfg`. Registry-only discovery is not enough.
3. **`activate.ps1` / `activate.bat`:** set PATH, SDKROOT and the vcvars-style variables.
4. **Installer packaging bug:** `swift build`/`swift test` need FoundationXML and swiftRegexBuilder runtime pieces that only ship in the sourcekit-lsp MSI, so the script copies them.

## Bugs found (draft issues in `xwin/REPORT.md`, not filed)

- **`-O` Foundation "link bug" was not the optimizer.** An executable named `foundation.exe` gets an import library `foundation.lib` written into the working directory. Later links autolink `Foundation.lib`, and the case-insensitive search finds the local stub first. It reproduces with VS installed. Suggested swift-driver fix: pass `/noimplib` for executables.
- **VFS assertion** ("Paths should not contain traversal components"): triggered by forward-slash paths in `clang.cfg` when a Swift overlay is active.
- **Empty `VCToolsInstallDir=""`** crashes the Asserts frontend ("virtual path not absolute").
- **swiftc defaults to MSVC `link.exe`** even when it is absent; it should fall back to lld.
- **LLVM `MSVCPaths.cpp` ignores `WindowsSdkDir`/`UniversalCRTSdkDir`/`UCRTVersion`** (existing FIXMEs). SDK discovery is flags-or-HKLM only.
- **xwin's SDK pruning** drops `corecrt_math.h`.

## MSVC-free route (mingw-w64 hybrid), branch `exp/mingw`

- **What works:** the official compiler plus llvm-mingw headers and import libs, a ~150-line open-source CRT startup shim (LDC-style) and a generated CRT modulemap. hello world, CRT, WinSDK, **Foundation** and concurrency build and run with zero Microsoft headers or libs (run 44961657611).
- **What fails:** SwiftPM (manifest compile ignores flags) and C++ interop (no MSVC-ABI C++ standard library). It also needs about a dozen header patches, 11 WinSDK headers are unavailable, and runtime still uses `vcruntime140.dll`.
- **Value:** small (~15–25 MB compressed est.) and license-clean for the build-time part. Worth packaging later as a Swift SDK bundle, especially for license-constrained enterprises. A full `windows-gnu` target would be 1–3 engineer-months and ABI-incompatible with official Swift; not recommended now.
- MSYS2 has no Swift package (request closed NOT_PLANNED, 2026-10-25). Upstream maintainers favor the MSVC ABI.

## Next steps

1. **Merge `exp/xwin-sysroot` into `main`** and switch the setup script to range-fetch + NoAsserts + hardlink dedup (`build-eval/minimal-zip.ps1`). About a day.
2. **Release workflow, 2–3 days.**
   - On each swift.org release: build a minimal 7z/tar.xz per arch.
   - Run the no-VS test matrix against the unpacked archive.
   - Publish with SHA256 sums, the LICENSE/NOTICE files and the VC++ redist terms.
   - The setup script prefers the archive and falls back to extraction.
3. **CI action:** a `setup-swift-portable` GitHub Action wrapping the script, with Microsoft payloads cached per job only, inside the user's own repo.
4. **Upstream:**
   - file the issues above;
   - propose env-var SDK discovery and an lld default;
   - ask swift.org for a portable zip or loose MSIs;
   - offer the CRT/SDK fetcher to the swiftly-on-Windows effort.
5. **Optional:** package the mingw sysroot as a Swift SDK bundle and fix its SwiftPM manifest issue.
6. **Get Microsoft or legal confirmation** of the user-side MSVC CRT download model before shipping it broadly.

## Sources

- `research/legal.md`, `research/landscape.md`, `research/swift-internals.md`
- `xwin/REPORT.md` (branch `exp/xwin-sysroot`)
- `build-eval/DECISION.md` (branch `exp/build-vs-repackage`)
- the MinGW report (branch `exp/mingw`; not yet committed)
