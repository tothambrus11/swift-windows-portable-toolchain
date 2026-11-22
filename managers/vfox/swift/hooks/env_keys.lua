local file = require("compat").file
local swiftorg = require("swiftorg")

function PLUGIN:EnvKeys(ctx)
    -- standalone vfox: ctx.path is the version directory (or its sdks\ link), ctx.main.path the install itself
    local root = (not require("compat").is_mise and ctx.main and ctx.main.path) or ctx.path
    if RUNTIME.osType == "darwin" then
        return { { key = "PATH", value = file.join_path(root, "toolchain", "usr", "bin") } }
    elseif RUNTIME.osType ~= "windows" then
        return { { key = "PATH", value = file.join_path(root, "usr", "bin") } }
    end
    if not require("compat").is_mise then
        -- Standalone vfox asks for the variables of a *link* to the install (sdks\swift), which need not exist
        -- yet, so they are computed from the path alone: PostInstall ran the setup with -StableNames. Only PATH
        -- and SDKROOT are needed; clang.cfg points clang (and so swiftc/SwiftPM) at the MSVC/WinSDK sysroot.
        local swift = file.join_path(root, "Swift")
        return {
            { key = "PATH", value = file.join_path(swift, "Toolchains", "current", "usr", "bin") },
            { key = "PATH", value = file.join_path(swift, "Runtimes", "current", "usr", "bin") },
            { key = "SDKROOT", value = file.join_path(swift, "Platforms", "current", "Windows.platform", "Developer", "SDKs", "Windows.sdk") .. "\\" },
        }
    end
    -- Windows: setup-portable-swift.ps1 records the PATH entries (toolchain usr\bin and
    -- Runtimes\<ver>\usr\bin) and variables (SDKROOT; with the portable sysroot also INCLUDE, LIB,
    -- VCToolsInstallDir, UCRTVersion, ...) in mise-env.json.
    local data, path = swiftorg.read_env_json(root)
    local ok, cache = pcall(require, "mise.cache")
    if ok then
        cache.watch_files({ path })
    end
    if data == nil then
        error("swift: " .. path .. " is missing; reinstall with `mise install --force`")
    end
    local keys = {}
    for _, p in ipairs(data.path or {}) do
        table.insert(keys, { key = "PATH", value = p })
    end
    for k, v in pairs(data.env or {}) do
        table.insert(keys, { key = k, value = v })
    end
    return keys
end
