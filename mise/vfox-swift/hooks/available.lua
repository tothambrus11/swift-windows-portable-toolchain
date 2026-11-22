local http = require("http")
local json = require("json")
local swiftorg = require("swiftorg")

-- swift.org's release index lists every release oldest first, with the platforms it was built for.
function PLUGIN:Available(ctx)
    local resp = http.get({ url = swiftorg.releases_url })
    if resp.status_code ~= 200 then
        error("swift: fetching " .. swiftorg.releases_url .. " failed: HTTP " .. resp.status_code)
    end
    local want = ({ windows = "Windows", linux = "Linux" })[RUNTIME.osType]
    local result = {}
    local releases = json.decode(resp.body)
    for i = #releases, 1, -1 do
        local r = releases[i]
        local ok = want == nil -- macOS: every release has an Xcode toolchain package
        for _, p in ipairs(r.platforms or {}) do
            if p.platform == want then
                ok = true
            end
        end
        if ok and type(r.name) == "string" then
            local entry = { version = r.name }
            if type(r.date) == "string" and r.date:match("^%d%d%d%d%-%d%d%-%d%d$") then
                entry.created_at = r.date .. "T00:00:00Z"
            end
            table.insert(result, entry)
        end
    end
    return result
end
