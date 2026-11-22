local swiftorg = require("swiftorg")

-- Linux: mise downloads and unpacks the official tarball itself.
-- macOS and Windows: the official artifacts are installer packages (.pkg / WiX Burn .exe) that
-- mise cannot unpack, so PostInstall downloads and unpacks them instead.
-- Windows with source = "prebuilt": a repackaged Swift-only archive (no Microsoft files) from this
-- repository's GitHub releases, downloaded and checksum-verified by mise itself.
function PLUGIN:PreInstall(ctx)
    local version = ctx.version
    if RUNTIME.osType == "windows" and swiftorg.source(ctx.options) == "prebuilt" then
        local url, sha256 = swiftorg.prebuilt_asset(version, ctx.options)
        return { version = version, url = url, sha256 = sha256 }
    end
    if RUNTIME.osType == "linux" then
        return {
            version = version,
            url = swiftorg.linux_url(version, swiftorg.linux_platform(ctx.options)),
        }
    end
    return { version = version }
end
