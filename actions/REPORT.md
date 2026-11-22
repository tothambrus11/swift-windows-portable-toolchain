# setup-msvc: results

Composite pwsh action: `uses: tothambrus11/swift-windows-portable-toolchain/actions/setup-msvc@<ref>`.

- **Installed mode:** vswhere, then `VsDevCmd.bat` with gha-setup-vsdevenv's arguments (`-host_arch -arch [-vcvars_ver] [-winsdk]`). It exports new or changed variables plus `Path`.
- **Portable mode:** downloads from Microsoft and exports the vcvars variables (INCLUDE, LIB, LIBPATH, VCToolsInstallDir, …).
  - CRT from the VS channel manifest, sha256-checked: Headers.base, `<arch>`.Store.base, optional `<arch>`.Desktop.base for the static CRT.
  - DIA SDK from the same manifest.
  - Windows SDK from NuGet `Microsoft.Windows.SDK.CPP` + `.<arch>`. A request for `10.0.X.0` maps to the newest NuGet `10.0.X.*`.
  - Laid out as a `/winsysroot` directory, with case-alias symlinks on Linux.
  - Wires the Swift toolchain: `clang.cfg` and modulemaps.
- **Gates:** `accept-license: true` is required for portable mode. `cache` is opt-in (own repo only).

**Runner facts (Nov 2026):**
- `windows-latest` / `windows-2025` ship VS 2026 Enterprise with MSVC 14.29, 14.44 and 14.52 (default), and Windows SDK 10.0.26100.0 only.
- The VS 2026 channel is `https://aka.ms/vs/18/stable/channel`; `/18/release/` doesn't exist. It has CRT packages 14.29–14.53, default 14.52.

## Matrix (final run [45045549284](https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/45045549284))

| cell | result |
|---|---|
| 1. installed: VS present, auto → installed (VS 2026, 14.52, SDK 26100). `cl` hello; Swift 6.2.4 (SwiftyLab): hello, Foundation `-Onone`/`-O`, WinSDK, SwiftPM build/run/test/release, C target | PASS |
| 2. portable x64, Swift 6.4.3: VS/Kits/LLVM hidden, auto → portable. License gate refuses and downloads nothing. hello, Foundation, WinSDK, SwiftPM build/run/test/release, C target, C++ interop, plain clang, `swiftc -static` | PASS |
| 2b. portable x64, Swift 6.2.4 (copy and overlay modulemaps) | PASS (after fixes 2 and 3) |
| 3. selection ×7: env and a compiled probe (`_VC_CRT_*`, `WDK_NTDDI_VERSION`) match the request | PASS |
| 4. windows-11-arm portable, Swift 6.4.3 | PASS |
| 5. cross on ubuntu-latest (clang/lld 22) and macos-latest (brew llvm+lld): `clang-cl /winsysroot -fuse-ld=lld`; C `/MD` and `/MT`; C++17 (iostream, map, filesystem); windows.h/ShlObj + user32; INCLUDE/LIB env only; arm64 sysroot + aarch64 target | PASS (PE32+ x86-64 and ARM64 executables) |
| 6. Hylo | see below |

Version selection (cell 3):

| request | result |
|---|---|
| auto, 14.44, SDK 22621 | portable ("SDK 10.0.22621.0 not installed"). Got 14.44.35207 / 22621; probe CRT 14.44.35220, WDK_NTDDI 0x0A00000C. |
| auto, 14.40, SDK 26100 | portable ("toolset 14.40 not installed (have 14.29.30133, 14.44.35207, 14.52.37025)"). Got 14.40.33807; probe 0x0A000010. |
| auto, 14.44, SDK 26100 | installed (`-vcvars_ver=14.44`). Got 14.44.35207 / 26100. |
| installed, latest, x86 | 14.52 / 26100; the x86 cl build runs. |
| portable, latest, SDK 26100 | 14.52.37025 / 26100 (NuGet 10.0.26100.9457). |
| portable, 14.44, SDK 22621, channel 17 | 14.44.35207 / 22621. |
| portable, 14.50, latest, `cache: true` | 14.50.35717 / 28000; probe 0x0A000012. Cache hit on the next run ("Cache restored … skipping downloads"). |

Cost:
- Portable mode downloads 280–310 MB in 9–15 s; the step takes 11–21 s on Windows and ~15 s on Linux (+2.5 s for ~1650 symlinks).
- Installed mode takes ~5 s.
- `setup-swift-portable`: 34 s (6.2.4) / 81 s (6.4.3) on x64, 158 s on arm64.

## Problems found and fixed

1. **The VS 2026 14.52 STL rejects clang < 22** (`STL1000: Unexpected compiler version`). Swift 6.2.4 ships clang 19 and 6.4.3 ships clang 21, so all their C++ compiles fail, including Hylo's C++ shims with VS present.
   - Installed fix: pin `msvc-version: 14.44`.
   - Portable mode adds `-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH` to `clang.cfg` automatically when the Swift clang is too old, and sets output `stl-mismatch=true`.
2. **Swift 6.2.x packaging bug:** the SDK has import libs `swift_Builtin_float.lib` / `swift_Volatile.lib`, but there are no matching DLLs anywhere, including in the official/SwiftyLab install. 6.4.3 ships them.
   - MSVC link.exe drops the import; lld-link keeps it, so Foundation/WinSDK programs crash at start with `0xC0000135`. This also caused Hylo's "Invalid manifest".
   - Fix: delay-load SDK import libs with no DLL, via `-Wl,/delayload:… -Wl,delayimp.lib` inside `--start/--end-no-unused-arguments` in `clang.cfg`. Output `delayload=…`.
