-- Pattern "https". This file is copied unchanged into every
-- plugin that makes requests to the internet, as <id>/https_main.lua: change the pattern first, then copy it
-- again.
--
-- A request as its own program, used only on macOS, where a forked child cannot use the network. It receives
-- the plugin folder, a file with the request, which it deletes as soon as it is read, and the code file, which
-- gets "0" when the request cannot even start, so the screen is never left waiting.
local plugin_dir, spec_path, code_path = arg[1], arg[2], arg[3]
local ok, err = pcall(function()
    local id = assert(arg[0]:match("([^/]+)/https_main%.lua$"), "https_main: run it as <id>/https_main.lua")
    local file = assert(io.open(spec_path, "rb"))
    local text = file:read("*a")
    file:close()
    os.remove(spec_path)
    require("setupkoenv")
    package.path = plugin_dir .. "/?.lua;" .. package.path
    require(id .. "/https_request").run(require("rapidjson").decode(text))
end)
if not ok then
    os.remove(spec_path)
    local file = code_path and io.open(code_path, "wb")
    if file then
        file:write("0")
        file:close()
    end
    io.stderr:write(tostring(err), "\n")
    os.exit(1)
end
