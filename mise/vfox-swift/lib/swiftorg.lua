-- Helpers shared by the hooks.
local file = require("file")

local M = {}

M.releases_url = "https://www.swift.org/api/v1/install/releases.json"

-- Top-level booleans in tool options arrive as strings.
function M.truthy(v)
    if v == nil then
        return false
    end
    v = string.lower(tostring(v))
    return v == "true" or v == "1" or v == "yes"
end

function M.win_arch()
    return RUNTIME.archType == "arm64" and "arm64" or "x64"
end

-- The user's explicit acceptance of the Microsoft license terms (VS Build Tools license for the
-- C/C++ runtime, Windows SDK license). Nothing from Microsoft is downloaded without it.
function M.msvc_license_accepted(options)
    return M.truthy((options or {}).accept_msvc_license) or M.truthy(os.getenv("SWIFT_PORTABLE_ACCEPT_MSVC_LICENSE"))
end

-- msvc = "auto" (default): use an installed Visual Studio when there is one, otherwise the portable
--                           sysroot if the license was accepted
--        "portable"       : always the portable sysroot (requires the acceptance)
--        "system"         : never download anything from Microsoft
function M.msvc_mode(options)
    local m = (options or {}).msvc or os.getenv("SWIFT_PORTABLE_MSVC") or "auto"
    if m ~= "auto" and m ~= "portable" and m ~= "system" then
        error('swift: tool option msvc must be "auto", "portable" or "system", got "' .. tostring(m) .. '"')
    end
    return m
end

-- Visual Studio / Build Tools with the MSVC tools for this architecture, found via vswhere.
function M.find_visual_studio()
    local pf86 = os.getenv("ProgramFiles(x86)") or "C:\\Program Files (x86)"
    local vswhere = pf86 .. "\\Microsoft Visual Studio\\Installer\\vswhere.exe"
    if not file.exists(vswhere) then
        return nil
    end
    local component = RUNTIME.archType == "arm64" and "Microsoft.VisualStudio.Component.VC.Tools.ARM64"
        or "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
    local cmd = require("cmd")
    local ok, out = pcall(cmd.exec, '"' .. vswhere .. '" -latest -products * -requires ' .. component
        .. " -property installationPath")
    if not ok or out == nil then
        return nil
    end
    out = out:gsub("%s+$", "")
    if out == "" then
        return nil
    end
    return out
end

-- Does this install need the portable MSVC/WinSDK sysroot, and may we fetch it?
-- Returns want (bool), allowed (bool), reason (string)
function M.sysroot_plan(options)
    local mode = M.msvc_mode(options)
    if mode == "system" then
        return false, false, "msvc = system"
    end
    local accepted = M.msvc_license_accepted(options)
    if mode == "auto" then
        local vs = M.find_visual_studio()
        if vs then
            return false, false, "using the installed Visual Studio at " .. vs
        end
    end
    return true, accepted, accepted and "license accepted" or "license not accepted"
end

function M.read_env_json(root)
    local json = require("json")
    local path = file.join_path(root, "mise-env.json")
    if not file.exists(path) then
        return nil, path
    end
    return json.decode(file.read(path)), path
end

-- Linux: swift.org publishes one build per distro family/release. Map /etc/os-release to the
-- artifact name (ubuntu24.04, debian12, fedora41, amazonlinux2023, ubi9). Option swift_platform overrides.
function M.linux_platform(options)
    local pinned = (options or {}).swift_platform or os.getenv("SWIFT_PLATFORM")
    if pinned and pinned ~= "" then
        return pinned
    end
    local ok, text = pcall(file.read, "/etc/os-release")
    if not ok or not text then
        return "ubuntu24.04"
    end
    local id = text:match('\nID="?([%w%-%.]+)"?') or text:match('^ID="?([%w%-%.]+)"?') or ""
    local ver = text:match('VERSION_ID="?([%d%.]+)"?') or ""
    local like = text:match('ID_LIKE="?([^"\n]+)"?') or ""
    if id == "ubuntu" then
        return "ubuntu" .. ver
    elseif id == "debian" then
        return "debian" .. (ver:match("^%d+") or "12")
    elseif id == "fedora" then
        return "fedora" .. ver
    elseif id == "amzn" then
        return "amazonlinux" .. ver
    elseif id == "rhel" or id == "rocky" or id == "almalinux" or like:find("rhel") then
        return "ubi" .. (ver:match("^%d+") or "9")
    elseif like:find("ubuntu") then
        return "ubuntu24.04"
    elseif like:find("debian") then
        return "debian12"
    end
    return "ubi9"
end

function M.linux_url(version, platform)
    local arch = RUNTIME.archType == "arm64" and "-aarch64" or ""
    local dir = platform:gsub("%.", "") .. arch
    return "https://download.swift.org/swift-" .. version .. "-release/" .. dir .. "/swift-" .. version
        .. "-RELEASE/swift-" .. version .. "-RELEASE-" .. platform .. arch .. ".tar.gz"
end

function M.macos_url(version)
    return "https://download.swift.org/swift-" .. version .. "-release/xcode/swift-" .. version
        .. "-RELEASE/swift-" .. version .. "-RELEASE-osx.pkg"
end

-- Shell-quote for cmd.exe (Windows) / sh
function M.q(s)
    if RUNTIME.osType == "windows" then
        return '"' .. tostring(s) .. '"'
    end
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

return M
