local file = require("file")

-- .swift-version: the first line, e.g. "6.4.3"
function PLUGIN:ParseLegacyFile(ctx)
    local line = file.read(ctx.filepath):match("^%s*([^\r\n]+)")
    return { version = line and line:match("^(.-)%s*$") }
end
