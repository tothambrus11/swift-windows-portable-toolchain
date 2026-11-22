local file = require("file")
local swiftorg = require("swiftorg")
local q = swiftorg.q

local function run(command)
    print("swift: " .. command)
    local code = os.execute(command)
    if code ~= 0 and code ~= true then
        error("swift: command failed (exit " .. tostring(code) .. "): " .. command)
    end
end

local function powershell()
    local override = os.getenv("SWIFT_PORTABLE_POWERSHELL")
    if override and override ~= "" then
        return override
    end
    local cmd = require("cmd")
    local ok, out = pcall(cmd.exec, "where pwsh.exe")
    if ok and out and out:match("pwsh") then
        return "pwsh.exe"
    end
    return "powershell.exe"
end

local function print_license_notice(root)
    local lines = {
        "",
        "swift: Swift is installed, but it cannot link programs yet: no Visual Studio was found, and the",
        "swift: Microsoft C/C++ runtime + Windows SDK (needed to link on Windows) were NOT downloaded",
        "swift: because their license terms were not accepted. They come from Microsoft only, under:",
        "swift:   - MSVC C/C++ runtime: Visual Studio Build Tools license, https://go.microsoft.com/fwlink/?LinkId=2179911",
        "swift:   - Windows SDK: https://aka.ms/WinSDKLicenseURL",
        "swift: To accept them, set the tool option  accept_msvc_license = true  in mise.toml, or the",
        "swift: environment variable SWIFT_PORTABLE_ACCEPT_MSVC_LICENSE=1, then run `mise install` again.",
        "swift: (install dir: " .. root .. ")",
        "",
    }
    for _, l in ipairs(lines) do
        print(l)
    end
end

local function windows(ctx)
    local root = ctx.rootPath
    local options = ctx.options or {}
    local script = file.join_path(RUNTIME.pluginDirPath, "scripts", "setup-portable-swift.ps1")
    local base = q(powershell()) .. " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " .. q(script)
        .. " -Target " .. q(root) .. " -Arch " .. swiftorg.win_arch()
    local extra = ""
    if swiftorg.truthy(options.no_asserts) then
        extra = extra .. " -NoAsserts"
    end
    if swiftorg.truthy(options.full) then
        extra = extra .. " -Full"
    end

    local envjson = swiftorg.read_env_json(root)
    if envjson == nil then
        run(base .. " -Part swift -SwiftVersion " .. ctx.runtimeVersion .. extra)
        envjson = swiftorg.read_env_json(root)
    else
        print("swift: toolchain already unpacked in " .. root)
    end

    local want, allowed, reason = swiftorg.sysroot_plan(options)
    print("swift: portable MSVC/WinSDK sysroot " .. (want and "needed" or "not needed") .. " (" .. reason .. ")")
    if want and envjson and envjson.sysroot == true then
        print("swift: portable sysroot already set up")
    elseif want and allowed then
        run(base .. " -Part sysroot -AcceptLicense")
    elseif want then
        print_license_notice(root)
        if swiftorg.msvc_mode(options) == "portable" then
            error('swift: msvc = "portable" requires accept_msvc_license = true')
        end
    end
end

local function macos(ctx)
    local root = ctx.rootPath
    local version = ctx.runtimeVersion
    local http = require("http")
    local url = swiftorg.macos_url(version)
    local pkg = file.join_path(root, "swift.pkg")
    print("swift: downloading " .. url)
    http.download_file({ url = url }, pkg)
    local tmp = file.join_path(root, "_pkg")
    run("pkgutil --expand-full " .. q(pkg) .. " " .. q(tmp))
    local payload = file.join_path(tmp, "swift-" .. version .. "-RELEASE-osx-package.pkg", "Payload")
    if not file.exists(payload) then
        local found = file.glob(file.join_path(tmp, "*", "Payload"))
        payload = found[1] or error("swift: no Payload in " .. pkg)
    end
    file.move(payload, file.join_path(root, "toolchain"))
    run("rm -rf " .. q(tmp) .. " " .. q(pkg))
end

function PLUGIN:PostInstall(ctx)
    if RUNTIME.osType == "windows" then
        windows(ctx)
    elseif RUNTIME.osType == "darwin" then
        macos(ctx)
    end
end
