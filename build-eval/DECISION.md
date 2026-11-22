# Decision: build Swift for Windows from source, or repackage the official installer?

**Recommendation: don't build from source.** Keep the official swift.org binaries and change *how* they are delivered:

1. **Now:** make the setup script fetch only the containers it needs with HTTP range requests, and switch it to the NoAsserts toolchain.
2. **Next:** add a CI job that repackages each official release once into a deduplicated archive and publishes it as a GitHub release. The MSVC CRT and Windows SDK stay out of the archive and are still fetched on the user's machine.
3. **In parallel:** take the findings upstream, asking for loose MSIs/zip on download.swift.org, `UniversalCRTSdkDir`/`WindowsSdkDir` support in clang's `MSVCPaths`, an lld default, and the VFS assertion fix. This fits the swiftly-on-Windows pitch.

Building from source costs roughly 100x more CI time, cannot run on free runners within the 6 h job limit, and needs re-validation every release. Almost every benefit it offers can be had without it.

## Evidence

Runs on this branch:
- Bundle inspection: https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44962741696
- Range-fetch, minimal layout, dedup and archive sizes: https://github.com/tothambrus11/swift-windows-portable-toolchain/actions/runs/44964550039 (results in `minimal.json` artifacts; still running when this memo was written)

### What is in the official 6.4.3 bundle

The x64 bundle is 2003 MB; the arm64 bundle is 1551 MB. Each is one Burn exe with 3 attached CAB containers.

| container | x64 | arm64 | contents |
|---|---|---|---|
| AssertsToolchain | 802 MB | 703 MB | bld/cli/dbg/ide `.asserts` |
| NoAssertsToolchain | 653 MB | 563 MB | the same four, `.noasserts` |
| Shared | 546 MB | 284 MB | rtl, res, python, windows.msi with per-arch `sdk.windows.{x64,arm64,x86}.cab`, and (x64 only) android.msi |

Extracted sizes in MB, from `msiexec /a` on a runner (x64 / arm64):

| MSI | Asserts | NoAsserts |
|---|---|---|
| bld (compiler, clang, lld) | 2042 / 1871 | 1787 / 1409 |
| cli (driver, SwiftPM, swift-build, libclang) | 553 / 525 | 447 / 408 |
| dbg (lldb) | 620 / 587 | 497 / 447 |
| ide (sourcekit-lsp) | 224 / 213 | 176 / 159 |

The other MSIs: windows.msi 851 (all three SDK arches, 102 MB of `.msm` merge modules, `swift_static` libraries), rtl 119, android 1159 (x64 only), python 16.

Findings:
- **There are no PDBs.** Debug info is not where the size goes; stripping would gain nothing.
- **The size is duplicated executables.** MSI cannot express links, so these are full copies:
  - `swift-frontend.exe` (123 MB on x64) ships as frontend, symbolgraph-extract, autolink-extract and api-digester, plus synthesize-interface in dbg.
  - `clang.exe` (91 MB) ships 4x.
  - `lld.exe` (56 MB) ships 5x.
  - `swift.exe`/`swiftc.exe` (54 MB) ship 2x.
  - Together that is roughly 0.8 to 0.9 GB of duplicates in the NoAsserts toolchain alone.
- **Asserts vs NoAsserts:** NoAsserts is about 13% smaller (x64) to 25% smaller (arm64). The prototype currently uses Asserts, and the VFS crash it hits is an assertion.
- **No loose files on download.swift.org.** Burn `DownloadUrl` is the template `/{2}`, every payload is `embedded`, and `bld.noasserts.msi` and friends return 404 there.
- **download.swift.org supports `Range` (206).** So we can read the PE header, the `.wixburn` header and the 200 KB UX manifest, then fetch only the NoAsserts and Shared containers. That avoids about 800 MB (x64) or 700 MB (arm64) of the bundle. Run 44964550039 implements and measures this.
- **The Browser Company's installers are web installers.** Each 1.3 MB `installer-amd64.exe` lists external payloads at `https://swift-toolchain.thebrowserco.com/<tag>/amd64/<run>/{bld.noasserts.cab,...}`. Each MSI/CAB can be downloaded on its own (HTTP 200, range supported). A minimal x64 set from there is about 690 MB of downloads:
  - bld.noasserts 342
  - cli.noasserts 141
  - rtl 37
  - windows.cab 84
  - sdk.windows.x64 82
  - res

  These are nightly snapshots of `release/6.4` (`swift-6.4.0-YYYYMMDD.3`), not the swift.org 6.4.3 release, and the host is a third-party CDN with no stability promise.

