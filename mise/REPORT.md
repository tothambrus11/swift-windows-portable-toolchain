# Swift on Windows through mise, without Visual Studio

**Verdict: it works.**

- A vfox (Lua) tool plugin for mise, in `mise/vfox-swift/`, installs the official Swift 6.4.3 on Windows with no Visual Studio, no admin rights, and without running the installer.
- On GitHub runners with VS, Build Tools and the Windows Kits hidden, it passed on **x64 and arm64**:
  - `swift --version`
  - a Foundation program built with `swiftc` (debug and `-O`) and run
  - `swift build`, `swift run`, `swift test` (XCTest and swift-testing) and `swift build -c release` on a small package
- Everything ran through `mise exec` / `mise x`, including from a fresh `cmd` whose PATH held only System32 and mise.
- The same plugin installs swift.org's toolchains on **Linux** (tarball) and **macOS** (`.pkg`).
- With **Visual Studio installed** it downloads nothing from Microsoft and uses VS.

```toml
# mise.toml
[plugins]
swift-portable = "<git URL of the plugin repo>"   # today, from a checkout: mise plugins link swift-portable ./mise/vfox-swift
[tools]
swift-portable = { version = "6.4.3", accept_msvc_license = true }
```
```sh
mise install && mise exec -- swift build
```

**Microsoft licenses.** The MSVC C/C++ runtime (VS Build Tools license) and the Windows SDK are fetched from Microsoft on the user's machine, from the VS channel manifest and from nuget.org. That happens only after an explicit acceptance, either the tool option `accept_msvc_license = true` or `SWIFT_PORTABLE_ACCEPT_MSVC_LICENSE=1`.

