-- Pattern "download". This file is copied unchanged into every plugin that downloads files in the background, as
-- <id>/download_main.lua: change the pattern first, then copy it again.
--
-- The download worker as its own program, used only on macOS, where a forked child cannot use the network. It
-- receives the plugin folder and a file with its settings, which it deletes as soon as it is read, since it may hold
-- headers such as a token. When it cannot start, the progress file says it ended, so the screen is never left waiting.
local plugin_dir, settings_path = arg[1], arg[2]
local settings
local ok, err = pcall(function()
    local id = assert(arg[0]:match("([^/]+)/download_main%.lua$"), "download_main: run it as <id>/download_main.lua")
    local file = assert(io.open(settings_path, "rb"))
    local text = file:read("*a")
    file:close()
    os.remove(settings_path)
    require("setupkoenv")
    package.path = plugin_dir .. "/?.lua;" .. package.path
    settings = require("rapidjson").decode(text)
    require(id .. "/download_worker").run(settings)
end)
if not ok then
    os.remove(settings_path)
    local file = settings and settings.progress and io.open(settings.progress, "wb")
    if file then
        file:write("0 0 0 end")
        file:close()
    end
    io.stderr:write(tostring(err), "\n")
    os.exit(1)
end