### Candidate portable layouts, measured

Measured layouts (x64 / arm64):

| layout | on disk | zip | 7z -mx9 |
|---|---|---|---|
| A: what the prototype extracts today (Asserts, all SDK arches) | 4427 / 4182 MB | 1639 / 1524 MB | |
| B: NoAsserts, everything | 3895 / 3410 MB | 1409 / 1282 MB | |
| C: B with host-arch SDK only | 3411 / 2923 MB | 1277 / 1150 MB | |
| D: compiler + SwiftPM + runtime + host SDK (no lldb, sourcekit-lsp or python) | 2723 / 2301 MB | 1015 / 902 MB | **424 / 375 MB** |

Expected minimal layout after dedup:
- D drops about 0.8 to 0.9 GB with hardlinks, and another 102 MB by dropping `Redistributables\*.msm`. That leaves roughly 1.8 GB (x64) or 1.4 GB (arm64) on disk.
- A tar or 7z archive that keeps the links should land around 400 to 600 MB, against today's 2.0 GB download and 4.4 GB extraction.
- Exact numbers are in run 44964550039, which also checks that the built-in `tar.exe` restores the hardlinks.

## Cost of building from source

- **What `utils/build.ps1` does:**
  - Builds a bootstrap/stage1 compiler (LLVM, clang, lld, Swift) with the host MSVC.
  - Rebuilds the full stage2 toolchain with stage1, for Asserts and optionally NoAsserts.
  - Builds the runtime and SDK per target arch and link mode (Windows X64, X86 and Arm64, dynamic and static; Android optional).
  - Builds Foundation, XCTest, swift-testing, the driver, SwiftPM, swift-build, sourcekit-lsp, lldb, DocC and swift-format.
  - Packages it all with WiX.

  It needs VS 2022 with the MSVC (and ARM64) tools, ATL, a pinned Windows SDK, CMake, Ninja, Python and a pinned bootstrap Swift. A VS install on the build machine is fine for us, but it is a large, version-pinned setup.
- **Measured on The Browser Company's pipeline** (`thebrowsercompany/swift-build`, Release 6.4 run 44944673837):
  - 88 jobs, 3 h 24 min wall clock, **916 job-minutes**.
  - Runners are cirun / GitHub *larger* runners: **64-core** for compilers, 16/8-core for the rest.
  - The amd64 Asserts stage2 compiler job took **53 min on 64 cores**, 31 min of it compiling: 7361 ninja steps with a **1.04 % sccache hit rate**, so effectively cold.
  - Stage1 took 32 min. Each SDK slice took 34 to 39 min.
- **On free `windows-latest`** (4 vCPU, 16 GB RAM):
  - Scaling the compile step 16x puts a single stage2 compiler at about 6 to 8 h. That **does not fit the 6 h job limit**, and the build needs two compiler stages per host arch.
  - The pipeline would have to be cut into many artifact-handoff jobs, like TBC's, and some would still be at the limit.
  - **sccache does not help a release build.** Each tag is effectively cold, and the 10 GB Actions cache per repo is smaller than one toolchain's object cache.
  - Disk is not the constraint: D: had 220 GB free, C: 27 GB.
- **On paid larger runners:** about 900 job-minutes per release, mostly on 16 to 64-core Windows machines. That is likely $100 to $300 per release for two arches. TBC's own scheduled snapshot runs fail frequently (most of the last 15 scheduled runs concluded `failure`), which shows the maintenance load.
- **Arm64:** "cross compiling from x64 works", and native arm64 builds needed extra PRs in 6.2 (unofficial build guide, forums thread 81751). arm64 runners double the matrix.
- **Maintenance per release:**
  - Re-pin VS, the Windows SDK and the bootstrap toolchain.
  - Rebase any patches on about 30 repos (`update-checkout`).
  - Re-run the test matrix.
  - Sign or explain an unsigned toolchain, and own every miscompile question ("is it your build or Swift?").

  compnerd on this: "the costs are absurd" (forums thread 63521).

## What building from source would buy, and the cheaper way to get each

