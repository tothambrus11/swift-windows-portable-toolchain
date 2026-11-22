local compat = require("compat")
local swiftorg = require("swiftorg")

-- Linux: the tool manager downloads and unpacks the official tarball itself.
-- macOS and Windows: the official artifacts are installer packages (.pkg / WiX Burn .exe), so PostInstall
-- downloads and unpacks them. Windows + source=prebuilt under mise: mise downloads, verifies and unpacks
-- the repackaged Swift-only archive (standalone vfox's extractor drops hard links: PostInstall does it there).
function PLUGIN:PreInstall(ctx)
    local version = ctx.version
    if RUNTIME.osType == "windows" then
        if not compat.is_mise then
            -- Standalone vfox has no tool options and no way to complete an install later, so the license
            -- gate is checked before anything is downloaded.
            local want, allowed = swiftorg.sysroot_plan(ctx.options)
            if want and not allowed then
                swiftorg.print_license_notice()
                error("swift: the Microsoft license terms were not accepted; nothing was downloaded")
            end
        elseif swiftorg.source(ctx.options) == "prebuilt" then
            local url, sha256 = swiftorg.prebuilt_asset(version, ctx.options)
            return { version = version, url = url, sha256 = sha256 }
        end
    end
    if RUNTIME.osType == "linux" then
        return {
            version = version,
            url = swiftorg.linux_url(version, swiftorg.linux_platform(ctx.options)),
        }
    end
    return { version = version }
end
