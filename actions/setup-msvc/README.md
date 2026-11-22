# setup-msvc

A composite GitHub Action that gives a job an **MSVC CRT + Windows SDK** environment, like running
`vcvarsall.bat`. You choose the toolset and SDK versions.

- **installed mode:** if the runner's Visual Studio has the requested toolset and SDK, the action runs
  `VsDevCmd.bat` with the same arguments as `compnerd/gha-setup-vsdevenv` and exports the resulting
  environment.
- **portable mode:** otherwise, it downloads the MSVC CRT (from the Visual Studio channel manifest) and the
  Windows SDK (from NuGet) **directly from Microsoft** into a `/winsysroot`-style directory, and exports a
  vcvars-equivalent environment. Portable mode works on **Windows, Linux and macOS**. On Linux and macOS
  the directory is a cross-compilation sysroot for `clang-cl`/`lld-link` or `swiftc -target *-windows-msvc`.
- **Swift:** if a Swift toolchain is on `PATH` (or named explicitly), portable mode also wires it to the
  sysroot. It writes `clang.cfg` with `-fuse-ld=lld` and the sysroot, and places Swift's ucrt, WinSDK and
  vcruntime modulemaps. After that, `swiftc`, `swift build`, `swift test` and SwiftPM C targets work without
  Visual Studio.

```yaml
- uses: tothambrus11/swift-windows-portable-toolchain/actions/setup-msvc@exp/setup-msvc-action
  with:
    winsdk: 10.0.26100.0      # optional
    msvc-version: latest      # optional, e.g. 14.44
    accept-license: true      # required whenever portable mode may be used
```

Pin a commit SHA instead of the branch name for reproducible CI.

## Drop-in replacement for `compnerd/gha-setup-vsdevenv` (Hylo example)

`hylo-lang/hylo` `.github/workflows/build-and-test.yml` has this step today:

```yaml
      - name: Set up Visual Studio Development Environment (Windows)
        if: ${{ runner.os == 'Windows' }}
        uses: compnerd/gha-setup-vsdevenv@main
        with:
          winsdk: "10.0.26100.0"
```

The replacement:

```yaml
      - name: Set up MSVC + Windows SDK (Windows)
        if: ${{ runner.os == 'Windows' }}
        uses: tothambrus11/swift-windows-portable-toolchain/actions/setup-msvc@<sha>
        with:
          winsdk: "10.0.26100.0"
          accept-license: true   # only used if the runner's VS lacks the toolset/SDK (portable fallback)
```

How it behaves:
- **On `windows-2025`** VS 2022 has SDK 10.0.26100.0, so the action picks installed mode and produces the
  same environment as gha-setup-vsdevenv: the same `VsDevCmd.bat -host_arch -arch -winsdk` call, with new
  variables and `Path` exported.
- **Without VS**, it falls back to portable mode, and the SwiftPM jobs work unchanged.
- **The CMake job** declares `LANGUAGES C CXX Swift`. Without VS there is no `cl.exe`, so add
  `export-cc: clang-cl` to that job only. It exports `CC`/`CXX` pointing at the Swift toolchain's
  `clang-cl.exe`. CMake then uses `clang-cl` + `lld-link`, and `rc.exe`/`mt.exe` come from the NuGet SDK.
  Don't set `export-cc` for SwiftPM jobs: SwiftPM reads `CC` as its clang.

## Inputs

