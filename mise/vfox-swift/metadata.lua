-- vfox / mise tool plugin: official swift.org toolchains, including a portable,
-- Visual-Studio-free setup on Windows.
--
--   mise plugins link swift-portable ./mise/vfox-swift          (from a checkout)
--   mise use swift-portable@6.4.3
--
-- Windows: the official installer bundle is unpacked without running it (no admin rights,
-- no registry). The Microsoft C/C++ runtime and Windows SDK, which Swift needs to link, are
-- downloaded from Microsoft only after you accept their licenses
-- (tool option accept_msvc_license = true, or SWIFT_PORTABLE_ACCEPT_MSVC_LICENSE=1), unless an
-- installed Visual Studio is found. See mise/REPORT.md.
PLUGIN = {
    name = "swift",
    version = "0.1.0",
    description = "Swift toolchains from swift.org; portable (no Visual Studio) on Windows",
    homepage = "https://github.com/tothambrus11/swift-windows-portable-toolchain",
    license = "Apache-2.0",
    legacyFilenames = { ".swift-version" },
}
