# Distributing the portable, VS-free Swift toolchain through Windows package and tool managers

## Summary

- **Scoop is the best fit, and the prototype works.**
  - User-level, no admin rights, and already the usual way to install Swift on Windows (Main has `swift.json`).
  - It can share one Microsoft sysroot between Swift versions through a `depends` app.
  - The bucket has three manifests:
    - `msvc-sysroot`: license-gated download of the MSVC runtime and Windows SDK
    - `swift-portable`: the prebuilt archive
    - `swift-portable-official`: the swift.org installer, unpacked
  - Green on x64 and arm64 with VS hidden, and on x64 with VS present (VS is reused; nothing is downloaded from Microsoft). Install takes 53–60 s.
- **vfox is second.**
  - The mise plugin was ported with `lib/compat.lua` and four vfox-specific fixes; one plugin source now runs in both vfox and mise.
  - Green on x64 (official installer, asserts build), arm64 (prebuilt) and x64 with VS present.
  - The vfox-plugins registry accepts new plugins by PR, unlike mise's registry.
- **A rustup-style bootstrapper** (`irm …/install.ps1 | iex`) is the simplest baseline and was green on the first run. It is also the reference implementation for a swiftly integration.
- **One MSVC/WinSDK sysroot per user and architecture,** shared by every Swift version, in every prototype (including mise). This fixes the per-version duplication in the original mise prototype.
- **Only PATH and SDKROOT need to be persistent.**
  - INCLUDE, LIB and the vcvars-style variables can stay unset, because `clang.cfg` (`-Xmicrosoft-windows-sys-root`) is enough for swiftc, SwiftPM and clang. Verified in fresh shells on x64 and arm64.
  - This is what makes static Scoop `env_set` and vfox `EnvKeys` practical.
- **New upstream bug:** on the asserts toolchain, an *empty but defined* `VCToolsInstallDir` makes swift-frontend assert ("virtual path not absolute"). An empty `VCINSTALLDIR` trips a different assert. Draft issue below.

## Comparison of all candidates

