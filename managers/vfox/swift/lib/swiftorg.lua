-- Helpers shared by the hooks.
local compat = require("compat")
local file = compat.file

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
    local ok, out = pcall(compat.exec, '"' .. vswhere .. '" -latest -products * -requires ' .. component
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

-- Windows: "official" (default) unpacks swift.org's installer bundle; "prebuilt" downloads a
-- repackaged Swift-only archive from a GitHub release.
function M.source(options)
    local s = (options or {}).source or os.getenv("SWIFT_PORTABLE_SOURCE") or "official"
    if s ~= "official" and s ~= "prebuilt" then
        error('swift: tool option source must be "official" or "prebuilt", got "' .. tostring(s) .. '"')
    end
    return s
end

M.prebuilt_repo = "tothambrus11/swift-windows-portable-toolchain"

-- URL + sha256 of the prebuilt archive, from the GitHub release API (asset "digest").
function M.prebuilt_asset(version, options)
    local http = require("http")
    local json = require("json")
    options = options or {}
    local repo = options.prebuilt_repo or M.prebuilt_repo
    local tag = options.prebuilt_tag or ("swift-" .. version .. "-portable.0")
    local name = "swift-" .. version .. "-windows-" .. M.win_arch() .. "-portable.tar.xz"
    local api = "https://api.github.com/repos/" .. repo .. "/releases/tags/" .. tag
    local resp = http.get({ url = api, headers = M.github_headers() })
    if resp.status_code ~= 200 then
        error("swift: no prebuilt release " .. tag .. " in " .. repo .. " (HTTP " .. resp.status_code
            .. "); use source = \"official\"")
    end
    for _, a in ipairs(json.decode(resp.body).assets or {}) do
        if a.name == name then
            local sha = type(a.digest) == "string" and a.digest:match("^sha256:(%x+)$") or nil
            if sha == nil then
                local s = http.get({ url = a.browser_download_url .. ".sha256" })
                sha = s.status_code == 200 and s.body:match("^(%x+)") or nil
            end
            if sha == nil then
                error("swift: no sha256 for " .. name)
            end
            return a.browser_download_url, sha
        end
    end
    error("swift: release " .. tag .. " has no asset " .. name)
end

-- mise adds a GitHub token to api.github.com requests itself; standalone vfox does not
function M.github_headers()
    local token = os.getenv("GITHUB_TOKEN")
    if token and token ~= "" and not compat.is_mise then
        return { Authorization = "Bearer " .. token }
    end
    return nil
end

-- One MSVC CRT + Windows SDK sysroot per user and architecture, shared by every installed Swift version
-- (and by mise and vfox installs alike). Created by `setup-portable-swift.ps1 -Part fetch-sysroot`.
function M.shared_sysroot()
    local s = os.getenv("SWIFT_PORTABLE_SYSROOT")
    if s and s ~= "" then
        return s
    end
    local base = os.getenv("LOCALAPPDATA") or os.getenv("USERPROFILE")
    return base .. "\\swift-portable\\msvc-sysroot-" .. M.win_arch()
end

function M.print_license_notice()
    local how = compat.is_mise
        and "set the tool option  accept_msvc_license = true  in mise.toml, or the environment variable"
        or "set the environment variable"
    local lines = {
        "",
        "swift: no Visual Studio was found, so Swift needs the Microsoft C/C++ runtime + Windows SDK to link.",
        "swift: They are downloaded from Microsoft onto this machine only after you accept their licenses:",
        "swift:   - MSVC C/C++ runtime: Visual Studio Build Tools license, https://go.microsoft.com/fwlink/?LinkId=2179911",
        "swift:   - Windows SDK: https://aka.ms/WinSDKLicenseURL",
        "swift: To accept them, " .. how .. " SWIFT_PORTABLE_ACCEPT_MSVC_LICENSE=1,",
        "swift: then install again. (SWIFT_PORTABLE_MSVC=system installs Swift without them.)",
        "",
    }
    for _, l in ipairs(lines) do
        print(l)
    end
end

-- Shell-quote for cmd.exe (Windows) / sh
function M.q(s)
    if RUNTIME.osType == "windows" then
        return '"' .. tostring(s) .. '"'
    end
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

return M
