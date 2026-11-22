-- vfox tool plugin: official swift.org toolchains, including a portable, Visual-Studio-free setup on
-- Windows. Runs in standalone vfox and in mise (vfox backend); lib/compat.lua bridges the differences.
--
--   vfox add --source <swift-vfox-plugin.zip or URL> swift
--   $env:SWIFT_PORTABLE_ACCEPT_MSVC_LICENSE = 1     # only without Visual Studio, see below
--   vfox install swift@6.4.3 ; vfox use -p swift@6.4.3
--
-- Windows: the official installer bundle (or, with SWIFT_PORTABLE_SOURCE=prebuilt, a repackaged
-- Swift-only archive) is unpacked without running it: no admin rights, no registry. The Microsoft C/C++
-- runtime and Windows SDK are downloaded from Microsoft, once per user into a shared sysroot
-- (%LOCALAPPDATA%\swift-portable\msvc-sysroot-<arch>), only after the license terms are accepted
-- (SWIFT_PORTABLE_ACCEPT_MSVC_LICENSE=1; mise: tool option accept_msvc_license = true), unless an
-- installed Visual Studio is found.
--
-- scripts/setup-portable-swift.ps1 is copied from managers/common by managers/vfox/pack.ps1.
PLUGIN = {
    name = "swift",
    version = "0.2.0",
    description = "Swift toolchains from swift.org; portable (no Visual Studio) on Windows",
    homepage = "https://github.com/tothambrus11/swift-windows-portable-toolchain",
    license = "Apache-2.0",
    legacyFilenames = { ".swift-version" },
}
