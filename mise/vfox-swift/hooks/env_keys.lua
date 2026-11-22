local file = require("file")
local swiftorg = require("swiftorg")

function PLUGIN:EnvKeys(ctx)
    local root = ctx.path
    if RUNTIME.osType == "darwin" then
        return { { key = "PATH", value = file.join_path(root, "toolchain", "usr", "bin") } }
    elseif RUNTIME.osType ~= "windows" then
        return { { key = "PATH", value = file.join_path(root, "usr", "bin") } }
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
