local swiftorg = require("swiftorg")

-- Lets `mise install` finish an install once the Microsoft license terms have been accepted
-- (or the msvc option changed) without downloading Swift again: mise then re-runs PostInstall.
function PLUGIN:MiseInstallSatisfied(ctx)
    if RUNTIME.osType ~= "windows" then
        return { satisfied = true }
    end
    local data = swiftorg.read_env_json(ctx.path)
    if data == nil then
        return { satisfied = false, reason = "mise-env.json missing" }
    end
    local want, allowed = swiftorg.sysroot_plan(ctx.options)
    if want and allowed and data.sysroot ~= true then
        return { satisfied = false, reason = "portable MSVC/WinSDK sysroot not set up yet" }
    end
    return { satisfied = true }
end