3. **`setup-swift-portable` with 6.2.4:** the bundle has a single `rtl.msi`, which the arch filter skipped. The runtime now goes before the toolchain on PATH.
4. **robocopy leaves `LASTEXITCODE=1`:** steps end with `exit 0`; real errors throw.
5. **Linux case aliases:** PowerShell `-ne` is case-insensitive, so `-cne` is needed. Without it lld-link couldn't find `uuid.lib`/`user32.lib`.
6. **`JsonElement.TryGetProperty`:** its out parameter doesn't bind from PowerShell; replaced with `EnumerateObject`.
7. **`hylo-lang/get-llvm` needs the preinstalled clang,** so the workflow hides VS after it runs.
8. **CMake compiler checks link `msvcrtd.lib`,** so `debug-libs` defaults to true.
9. **LLVM's CMake package links `$VSINSTALLDIR/DIA SDK/lib/amd64/diaguids.lib`.** Portable mode fetches `Microsoft.VisualCpp.DIA.SDK` (8 MB) and sets `VSINSTALLDIR` (`dia-sdk: true`).
10. **`swiftc -emit-library -static` runs `link /lib`,** which resolved to Git's `/usr/bin/link`. Portable mode puts a `link.exe` hard link to lld-link on PATH (`link-shim: true`).

## Hylo integration

Checks out hylo-lang/hylo `main` read-only and replicates its Windows release job:
- Swift 6.2.4, get-llvm 20.1.6, the same spm options and the BuildToolDependencies retry
- `swift build --build-tests`, then `swift test --skip-build --parallel`
- our action replaces gha-setup-vsdevenv, with `winsdk: 10.0.26100.0`

Only release was run; Hylo's own CI skips Windows debug tests.

**SwiftPM:**

| job | run 45044074874 | final 45045549284 |
|---|---|---|
| VS present, SwiftyLab Swift, `msvc-version: 14.44` → installed | PASS: build 6 min, 734/734 XCTest | PASS |
| VS hidden, portable Swift, 14.44 → portable | PASS: build 11 min, tests 10 min, 734/734 | PASS |
| VS hidden, portable Swift, `latest` (14.52 + mismatch define) | PASS, 734/734 | PASS |
| VS present, default toolset 14.52 (what gha-setup-vsdevenv gives today) | FAIL with STL1000 (run 45040709302) | – |

**CMake (Ninja, release): fails in both modes, for reasons outside the action.**
- **VS present:** `LNK1181: cannot open input file …FixedWidthInteger+roundUpToPowerOfTwo.swift.obj` while linking the swift-collections static library through VS `link.exe`. Hylo's CMake uses the Swift toolchain's GNU-style clang for C/C++ even with VS present.
- **VS hidden:** that library links through the lld-link shim, and the build reaches ~[42/257]. It then stops at Hylo's post-link `editbin.exe`, a VS-only tool portable mode does not provide.
- Hylo's own main CI was already red on these Windows jobs at its last run (2026-07-13); the logs have expired.

**Recommended Hylo change:**

```yaml
- uses: tothambrus11/swift-windows-portable-toolchain/actions/setup-msvc@<sha>
  with:
    winsdk: "10.0.26100.0"
    msvc-version: "14.44"
    accept-license: true
```

## Known limitations

- **No `cl.exe` in portable mode;** C/C++ go through clang. CMake projects looking for cl need `export-cc: clang-cl`; don't set it for SwiftPM, which reads `CC`.
- **The STL mismatch define only silences the check.** Prefer `msvc-version: 14.44` with Swift ≤ 6.4.
- **`latest`** means the installed VS default (installed mode) or the channel default (portable). Both are 14.52 today; pin for reproducible CI.
- **`clang.cfg`:** portable mode overwrites the toolchain's existing one.
- **Not tested:** ATL/MFC (not fetched), arm64ec, x86 portable, Swift cross-compilation from Linux (only clang-cl/lld-link was tested), and running the Linux-built exes. NuGet SDKs older than 22000 may use a different layout.
- **`setup-swift-portable`** is Windows-only.
- **License:** an MSVC library license is required (VS Community is fine for individuals, OSS and small orgs). The cache is opt-in and must never be shared across repositories.

## Runs

| run | notes |
|---|---|
| 45040709302 | installed green; TryGetProperty, robocopy, get-llvm, Hylo + 14.52 → STL1000 |
| 45040957471 | selection + macOS green; Linux case-alias bug |
| 45041220067 | Linux green; 6.4.3 C++ STL1000; 6.2.4 `0xC0000135` |
| 45041758669 | mismatch define makes 6.4.3 x64 + arm64 green |
| 45042340266 | Hylo SPM VS + 14.44 green (734); portable "Invalid manifest"; CMake msvcrtd |
| 45042789380 / 45043194930 / 45043664768 | swift_Builtin_float diagnosis; `/delayload` |
| 45044074874 | 6.2.4 portable green; cache hit; 3 Hylo SPM jobs green |
| 45044629825 | DIA SDK; core matrix green (cancelled as a duplicate) |
| **45045549284** | **final:** core + 3 Hylo SPM green; Hylo CMake fails as above |