Without acceptance, and without VS:
- mise installs Swift only and prints the two license URLs (https://go.microsoft.com/fwlink/?LinkId=2179911, https://aka.ms/WinSDKLicenseURL) with instructions;
- `swift --version` works; linking fails.

After acceptance, the next `mise install` completes the install in 15–20 s through the `MiseInstallSatisfied` hook, without downloading Swift again. CI checks both states. Nothing from Microsoft is bundled or mirrored; the optional prebuilt archive contains only Swift (Apache-2.0).

## Runs

- **Latest, all 7 jobs green:** https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/45041635883
  - official path on x64 and arm64 (VS hidden)
  - VS present
  - prebuilt archive on x64 and arm64 (VS hidden)
  - ubuntu-24.04
  - macos-latest
- **Earlier green run** (official path, VS present, Linux, macOS): https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/45041052162
- **Prebuilt packaging run**, which created the pre-release: https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/45041635733
- **First run:** https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/45040292131
  - arm64 failed because the plugin was linked as `swift`; see §1.
  - macOS failed because `XCTestCase.add(_:)` shadows the package's `add`. Fixed by calling `HelloLib.add`.

| job | Swift step | sysroot step | download |
|---|---|---|---|
| win x64, official, VS hidden | 93 s | 15 s | Swift 2.0 GB (~80 s extraction); CRT 77 MB + SDK 204 MB |
| win arm64, official, VS hidden | 159 s | 20 s | Swift 1.6 GB; CRT + SDK |
| win x64, **prebuilt** | 62 s total | | 469 MB tar.xz (no-asserts) + CRT/SDK |
| win arm64, **prebuilt** | 62 s total | | 391 MB tar.xz + CRT/SDK |
| win x64, VS present | ~95 s | – (uses VS) | nothing from Microsoft |
| ubuntu-24.04 | 23 s | – | 1.1 GB tarball |
| macos-latest | 60 s (`pkgutil --expand-full`) | – | |

## 1. What mise does for Swift today

Read at jdx/mise commit 5330c6b (mise 2026.11.12).

- **The built-in tool doesn't support Windows.** [`src/plugins/core/swift.rs`](https://github.com/jdx/mise/blob/5330c6b88663a90fdde69cea3730adff51726c8e/src/plugins/core/swift.rs):
  - macOS: `pkgutil --expand-full`.
  - Linux: untars the distro tarball.
  - Windows: `todo!("install from exe")` at line 104.
  - It already builds correct Windows URLs, takes versions from swiftlang/swift GitHub releases, and sets no environment variables.
- **Registry and docs.** `registry/swift.toml` is `backends = ["core:swift"]`, `os = ["linux","macos"]`, and `docs/lang/swift.md` says "Windows is not supported".
- **On Windows the built-in tool still runs**, downloads the full installer (1.6 GB on arm64), then panics with `not yet implemented: install from exe`.
- **No Windows request exists.** mise issues are converted to Discussions; the Swift-related ones (#11751, #13291, #13289, #13306, #11295, #10572, #15786) don't cover Windows.

**Finding: a plugin named `swift` does not replace the built-in tool on Windows.** The docs say an installed plugin with a core tool's name takes precedence (rule 5 of "How mise picks a backend").

What we saw:
- `mise ls-remote swift` was served by the plugin.
- `mise tool swift --backend` printed `vfox:swift`.
- But `mise use swift@6.4.3` ran the built-in install and panicked.

Hypothesis, unconfirmed: `backend::get()` (src/backend/mod.rs:760) returns the backend cached under the short name, and that cache is seeded with `CORE_PLUGINS`. **Workaround:** name the plugin `swift-portable`.

## 2. Which mise extension mechanism fits

- **vfox tool plugin (Lua): the best fit, and what was built.**
  - The Lua runtime is built into mise, including on Windows.
  - `PostInstall` can run anything: `os.execute` / `cmd.exec` go through `cmd /s /c`. There are also `http.download_file` and `file.*`.
  - `EnvKeys` returns arbitrary variables plus several PATH entries, cached per version and options.
  - Tool options arrive in `ctx.options`, which carries the license acceptance.
  - `MiseInstallSatisfied` lets a later `mise install` finish an existing install after acceptance.
- **asdf plugin (bash):** mise doesn't run asdf tools on Windows.
- **`github:` / `http:` backend + prebuilt archive:** handles `.tar.*`/`.zip` only (no `.7z`) and has a single `bin_path` with no arbitrary environment. INCLUDE/LIB/SDKROOT would need `[env]` in every project, and the MSVC fetch a user-written `postinstall`. Clumsy.
- **PR to the built-in tool (Rust):** best UX long term (§3).
- **vfox backend plugin:** overkill. **`[env] _.source` / tasks:** glue only.

Vfox APIs used, all working on Windows:
- `http.get`, with mise adding the GitHub token
- `json`
- `file.read`, `exists`, `join_path`, `move`, `glob`
- `cmd.exec`
- `os.execute`
- `RUNTIME.osType` / `archType` / `pluginDirPath`

Limits:
- `PreInstall` downloads can only be extracted when they are `.tar.*` or `.zip`, so the Burn `.exe` and the `.pkg` are handled in `PostInstall`.
- `http.get` bodies are capped at 128 MiB.
- mise's tar extraction does not recreate hard links, which costs about 600 MB more disk with the prebuilt archive.

## 3. Upstream options

**(a) PR adding Windows to the built-in `core:swift`.** Needed:
1. Replace the `todo!` with the extraction:
   - carve the CABs out of `.wixburn` and expand them;
   - `msiexec /a … TARGETDIR=<short dir>` for bld/cli/rtl/windows;
   - merge into `LocalApp\Programs\Swift\*`;
   - move the runtime DLLs into `Runtimes\<v>\usr\bin`;
   - copy in the FoundationXML/swiftRegexBuilder assemblies (works around error 14001).
2. `list_bin_paths` + `exec_env` (SDKROOT).
3. `bail!` on Windows before downloading until (1) exists. This is trivial and worth sending on its own.
4. Registry `os` + docs.

The VS-free part (license-gated Microsoft downloads, `clang.cfg`, INCLUDE/LIB) likely doesn't belong in the built-in tool. Propose it in a Discussion first.

**(b) Standalone vfox plugin repo: recommended now.** For example `mise-swift-portable`, used via `[plugins]` / `mise plugins install` / `vfox:owner/repo`. The prototype is already laid out as a plugin root; it only needs to move to its own repo root.

**(c) The mise registry: closed.** `docs/contributing/registry.md` says "New `asdf` and `vfox` entries are rejected for supply-chain security reasons".

**Recommendation:**
1. Ship (b) with `source = "official"` as the default and `source = "prebuilt"` as opt-in.
2. Upstream, file the small `bail!` fix and a Discussion about Windows in the built-in tool.
3. Later, share the MSVC/SDK logic with `actions/setup-msvc`.

## 4. The prototype (branch `exp/mise`)

- `mise/vfox-swift/metadata.lua`: metadata; `legacyFilenames = {".swift-version"}`.
- `hooks/available.lua`: versions from swift.org `releases.json`, filtered by host platform, with `created_at`.
- `hooks/pre_install.lua`: Linux tarball URL; Windows `source = "prebuilt"` asset URL and sha256; otherwise no URL.
- `hooks/post_install.lua`: Windows runs `scripts/setup-portable-swift.ps1 -Part swift|env`, then `-Part sysroot -AcceptLicense` or prints the license notice. macOS runs `pkgutil`.
- `hooks/env_keys.lua`: reads `mise-env.json`.
- `hooks/mise_install_satisfied.lua`, `hooks/parse_legacy_file.lua`.
- `lib/swiftorg.lua`: options, vswhere VS detection, distro mapping, URLs, prebuilt lookup.
- `scripts/setup-portable-swift.ps1`: the proven xwin script, plus:
  - `-Part all|swift|sysroot|env`;
  - `-StageDir`, a short temp staging dir that avoids MAX_PATH error 1603 under long mise paths;
  - BOM-free `mise-env.json`.
- `.github/workflows/mise.yml` (tests), `.github/workflows/mise-prebuilt.yml` (pre-release build), `mise/ci/` (VS hiding, tests).

| option | values | effect |
|---|---|---|
| `accept_msvc_license` | `true` / env `SWIFT_PORTABLE_ACCEPT_MSVC_LICENSE=1` | accept the MSVC runtime + Windows SDK licenses |
| `msvc` | `auto` (default) / `portable` / `system` | `auto`: use VS if vswhere finds the VC tools for this arch, else the portable sysroot if accepted. `portable`: always portable; fails without acceptance. `system`: never download from Microsoft. |
| `source` | `official` (default) / `prebuilt` | Windows: unpack swift.org's installer, or use the repackaged archive |
| `no_asserts`, `full` | `true` | no-asserts toolchain; add lldb / sourcekit-lsp / python |
| `swift_platform` | e.g. `ubuntu24.04` | force a Linux distro build |

Environment on Windows:
- PATH: toolchain and runtime `usr\bin`.
- `SDKROOT`, `SWIFT_PORTABLE_ROOT`.
- With the sysroot also: INCLUDE, LIB, VCToolsInstallDir, VCToolsVersion, VCINSTALLDIR, UniversalCRTSdkDir, UCRTVersion, WindowsSdkDir, WindowsSDKVersion, WindowsSDKLibVersion.
- `clang.cfg` / `clang++.cfg` are written next to the toolchain's clang.

Design notes:
- Everything lives in the install dir, so `mise uninstall` removes it all, with no registry or global state.
- The sysroot (~640 MB) is duplicated per Swift version; a shared `msvc-sysroot` tool would fix that.
- The plugin prefers `pwsh` and falls back to Windows PowerShell 5.1; only `pwsh` was tested in CI.
- There is no GPG/sha256 verification on Linux, because swift.org publishes no checksums.

### Prebuilt archive (`source = "prebuilt"`)

Pre-release https://github.com/tothambrus11/swift-windows-portable-toolchain/releases/tag/swift-6.4.3-portable.0, built by `mise-prebuilt.yml` with `setup-portable-swift.ps1 -Part swift -NoAsserts` and packed with the in-box `tar.exe -cJf`.

Contents:
- bld/cli/rtl/windows MSIs plus two assemblies from `ide`
- the host-arch SDK only
- identical binaries hard-linked
- `LICENSE.txt` (Swift), `LICENSE-LLVM.txt` and `README-portable.txt`

| arch | size | sha256 |
|---|---|---|
| x64 | 469 MB | 99934abc33c978d6550e0750b45b5b4bd3636c9c1cd3aa197b4e0943769d1444 |
| arm64 | 391 MB | 73e9f0c1fffc67bf1273255dcd988494ac6c2303b94aaabdd8dcdadd7410475f |

- **Install time:** 62 s through mise, compared with 108 s (x64) / 179 s (arm64) for the official path. No msiexec is needed, and `mise lock` can record the URL and checksum.
- **Caveats:**
  - Users have to trust our CI build.
  - mise loses the hard links on extraction.
  - **The third-party notice set is missing.** The installer tree ships none, so a production release needs notices for ICU, libxml2, curl, zlib and the rest.

## Draft upstream texts (not filed)

**Bug: built-in `core:swift` on Windows downloads the 2 GB installer, then panics with `not yet implemented: install from exe`**

> With mise 2026.11.12 on Windows (x64 and arm64), `mise use swift@6.4.3` downloads `swift-6.4.3-RELEASE-windows10-arm64.exe` (1.6 GB) and then crashes:
> ```
> The application panicked (crashed).
> Message:  not yet implemented: install from exe
> Location: src\plugins\core\swift.rs:104
> ```
> 1. `registry/swift.toml` has `os = ["linux","macos"]`, yet the core tool is still used on Windows. `install_version_` should `bail!` before downloading.
> 2. With a vfox plugin linked as `swift`, `mise tool swift --backend` says `vfox:swift`, but the install runs the core implementation. That contradicts rule 5 of "How mise picks a backend".
>
> ```rust
> if cfg!(windows) {
>     bail!("mise cannot install swift.org's Windows toolchain yet (it is a WiX installer bundle); use the official installer/winget or a plugin");
> }
> ```

**Discussion: Windows support for `core:swift` via portable extraction of the official installer**

> The swift.org Windows toolchain (a WiX Burn bundle) can be installed per-user without running it and without admin rights:
> 1. Carve and expand the CABs.
> 2. `msiexec /a` bld/cli/rtl/windows.
> 3. Merge `LocalApp\Programs\Swift`.
> 4. Put the toolchain and runtime `usr\bin` on PATH and set SDKROOT.
>
> With VS (or Build Tools + Windows SDK) installed, `swift build`/`swift test` then work. It already works as a vfox plugin, tested on x64/arm64. Gotchas:
> - `cli.msi` needs the FoundationXML/swiftRegexBuilder assemblies that only `ide.msi` ships (error 14001).
> - `msiexec /a` fails with 1603 on deep paths.
>
> Would a PR porting this to `swift.rs` be welcome? The VS-free part would stay in the plugin.