| benefit | from source | without building |
|---|---|---|
| Baked-in sysroot (`-fuse-ld=lld`, `-Xmicrosoft-windows-sys-root`) | patch the clang/driver defaults | already done with `clang.cfg` next to clang.exe, which is stable and needs no patch |
| Env-var SDK discovery (UCRT/WinSDK for the frontend VFS) | patch LLVM `MSVCPaths.cpp` | the modulemap copy works today; upstream the patch |
| No Asserts build | `-IncludeNoAsserts` | official NoAsserts MSIs are in the bundle; just pick them |
| Strip debug info | n/a | there are no PDBs to strip |
| Smaller size | links instead of copies | dedup with hardlinks at repackage time gives the same result |
| Native zip | `build.ps1` builds image dirs | the repackage CI job produces the zip |
| VFS assertion fix | patch LLVM | NoAsserts sidesteps the assert; the real fix belongs upstream |
| No MSI admin-extract fragility | yes | a prebuilt archive removes it for users; CI absorbs it once per release |

The one thing only a source build gives is shipping fixes before upstream releases them. That is not worth the cost above.

## Options compared

| | A. repackage at install (today) | B. prebuilt repackaged archive (GitHub release) | C. own from-source build | D. upstream (swift.org zip/MSIs, swiftly) |
|---|---|---|---|---|
| User download | 2.0 / 1.55 GB, or about 1.2 / 0.85 GB with range fetch | about 0.4 to 0.6 GB (dedup, est.) + 0.5 GB CRT/SDK | similar to B | depends on swift.org |
| User disk | 4.4 GB, or about 2 GB with NoAsserts + dedup | about 1.5 to 1.9 GB + 0.65 to 0.97 GB sysroot | similar | |
| Setup time | about 3 min | under 1 min unpack + CRT/SDK fetch | similar | |
| Provenance | official binaries, fetched directly | official binaries, repackaged (checksums of source MSIs published) | ours | official |
| CI cost per release | 0 | about 20 min on free runners | 900+ larger-runner minutes, $100s | 0 for us |
| Maintenance | Burn/MSI format drift | same, but caught in CI, not on user machines | very high | lobbying, slow |
| Legal | none redistributed | Swift Apache-2.0 is fine; rtl ships `vcruntime140`/`msvcp140`/`concrt140`/`vccorlib140` (VS "Distributable Code", allowed alongside an app with conditions: no MS trademarks, keep license terms); **no MSVC/SDK headers or libs in the archive** | same as B | n/a |
| Effort | done (+1 day for range fetch/NoAsserts) | 2 to 3 days | weeks, then ongoing | forum post + PRs, months |

Option (b) of the brief, The Browser Company artifacts: their web installer payloads are individually addressable and smaller, but they are nightly snapshots on a third-party host. Keep that host only as an optional `-Source tbc` path for snapshots.

Option (d) of the brief, a bootstrapper: the swiftly-on-Windows pitch (forums 90287) plans to extract the MSIs from the exe and *install* them with `MsiInstallProductW`. It says outright: "If swift.org published the MSIs separately, Swiftly could download the files it needs." It does not address VS. Our range-fetch carve plus the CRT/SDK fetch is exactly the missing piece. Offer it there rather than shipping a competing Go/Swift exe; for now a PowerShell bootstrapper is enough.

## Next steps

1. **Setup script (about 1 day).**
   - Range-fetch the containers as in `build-eval/minimal-zip.ps1`.
   - Default to NoAsserts, with `-Asserts` as an opt-in.
   - Trim non-host SDK arches and `Redistributables`; dedup with hardlinks.
   - Coordinate with the agent already simplifying the script; this is a drop-in replacement for `Expand-BurnBundle`.
2. **Release workflow (2 to 3 days).**
   - On each swift.org release (poll `releases.json`), for x64 and arm64: carve, admin-extract the minimal set, dedup, and pack `swift-<ver>-windows-<arch>-portable.{zip,tar.gz|7z}`.
   - Run the existing VS-hidden test matrix against the unpacked archive.
   - Publish a GitHub release with SHA256 sums of the archive *and* of the source bundle, plus NOTICE/LICENSE (Apache-2.0, VS redist notice).
   - The installer script then prefers the archive and falls back to carving.
3. **Upstream (ongoing).**
   - Post on the swiftly pitch and in the Windows forum category with the measurements: loose MSIs or a zip on download.swift.org, and links instead of duplicated exes in the MSIs.
   - File the LLVM `MSVCPaths` env-var issue/PR, the swift-driver lld-default issue, and the VFS assertion bug.
   - File the xwin `corecrt_math.h` issue.
4. **Revisit a source build only if** a needed fix is unreleased for more than one release cycle *and* a sponsor pays for larger runners.
