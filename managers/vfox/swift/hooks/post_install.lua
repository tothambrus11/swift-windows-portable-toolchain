local compat = require("compat")
local swiftorg = require("swiftorg")
local file = compat.file
local q = swiftorg.q

local function run(command)
    print("swift: " .. command)
    local code = compat.execute(command)
    if code ~= 0 and code ~= true then
        error("swift: command failed (exit " .. tostring(code) .. "): " .. command)
    end
end

local function powershell()
    local override = os.getenv("SWIFT_PORTABLE_POWERSHELL")
    if override and override ~= "" then
        return override
    end
    local ok, out = pcall(compat.exec, "where pwsh.exe 2>nul")
    if ok and out and out:match("pwsh") then
        return "pwsh.exe"
    end
    return "powershell.exe"
end

local function windows(ctx)
    local root, version = compat.main_sdk(ctx)
    local options = ctx.options or {}
    local script = file.join_path(RUNTIME.pluginDirPath, "scripts", "setup-portable-swift.ps1")
    local base = q(powershell()) .. " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " .. q(script)
        .. " -Target " .. q(root) .. " -Arch " .. swiftorg.win_arch()
    local extra = compat.is_mise and "" or " -StableNames"   -- see env_keys.lua
    -- the no-asserts toolchain build: mise tool option no_asserts, or SWIFT_PORTABLE_NO_ASSERTS=1
    if swiftorg.truthy(options.no_asserts) or swiftorg.truthy(os.getenv("SWIFT_PORTABLE_NO_ASSERTS")) then
        extra = extra .. " -NoAsserts"
    end
    if swiftorg.truthy(options.full) then
        extra = extra .. " -Full"
    end

    local envjson = swiftorg.read_env_json(root)
    if envjson == nil and file.exists(file.join_path(root, "Swift", "Toolchains")) then
        -- unpacked by mise from the prebuilt archive: only record this location's paths
        run(base .. " -Part env")
        envjson = swiftorg.read_env_json(root)
    elseif envjson == nil and swiftorg.source(options) == "prebuilt" then
        -- standalone vfox: its tar extractor drops hard links, so let the in-box bsdtar unpack the archive
        local url, sha256 = swiftorg.prebuilt_asset(version, options)
        run(base .. " -Part swift -SwiftVersion " .. version .. " -PrebuiltUrl " .. q(url) .. " -PrebuiltSha256 " .. sha256 .. extra)
        envjson = swiftorg.read_env_json(root)
    elseif envjson == nil then
        run(base .. " -Part swift -SwiftVersion " .. version .. extra)
        envjson = swiftorg.read_env_json(root)
    else
        print("swift: toolchain already unpacked in " .. root)
    end

    local want, allowed, reason = swiftorg.sysroot_plan(options)
    print("swift: portable MSVC/WinSDK sysroot " .. (want and "needed" or "not needed") .. " (" .. reason .. ")")
    if want and envjson and envjson.sysroot == true then
        print("swift: portable sysroot already set up")
    elseif want and allowed then
        local sysroot = swiftorg.shared_sysroot()
        if file.exists(file.join_path(sysroot, "sysroot.json")) then
            print("swift: reusing the shared MSVC/WinSDK sysroot " .. sysroot)
        else
            run(base .. " -Part fetch-sysroot -SysrootDir " .. q(sysroot) .. " -AcceptLicense")
        end
        run(base .. " -Part link -SysrootDir " .. q(sysroot))
    elseif want then
        swiftorg.print_license_notice()
        if swiftorg.msvc_mode(options) == "portable" then
            error("swift: msvc = portable requires accepting the Microsoft licenses")
        end
    end
end

local function macos(ctx)
    local root, version = compat.main_sdk(ctx)
    local http = require("http")
    local url = swiftorg.macos_url(version)
    local pkg = file.join_path(root, "swift.pkg")
    print("swift: downloading " .. url)
    http.download_file({ url = url }, pkg)
    local tmp = file.join_path(root, "_pkg")
    run("pkgutil --expand-full " .. q(pkg) .. " " .. q(tmp))
    run("mv " .. q(tmp) .. "/swift-" .. version .. "-RELEASE-osx-package.pkg/Payload " .. q(file.join_path(root, "toolchain")))
    run("rm -rf " .. q(tmp) .. " " .. q(pkg))
end

function PLUGIN:PostInstall(ctx)
    if RUNTIME.osType == "windows" then
        windows(ctx)
    elseif RUNTIME.osType == "darwin" then
        macos(ctx)
    end
end
