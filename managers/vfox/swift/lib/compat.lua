-- The plugin runs both in standalone vfox and in mise's vfox runtime. mise adds the `file` and `cmd`
-- modules and tool options (ctx.options); standalone vfox has neither, but its Lua VM keeps the standard
-- `io`/`os` libraries (os.execute / io.popen go through cmd.exe on Windows).
local M = {}

local ok_file, mise_file = pcall(require, "file")
M.is_mise = ok_file

local sep = package.config:sub(1, 1)

function M.exec(command)
    local ok, cmd = pcall(require, "cmd")
    if ok then
        return cmd.exec(command)
    end
    local h = assert(io.popen(command))
    local out = h:read("*a")
    h:close()
    return out
end

local function q(s)
    return '"' .. tostring(s) .. '"'
end

M.file = ok_file and mise_file or {
    join_path = function(...)
        return table.concat({ ... }, sep)
    end,
    exists = function(p)
        local f = io.open(p, "rb")
        if f then
            f:close()
            return true
        end
        if sep == "\\" then
            -- directories cannot be opened as files
            return (M.exec("if exist " .. q(p) .. " echo yes") or ""):match("yes") ~= nil
        end
        return os.execute("test -e " .. q(p)) == 0
    end,
    read = function(p)
        local f = assert(io.open(p, "rb"))
        local s = f:read("*a")
        f:close()
        return s
    end,
}

-- Install directory and version of the tool being installed, for both runtimes:
-- mise: ctx.rootPath + ctx.runtimeVersion; vfox: ctx.sdkInfo[<name>].path / .version
function M.main_sdk(ctx)
    local info = ctx.sdkInfo or {}
    local main = info[PLUGIN.name]
    if main == nil then
        for _, v in pairs(info) do
            main = v
            break
        end
    end
    local path = (main and main.path) or ctx.rootPath
    local version = ctx.runtimeVersion or (main and main.version)
    return path, version
end

return M