| Candidate | Windows support | Non-admin | Can run the license-gated MSVC/SDK fetch | Persistent env | Sysroot shared across Swift versions | Per-project pinning | CI use | Upstream/registry prospects | Effort |
|---|---|---|---|---|---|---|---|---|---|
| **Scoop (custom bucket)** ✅ prototype | Native, mature | Yes (by design) | Yes: `installer.script` runs PowerShell in-process. Gate via env var, or a `Read-Host` prompt when interactive | `env_add_path`/`env_set` (static, so versions are renamed to `current`). Keeps REG_EXPAND_SZ | **Yes:** `msvc-sysroot` is a `depends` app; its `post_install` re-links the installed Swift versions | No (global `current`; `scoop reset` switches) | Good (`-RunAsAdmin` on runners) | Own bucket today. Main later is possible as a separate `msvc-sysroot` app (precedent: `windows-sdk-buildtools` pulls an MS nupkg), but the gate is unusual | Low |
| **vfox standalone** ✅ prototype | Native (v1.1.0). Bugs: `exec` ignores PATHEXT; `cmd /c` quoting | Yes | Yes: `PostInstall` + `os.execute`. No tool options, so the gate is an env var checked in `PreInstall` | `EnvKeys`, computed from the path only. `vfox use -g` writes HKCU | Yes (per-user dir under LOCALAPPDATA) | **Yes** (`.vfox.toml`, `.tool-versions`, `.swift-version`) | Good (`vfox exec`) | **vfox-plugins registry takes PRs**; none has swift yet | Low–medium (port done) |
| mise (benchmark, `exp/mise`) | Native | Yes | Yes (tool option) | EnvKeys | Now yes (same plugin, verified) | Yes | Very good | Registry closed to vfox plugins; core `swift` is Linux/macOS only | Done |
| **Bootstrapper** (`install.ps1`) ✅ prototype | Native | Yes | Yes (`-AcceptMsvcLicense`, env var, or prompt) | Writes HKCU PATH (REG_EXPAND_SZ) + SDKROOT | Yes | No (re-run to switch) | Excellent | Ours; also the reference for swiftly | Very low |
| swiftly | Not on main. PR #619 (open) builds it and can `list`/`use`; `install` not supported yet | Pitch unclear (MSI via `MsiInstallProductW`) | Not designed for it: the pitch ignores VS, MSVC and the SDK | Proxies + per-invocation `updateEnvironmentWithToolchain` (ideal: no global env) | Natural (swiftly home) | Yes (`.swift-version`) | Planned | **The official manager.** Best long-term home; draft below | Medium |
| WinGet | Native | Yes (`Swift.Toolchain` is `Scope: user`) | **No:** no post-install scripts (winget-cli #1279 closed); portable/zip only links executables | Portable sets PATH only (no SDKROOT) | No | No | OK | Could only depend on `Microsoft.VisualStudio.BuildTools`, the opposite of VS-free. A `winget configure` (DSC) file could run the script, but it lives outside winget-pkgs | n/a |
| Chocolatey | Native | Admin by default | Yes: `chocolateyInstall.ps1`, gate via `--params "'/AcceptMsvcLicense'"` | `Install-ChocolateyEnvironmentVariable` | Possible (dependency package) | No | OK | Moderation allows install-time downloads with checksums; no current Swift package | Medium |
| conda-forge / pixi | Native | Yes | **Weak:** post-link scripts are discouraged, and pixi doesn't run them unless `run-post-link-scripts = "insecure"`. Only a `pixi run setup-msvc` task is realistic | `etc/conda/activate.d/*` | Yes (outside the env) | Yes | Good | No swift package; staged-recipes PR #34391 (open, win-64, relies on VS) | High |
| proto (moonrepo) | Native | Yes | WASM plugin `native_install`/`post_install` hooks; TOML plugins have no hooks | WASM `activate_environment` | Yes | Yes (`.prototools`) | Good | Built-in `swift` plugin returns UnsupportedOS on Windows; third-party plugins load by locator | Medium–high (Rust→WASM) |
| aqua | Some | – | No hooks | – | – | – | – | No swift in the registry | – |
| asdf | No native Windows (WSL only) | | | | | | | | |
| Nix | No native Windows (WSL only) | | | | | | | | |

## Recommendation

1. **Ship a Scoop bucket now.**
   - It needs a stable, tagged URL for `setup-portable-swift.ps1`, pinned by sha256.
   - `build-bucket.ps1` generates the manifests; `checkver`/`autoupdate` are already in them.
   - Make `swift-portable` (prebuilt, ~55 s) the default; keep `swift-portable-official` for users who don't want to trust our CI build.
2. **Publish the vfox plugin as its own repo** and send a vfox-plugins registry PR. The same plugin serves mise users via `[plugins]`.
3. **Keep `install.ps1` as the zero-dependency path,** for docs and CI.
4. **Strategically, go for swiftly.** Comment on the pitch and PR #619 with the VS-free design once `install` lands.
5. **Skip:**
   - WinGet: can't run the fetch.
   - Chocolatey: admin-centric, adds little over Scoop.
   - conda/pixi: no post-link under pixi; revisit if PR #34391 lands.
   - proto: WASM effort with no extra reach.
   - aqua, asdf, Nix.

## Prototype design (branch `exp/managers`, under `managers/`)

### `common/setup-portable-swift.ps1`

Copied from `exp/mise`, with these additions:
- `-Part fetch-sysroot`: fetches the CRT and SDK into `-SysrootDir` with no Swift needed, and writes `sysroot.json` (versions, accepted license URLs, INCLUDE/LIB).
- `-Part link`: configures a toolchain for an existing shared sysroot (modulemaps, `clang.cfg`, env files).
- `-PrebuiltUrl` / `-PrebuiltSha256`: extracts the Swift-only tar.xz with the in-box bsdtar, which **keeps hard links**. vfox's extractor drops `TypeLink` entries, and mise loses the hard links too.
- `-InstallerPath`: reuses the swift.org bundle Scoop already downloaded and hash-checked.
- `-StableNames`: renames `Swift\{Toolchains,Runtimes,Platforms}\<ver>` to `current`.

### `scoop/`

`src/*.ps1` holds the installer and post_install scripts; `build-bucket.ps1` generates `bucket/{msvc-sysroot,swift-portable,swift-portable-official}.json`.

- **msvc-sysroot:**
  - Version = the Windows SDK NuGet version (checkver reads the NuGet index).
  - With VS present it writes `{kind: vs}` and downloads nothing; `SWIFT_PORTABLE_MSVC=portable` overrides.
  - Otherwise it prints the two license URLs and requires `SWIFT_PORTABLE_ACCEPT_MSVC_LICENSE=1` or an interactive "y". Without that it throws, and nothing is downloaded.
  - `post_install` re-links every installed swift-portable version.
- **swift-portable / -official:**
  - `depends: msvc-sysroot`.
  - `env_add_path` for the toolchain and runtime `usr\bin`, `env_set` for SDKROOT.
  - `clang.cfg` points at `apps\msvc-sysroot\current\winsysroot`.
- **Caveat:** after the gate refuses, Scoop marks msvc-sysroot "Install failed", so `scoop uninstall msvc-sysroot` is needed before retrying. A real bucket should document this, or leave a notice instead of throwing.

### `vfox/swift/`

The mise plugin, ported to standalone vfox (`pack.ps1` builds the zip).
- `lib/compat.lua` provides `file`/`cmd` fallbacks; vfox has no `file` or `cmd` modules and no `ctx.options`.
- `compat.main_sdk` abstracts the install path and version between vfox and mise.
- `cmd` lines get an extra pair of quotes, because vfox runs `cmd /c` without `/s`.
- Under vfox the license gate is checked in `PreInstall`.
- `EnvKeys` is computed from the path alone.
- Shared sysroot: `%LOCALAPPDATA%\swift-portable\msvc-sysroot-<arch>`, or `SWIFT_PORTABLE_SYSROOT`; mise uses it too.

### `bootstrap/install.ps1`

- Layout: `%LOCALAPPDATA%\swift-portable\toolchains\<ver>` plus `msvc-sysroot-<arch>`.
- Options: `-Source prebuilt|official`, `-Msvc auto|portable|system`, `-AcceptMsvcLicense` (or env var, or prompt), `-List`.
- Writes the user PATH as REG_EXPAND_SZ through the registry API. `[Environment]::SetEnvironmentVariable(..,'User')` would flatten it to REG_SZ.

### CI

- `.github/workflows/managers.yml`.
- `common/ci/{hide-vs,clean-env}.ps1`, copied from xwin.
- `fresh-env.ps1`: simulates a new terminal (minimal machine PATH plus HKCU values).
- `test-swift.ps1`: `swift --version`, a Foundation program with swiftc (debug and `-O`) plus run, then `swift build`, `swift run`, `swift test` (XCTest and swift-testing).

## Results

Final all-green run (10 jobs): https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/45053113177

| Job | License gate | Install | Build/run/test | Notes |
|---|---|---|---|---|
| scoop x64, VS hidden | refused, nothing from MS | 56 s | fresh shell, all pass | second toolchain `swift-portable-official` (asserts) installed in 160 s, **reusing** the sysroot |
| scoop arm64, VS hidden | refused | 60 s | all pass | 17 hard links kept |
| scoop x64, VS present | – | 58 s, VS reused, no MS download | all pass | |
| vfox x64 official (asserts), VS hidden | refused in PreInstall | 125 s | `vfox exec` and fresh shell after `vfox use -g`, all pass | |
| vfox arm64 prebuilt, VS hidden | refused | 51 s | all pass | |
| vfox x64 prebuilt, VS present | – | 41 s, VS reused | all pass | |
| mise x64 prebuilt, same plugin | – | 64 s | `mise exec`, all pass | shared sysroot under mise |
| bootstrap x64 | refused | 52 s (Swift 33 s + CRT 77 MB / SDK 204 MB 16 s) | fresh shell, all pass | INCLUDE/LIB unset |
| bootstrap arm64 | refused | 60 s (CRT 106 MB / SDK 255 MB) | fresh shell, all pass | |
| probe (asserts toolchain) | | | see the bug below | |

Debugging runs:
- 45049747042: bootstrap green first try; vfox `cmd` quoting; `scoop bucket add` rejects local paths.
- 45050008918, 45050299750: Scoop green on all three jobs; vfox `EnvKeys` link-path issue; the asserts toolchain crashed in a fresh shell.
- 45050721367: mise green.
- 45051100740 – 45052669321: narrowing the fresh-shell crash. Ruled out: junctions, symlinks, renamed dirs, PATH entries.
- **45053113177: root cause isolated.**

| case (asserts toolchain, clean env) | result |
|---|---|
| baseline; extra PATH entries | OK |
| **empty `VCToolsInstallDir`** | **ASSERT `virtual path not absolute`** |
| **empty `VCINSTALLDIR`** | **ASSERT `unsupported toolset layout (VS2017+ required)`** |
| empty `UniversalCRTSdkDir` / `WindowsSdkDir` | OK |

The trigger was that `hide-vs.ps1` leaves empty HKCU values, which PowerShell 7.5+ turns into empty variables. `fresh-env.ps1` now skips them.

## Draft upstream texts (not filed)

**1. swiftlang/swift (ClangImporter) + llvm-project: an empty `VCToolsInstallDir` or `VCINSTALLDIR` crashes swift-frontend**

> With Swift 6.4.3 on Windows (asserts toolchain, the installer default), a *defined but empty* `VCToolsInstallDir` (e.g. PowerShell 7.5+ `$env:VCToolsInstallDir = ''`) makes every compile fail with `Assertion failed: sys::path::is_absolute(VirtualPath) && "virtual path not absolute", file …\llvm\lib\Support\VirtualFileSystem.cpp, line 2769`. An empty `VCINSTALLDIR` fails with `Assertion failed: VCTools.Layout == llvm::ToolsetLayout::VS2017OrNewer && "unsupported toolset layout (VS2017+ required)"` in ClangIncludePaths.cpp.
>
> `llvm::findVCToolChainViaEnvironment` (llvm/lib/WindowsDriver/MSVCPaths.cpp) returns true for an empty variable. `GetWindowsFileMappings` (swift/lib/ClangImporter/ClangIncludePaths.cpp) then maps the relative path `include/module.modulemap`; no-asserts builds silently inject a bogus mapping.
>
> Suggested fix: treat empty values as unset, and have Swift skip the VC injection for non-absolute paths. CI evidence: https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/45053113177 (probe job).

**2. swiftly: forum reply on "Pitch: Bringing swiftly to Windows"**

> One gap: the pitch doesn't cover the MSVC/Windows SDK prerequisite, which today means installing Visual Studio or Build Tools (several GB, admin). We've shown a per-user, VS-free path that works for Foundation, SwiftPM (build/run/test), C and C++ interop on x64 and arm64:
> - Fetch only the MSVC CRT headers and libs from the VS channel manifest (3 packages, ~77 MB) and the Windows SDK from NuGet `Microsoft.Windows.SDK.CPP[.<arch>]` (~204 MB), on the user's machine, after explicit acceptance of Microsoft's license terms. Nothing is redistributed.
> - Lay them out as a `/winsysroot` tree shared by all toolchains (`~/.swiftly/msvc-sysroot-<arch>`).
> - Copy the toolchain's ucrt/winsdk/vcruntime modulemaps in.
> - Write `<toolchain>\usr\bin\clang.cfg` with `-fuse-ld=lld` and `-Xmicrosoft-windows-sys-root "<escaped backslashes>"`. Then only PATH and SDKROOT are needed.
>
> In swiftly this fits the existing Platform hooks:
> - `verifySystemPrerequisitesForInstall`: detect VS via vswhere, else offer the sysroot with a license prompt (`--accept-msvc-license` for CI).
> - `install`: after extracting the MSIs, fetch once and link the toolchain.
> - `updateEnvironmentWithToolchain`: set SDKROOT and the `Runtimes\<v>\usr\bin` PATH entry per invocation.
>
> Gotchas:
> - `cli.msi` needs the FoundationXML/swiftRegexBuilder SxS assemblies from `ide.msi` (error 14001).
> - Deep paths hit MAX_PATH (1603).
>
> Prototype: https://github.com/tothambrus11/swift-windows-portable-toolchain/tree/exp/managers (`managers/bootstrap/install.ps1`, ~150 lines). Happy to send a PR once `install` lands (#619).

**3. version-fox/vfox-plugins: registry entry**

> `sources/swift.json`: `{"name":"swift","manifestUrl":"https://github.com/<owner>/vfox-swift/releases/latest/download/manifest.json","test":{"version":"6.4.3","check":"swift --version","resultRegx":"Swift version 6\\.4\\.3"}}`. Swift toolchains from swift.org for Windows (VS-free, per-user, license-gated MSVC/SDK fetch), Linux and macOS.

**4. version-fox/vfox: two Windows bugs (v1.1.0)**

- **`vfox exec <sdk> -- swift` reports "executable file not found in %PATH%"** although `swift.exe` is on the SDK's PATH. `lookPathInEnv` (cmd/commands/exec.go) doesn't try PATHEXT, then falls back to `exec.LookPath` on the parent's PATH. Fix: try `PATHEXT` extensions per directory, or call `exec.LookPath` with the child's PATH set.
- **`os.execute` / `io.popen` pass the line to `cmd /c` without `/s` wrapping,** so commands that start with a quoted path and contain more quotes break. mise uses `cmd /s /c "…"`; vfox should do the same.

**5. ScoopInstaller/Main: note on `swift.json` (after the bucket exists)**

> The manifest notes that Visual Studio and the Windows SDK must be installed. A VS-free alternative exists in the `swift-portable` bucket: a `msvc-sysroot` app fetches the MSVC CRT and Windows SDK from Microsoft after license acceptance, and Swift links with lld. Would you accept a `notes` line or a `suggest` entry pointing to it?

## Caveats

- The prebuilt archive still lacks the full third-party notice set.
- Not tested:
  - Scoop's interactive `Read-Host` prompt; CI uses the env-var path.
  - A real `scoop update msvc-sysroot` re-linking installed toolchains.
  - arm64 with VS present.
- WinGet, Chocolatey, conda, proto and swiftly status is from desk research, not prototypes.
