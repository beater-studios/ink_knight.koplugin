-- Pattern "awake". This file is copied unchanged into every plugin that has the pattern, as
-- tools/koreader/check_awake.lua: change the pattern first, then copy it again.
--
-- Checks <id>/awake.lua inside the desktop KOReader, pretending to be a Kindle: powerd, the commands and the
-- timers are stand-ins that record what the module asks for. The plugin id is the folder that holds awake.lua.
-- Usage: KOREADER_DIR=<desktop KOReader> tools/koreader/run_headless.sh tools/koreader/check_awake.lua
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))

require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path

local lfs = require("libs/libkoreader-lfs")
local Device = require("device")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")

local id
for name in lfs.dir(plugin_dir) do
    if name:sub(1, 1) ~= "." and lfs.attributes(plugin_dir .. "/" .. name .. "/awake.lua", "mode") == "file" then
        id = name
    end
end
if not id then
    print("FAILED no <id>/awake.lua in " .. plugin_dir)
    os.exit(1)
end

local marker_dir = DataStorage:getSettingsDir() .. "/"
lfs.mkdir(marker_dir)
local marker = marker_dir .. id .. ".awake"
-- Where the oldest versions of the module kept it.
local cache_dir = DataStorage:getDataDir() .. "/cache/"
lfs.mkdir(cache_dir)
local cache_marker = cache_dir .. id .. ".awake"

local commands = {}
os.execute = function(command)
    commands[#commands + 1] = command
    return 0
end
local resets = 0
local charging = false
Device.isKindle = function() return true end
Device.powerd = {
    isCharging = function() return charging end,
    isCharged = function() return false end,
    resetT1Timeout = function() resets = resets + 1 end,
}
-- The timers: what is scheduled waits here until the check runs it.
local scheduled = {}
UIManager.scheduleIn = function(_, seconds, task)
    scheduled[#scheduled + 1] = { seconds = seconds, task = task }
end
UIManager.unschedule = function(_, task)
    for i = #scheduled, 1, -1 do
        if scheduled[i].task == task then
            table.remove(scheduled, i)
        end
    end
end
local function run_timers()
    local due = scheduled
    scheduled = {}
    for _, entry in ipairs(due) do
        entry.task()
    end
end

local failures = 0
local function check(name, ok)
    print((ok and "ok    " or "FAILED ") .. name)
    if not ok then
        failures = failures + 1
    end
end
local function exists(path)
    return lfs.attributes(path, "mode") == "file"
end
local function count(text)
    local n = 0
    for _, command in ipairs(commands) do
        if command:find(text, 1, true) then
            n = n + 1
        end
    end
    return n
end

for _, path in ipairs({ marker, cache_marker }) do
    local leftover = io.open(path, "w")
    leftover:close()
end
local Awake = require(id .. "/awake")
Awake.install(id)
check("markers of earlier versions: install turns preventScreenSaver off once", count("preventScreenSaver 0") == 1)
check("a marker of an earlier version: install removes it", not exists(marker))
check("a marker of the oldest versions, in cache: install removes it", not exists(cache_marker))
Awake.install(id)
check("install recovers only once", count("preventScreenSaver 0") == 1)

-- A fresh copy of the module, as in the next run of KOReader, with only the marker in cache.
local leftover = io.open(cache_marker, "w")
leftover:close()
commands = {}
local Fresh = dofile(plugin_dir .. "/" .. id .. "/awake.lua")
Fresh.install(id)
check("only the marker in cache: install turns preventScreenSaver off", count("preventScreenSaver 0") == 1)
check("only the marker in cache: install removes it", not exists(cache_marker))
commands = {}

PluginShare.pause_auto_suspend = "previous"
Awake.set(true)
check("on: pauses KOReader's auto suspend", PluginShare.pause_auto_suspend == true)
check("on: resets the idle timer at once", resets == 1)
check("on: schedules the next reset within 5 minutes", #scheduled == 1 and scheduled[1].seconds > 0 and scheduled[1].seconds < 300)
check("on: never sets preventScreenSaver, which would block the power button", count("preventScreenSaver 1") == 0)
check("on: leaves nothing on disk", not exists(marker))
run_timers()
check("the timer resets again and schedules itself", resets == 2 and #scheduled == 1)
Awake.set(true)
check("on twice: changes nothing", resets == 2 and #scheduled == 1)
Awake.set(false)
check("off: restores the previous auto suspend", PluginShare.pause_auto_suspend == "previous")
check("off: stops the timer", #scheduled == 0)
run_timers()
check("off: no reset after it", resets == 2)

PluginShare.keepalive = true
Awake.set(true)
check("with keepalive: leaves powerd alone", resets == 2)
Awake.set(false)
PluginShare.keepalive = nil

charging = true
Awake.set(true)
check("while charging: no reset, as KOReader's AutoSuspend", resets == 2)
check("while charging: keeps checking", #scheduled == 1)
charging = false
run_timers()
check("after charging: resets again", resets == 3)
Awake.set(false)

Device.screen_saver_mode = true
Awake.set(true)
check("with the sleep screen up: no reset", resets == 3)
Awake.set(false)
Device.screen_saver_mode = false

-- Another plugin with the pattern has its own copy of the module.
local Other = dofile(plugin_dir .. "/" .. id .. "/awake.lua")
Other.install("other_plugin")
Awake.set(true)
Other.set(true)
check("two plugins on: one timer", resets == 4 and #scheduled == 1)
Awake.set(false)
check("one of two off: keeps the device awake", #scheduled == 1 and PluginShare.pause_auto_suspend == true)
Other.set(false)
check("both off: stops the timer and restores the auto suspend", #scheduled == 0 and PluginShare.pause_auto_suspend == "previous")

Device.isKindle = function() return false end
commands, resets = {}, 0
Awake.set(true)
check("outside the Kindle: only the auto suspend", resets == 0 and #scheduled == 0 and #commands == 0 and PluginShare.pause_auto_suspend == true)
Awake.set(false)

print(string.format("%s: %d failures", id, failures))
os.exit(failures == 0 and 0 or 1)