| input | default | meaning |
|---|---|---|
| `arch` | runner arch | target: `x64`, `arm64`, `x86` (`amd64`/`aarch64` accepted) |
| `host-arch` (`host_arch`) | runner arch | `vcvarsall` host arch (installed mode) |
| `winsdk` | `latest` | e.g. `10.0.26100.0`, `10.0.22621.0`. Portable: `10.0.X.0` → newest NuGet `Microsoft.Windows.SDK.CPP` `10.0.X.*`; an exact NuGet version (`10.0.26100.4188`) also works |
| `msvc-version` (`toolset_version`) | `latest` | e.g. `14.44`, `14.50`, `14.52`. `latest` = VS default toolset (installed) or the channel's default toolset (portable) |
| `vs-channel` | `18` | portable: `18` = VS 2026 Stable channel (has 14.29 … 14.5x), `17` = VS 2022, or a channel URL |
| `mode` | `auto` | `auto`: installed if the runner's VS satisfies arch + toolset + SDK, else portable; always portable off Windows. `installed`: fail if not satisfiable. `portable`: always download |
| `crt-static` | `true` | portable: also fetch the static CRT (`libcmt`, `libcpmt`, …; +50–70 MB). Plain `clang foo.c` defaults to `/MT` and needs it |
| `debug-libs` | `true` | portable: keep the debug CRT libs (`msvcrtd`, `libcmtd`, …). CMake's compiler checks and Debug builds link them; `false` saves ~40 MB on disk |
| `dia-sdk` | `true` | portable: also fetch the DIA SDK (`<sysroot>/DIA SDK`, ~8 MB) and set `VSINSTALLDIR` to the sysroot. LLVM's CMake package (e.g. Hylo's LLVM) links `diaguids.lib` |
| `swift-toolchain` | `auto` | portable: the Swift toolchain to wire: `auto` (the `swift.exe` on PATH, Windows), `none`, or a path |
| `modulemaps` | `copy` | portable: `copy` Swift's modulemaps into the sysroot, `overlay` (a clang VFS overlay referenced from `clang.cfg`), or `none` |
| `export-cc` | `false` | portable: `clang-cl` exports `CC`/`CXX`=clang-cl (for CMake C/C++), or give an explicit path |
| `vs-components` (`components`) | – | installed: extra VS components the instance must have (`;`-separated, `vswhere -requires`) |
| `accept-license` | `false` | **must be `true` for portable mode** (see [Licenses](#licenses)) |
| `install-dir` | `$RUNNER_TEMP/setup-msvc` | portable: where the sysroot goes |
| `cache` | `false` | portable: opt-in `actions/cache` of the sysroot in *your* repo (see [Licenses](#licenses)) |

## Outputs

| output | meaning |
|---|---|
| `mode` | `installed` or `portable` |
| `msvc-version` | full toolset version (`VCToolsVersion`), e.g. `14.44.35207` |
| `winsdk-version` | e.g. `10.0.26100.0` |
| `sysroot` | portable: the `/winsysroot` root (`VC/`, `Windows Kits/10/`); empty in installed mode |
| `vc-tools-dir`, `winsdk-dir` | `VCToolsInstallDir`, `WindowsSdkDir` |
| `vs-install-path` (`install_path`) | installed: the VS installation path |
| `swift-toolchain` | portable: the toolchain `usr/bin` whose `clang.cfg` was written |
| `cache-hit` | portable: `true` when an existing (cached) sysroot was reused |

**Exported environment.**
- **Installed mode:** everything `VsDevCmd.bat` adds or changes, `Path` included, which is what
  gha-setup-vsdevenv exports.
- **Portable mode:**
  - the vcvars variables: `INCLUDE`, `EXTERNAL_INCLUDE`, `LIB`, `LIBPATH`, `VCINSTALLDIR`,
    `VCToolsInstallDir`, `VCToolsVersion`, `WindowsSdkDir`, `WindowsSDKVersion`, `WindowsSDKLibVersion`,
    `UniversalCRTSdkDir`, `UCRTVersion`, `VSCMD_ARG_TGT_ARCH`, `VSCMD_ARG_HOST_ARCH`;
  - on Windows, `WindowsSdkBinPath`/`WindowsSdkVerBinPath`, with the SDK `bin` (rc.exe, mt.exe) added to
    `PATH`;
  - `WINSYSROOT`.

  The list separator is `;` on every OS, because clang-cl's `INCLUDE` and lld-link's `LIB` parsing expect it.
  The action also writes `<sysroot>/activate.ps1`.

## What portable mode downloads

- **MSVC CRT.** The action reads the Visual Studio channel (`https://aka.ms/vs/18/stable/channel` or
  `…/17/release/channel`) and its package manifest. From it, it takes three VSIX packages and checks each
  against the sha256 in the manifest:
  - `Microsoft.VC.<v>.CRT.Headers.base`: the vcruntime and STL headers;
  - `Microsoft.VC.<v>.CRT.<arch>.Store.base`: `msvcrt.lib`, `vcruntime.lib`, `msvcprt.lib`, `oldnames.lib`;
  - `Microsoft.VC.<v>.CRT.<arch>.Desktop.base`: the static CRT. This one is optional.

  PDBs, debug libs and the store/uwp/onecore variants are dropped. `latest` follows
  `Microsoft.VisualCpp.CRT.Headers`, the channel's default toolset; in VS 18.12 that is 14.52. You can pin
  `14.29` … `14.53` explicitly.
- **Windows SDK.** NuGet `Microsoft.Windows.SDK.CPP` provides `c/Include`, and `Microsoft.Windows.SDK.CPP.<arch>`
  provides `c/ucrt`, `c/um` and, on Windows, `c/bin`. The NuGet SDK is used because xwin's SDK lacks
  `corecrt_math.h`.
- **Layout:**
  - `<sysroot>/VC/Tools/MSVC/<ver>/{include,lib/<arch>}`
  - `<sysroot>/Windows Kits/10/{Include,Lib}/<sdkver>/{ucrt,um,shared,...}`

  This is the layout `clang-cl /winsysroot` expects. It is about 80–110 MB of CRT and 200–260 MB of SDK
  downloads.
- **Case-sensitive file systems (Linux).** The SDK headers include each other with inconsistent case
  (`<WinDef.h>` vs `windef.h`), and linkers look for `kernel32.lib`/`OLDNAMES.lib`. Like xwin, the action
  scans every `#include` and creates symlinks for each spelling that is used. It also adds lower-case
  aliases for all headers and libs, plus `UPPER.lib` aliases.
- **Swift wiring (Windows).**
  - It writes `clang.cfg` and `clang++.cfg` next to the toolchain's `clang.exe`, containing
    `-fuse-ld=lld -Xmicrosoft-windows-sys-root "<sysroot with doubled backslashes>"`. Forward slashes there
    crash swift-frontend's VFS overlay.
  - It copies Swift's `ucrt`, `winsdk_*` and `vcruntime` modulemaps (or overlays them) next to the headers.

  The runner's existing `clang.cfg` is overwritten.

To get Swift itself without the installer, use the companion action
[`actions/setup-swift-portable`](../setup-swift-portable/action.yml) (`swift-version: 6.2.4`, …). It
extracts the official swift.org installer without running it, with no admin rights or registry writes.

## Licenses

Portable mode downloads Microsoft software **from Microsoft's servers, inside your job**. Nothing is
redistributed by this action or repository. The log prints the applicable license URLs before downloading,
and the action refuses to run in portable mode unless `accept-license: true`.

- **MSVC CRT:** the Visual Studio (Build Tools) license terms, read live from the channel. For VS 2026 that is
  https://go.microsoft.com/fwlink/?LinkId=2327714; for VS 2022, https://go.microsoft.com/fwlink/?LinkId=2179911.
  **Using the MSVC libraries requires a Visual Studio license.** Visual Studio Community is fine for
  individuals, open-source projects, academic use and small organisations. Larger organisations need
  Professional/Enterprise or a Build Tools entitlement. Check the terms for your case.
- **Windows SDK:** https://aka.ms/WinSDKLicenseURL, read from the NuGet `.nuspec`.
- **`cache: true`** stores the downloaded Microsoft files in **your repository's** Actions cache. It is
  opt-in, because it is a copy of Microsoft binaries kept by GitHub on your behalf, and whether that is
  acceptable is your call. Never share or mirror that cache across repositories or publish it as an artifact.
  Without `cache`, every job downloads fresh from Microsoft, in about 20–40 s on GitHub runners.
- In installed mode, nothing is downloaded and the runner image's own Visual Studio license applies.

## Local use

```powershell
$env:SMSVC_MODE = 'portable'; $env:SMSVC_ACCEPT_LICENSE = 'true'; $env:SMSVC_INSTALL_DIR = "$HOME\msvc-sysroot"
pwsh ./actions/setup-msvc/setup-msvc.ps1 -Phase all
. "$HOME\msvc-sysroot\activate.ps1"
```

The script needs PowerShell 7 (`pwsh`), because it uses `System.Text.Json`.
