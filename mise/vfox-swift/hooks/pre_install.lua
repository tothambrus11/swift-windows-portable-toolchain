local swiftorg = require("swiftorg")

-- Linux: mise downloads and unpacks the official tarball itself.
-- macOS and Windows: the official artifacts are installer packages (.pkg / WiX Burn .exe) that
-- mise cannot unpack, so PostInstall downloads and unpacks them instead.
function PLUGIN:PreInstall(ctx)
    local version = ctx.version
    if RUNTIME.osType == "linux" then
        return {
            version = version,
            url = swiftorg.linux_url(version, swiftorg.linux_platform(ctx.options)),
        }
    end
    return { version = version }
end
