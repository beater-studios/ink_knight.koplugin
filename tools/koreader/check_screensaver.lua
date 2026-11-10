-- Pattern "screensaver". This file is copied
-- unchanged into every plugin as tools/koreader/check_screensaver.lua: change the pattern first.
--
-- Checks when the plugin cover replaces the sleep screen image and saves the resulting screen.
-- The plugin id is the folder that holds screensaver.lua; its full-screen windows are found by
-- looking for "covers_fullscreen = true" in its code, and each one must be named <id>_* and have
-- stop_events_propagation, so no gesture reaches what is under the plugin.
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=<desktop KOReader> tools/koreader/run_headless.sh tools/koreader/check_screensaver.lua
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))
local out_dir = assert(os.getenv("OUTPUT_DIR"))

require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
G_reader_settings:saveSetting("screensaver_type", "cover")
G_reader_settings:saveSetting("screensaver_img_background", "black")
package.path = plugin_dir .. "/?.lua;" .. package.path

local lfs = require("libs/libkoreader-lfs")
local Device = require("device")
local Screen = Device.screen
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
UIManager:init()
-- Screensaver needs a ReaderUI or FileManager instance; without a last book it falls back to the KOReader logo.
require("apps/filemanager/filemanager").instance = {}

local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Screensaver = require("ui/screensaver")

local failures = 0

local function report(ok, label, detail)
    print(string.format("%s %s: %s", ok and "ok" or "FAILED", label, detail))
    if not ok then
        failures = failures + 1
    end
end

local function read(path)
    local file = io.open(path, "r")
    if not file then
        return ""
    end
    local text = file:read("*a")
    file:close()
    return text
end

-- The plugin id: the folder with the pattern module.
local id
for entry in lfs.dir(plugin_dir) do
    if entry:sub(1, 1) ~= "." and read(plugin_dir .. "/" .. entry .. "/screensaver.lua"):find('Pattern "screensaver"', 1, true) then
        id = entry
    end
end
if not id then
    print("FAILED: no <id>/screensaver.lua from the pattern in " .. plugin_dir)
    os.exit(1)
end
local prefix = id .. "_"

-- Modules that declare a full-screen window.
local screen_modules = {}
local function scan(dir, module)
    for entry in lfs.dir(dir) do
        if entry:sub(1, 1) ~= "." then
            local path = dir .. "/" .. entry
            if lfs.attributes(path, "mode") == "directory" then
                scan(path, module .. "/" .. entry)
            elseif entry:match("%.lua$") and entry ~= "screensaver.lua" and read(path):find("covers_fullscreen%s*=%s*true") then
                screen_modules[#screen_modules + 1] = module .. "/" .. entry:gsub("%.lua$", "")
            end
        end
    end
end
scan(plugin_dir .. "/" .. id, id)
table.sort(screen_modules)
report(#screen_modules > 0, "full-screen windows found", table.concat(screen_modules, ", "))

local PluginScreensaver = require(id .. "/screensaver")
local setup_before = Screensaver.setup
PluginScreensaver.install(plugin_dir, id)
local setup_wrapped = Screensaver.setup
PluginScreensaver.install(plugin_dir, id)
report(setup_wrapped ~= setup_before and Screensaver.setup == setup_wrapped
    and Screensaver["_" .. id .. "_original_setup"] == setup_before, "install wraps setup once", "installed twice")

local plugin_image = plugin_dir .. "/assets/screensaver.png"
local default_image = "resources/koreader.png"
report(lfs.attributes(plugin_image, "mode") == "file", "cover image", plugin_image)

local function check(label, event, expected_file)
    Screensaver:setup(event)
    local file, kind = Screensaver.image_file, Screensaver.screensaver_type
    local ok = file == expected_file and (expected_file ~= plugin_image or kind == "cover")
    report(ok, label, string.format("%s (%s)", tostring(file), tostring(kind)))
    Screensaver:cleanup()
end

-- Stand-ins with the name and flag of each real window class, so the check does not depend on
-- accounts, data or network.
local stand_ins = {}
for _, module in ipairs(screen_modules) do
    local loaded, class = pcall(require, module)
    if not loaded then
        report(false, "load " .. module, (tostring(class):match("^[^\n]*")))
    elseif type(class) ~= "table" or not class.covers_fullscreen then
        report(false, "full-screen flag of " .. module, "the file sets covers_fullscreen = true but the module's table"
            .. " does not have it: declare covers_fullscreen, name and stop_events_propagation on the window class")
    else
        local named = type(class.name) == "string" and class.name:sub(1, #prefix) == prefix
        report(named, "window name of " .. module, tostring(class.name) .. " (must start with " .. prefix .. ")")
        report(class.stop_events_propagation == true, "gestures stop at " .. module,
            "stop_events_propagation = " .. tostring(class.stop_events_propagation) .. " (must be true)")
        stand_ins[#stand_ins + 1] = InputContainer:new{ name = class.name, covers_fullscreen = true }
    end
end

check("no plugin screen open", nil, default_image)

for _, screen in ipairs(stand_ins) do
    UIManager:show(screen)
    check(string.format("with %s open", tostring(screen.name)), nil, plugin_image)
    UIManager:close(screen)
end

local screen = InputContainer:new{ name = prefix .. "check", covers_fullscreen = true }
UIManager:show(screen)
check("powering off with the plugin open", "poweroff", default_image)

local dialog = InfoMessage:new{ text = "Message" }
UIManager:show(dialog)
check("with a dialog over the plugin", nil, plugin_image)
UIManager:close(dialog)

local other = InputContainer:new{ name = "other_fullscreen", covers_fullscreen = true }
UIManager:show(other)
check("with another full-screen window over the plugin", nil, default_image)
UIManager:close(other)

Screensaver:setup()
Screensaver:show()
local painted = false
for widget in UIManager:topdown_widgets_iter() do
    if widget.name == "ScreenSaver" then
        Screen.bb:fill(require("ffi/blitbuffer").COLOR_WHITE)
        widget:paintTo(Screen.bb, 0, 0)
        Screen.bb:writePNG(out_dir .. "/screensaver.png")
        painted = true
        break
    end
end
report(painted, "sleep screen painted", out_dir .. "/screensaver.png")
Screensaver:close_widget()
Screensaver:cleanup()
Device.screen_saver_mode = false

G_reader_settings:saveSetting("screensaver_type", "random_image")
check("sleep screen mode other than cover", nil, default_image)
G_reader_settings:saveSetting("screensaver_type", "cover")

UIManager:close(screen)
check("after closing the plugin", nil, default_image)

os.exit(failures == 0 and 0 or 1)
