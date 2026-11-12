-- Pattern "awake". This file is copied unchanged into every plugin that keeps the device awake, as
-- <id>/awake.lua: change the pattern first, then copy it again.
--
-- Keeps the device awake while a screen needs it, without taking the power button away. KOReader's auto
-- suspend is paused, and on a Kindle the idle timer of the system (t1) is reset every few minutes, as a touch
-- would, like KOReader's AutoSuspend does. powerd's preventScreenSaver is not used: it also makes the Kindle
-- ignore the power button, and it outlives a crash of KOReader.
local DataStorage = require("datastorage")
local Device = require("device")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

-- Below the shortest idle time of a Kindle, the same as KOReader's AutoSuspend.
local T1_RESET_SECONDS = 4 * 60

local Awake = { on = false, held = {} }

-- The holder of the calls that name none, so a plugin with a single screen that needs it can leave it out.
local DEFAULT_HOLDER = "default"

-- Every plugin with this pattern has its own copy of the module, so the plugins holding the device awake
-- are listed in PluginShare, which they all see: one timer runs while any of them holds it, and KOReader's
-- auto suspend gets its previous value back only when the last one lets go.
local function holders()
    PluginShare.awake_holders = PluginShare.awake_holders or {}
    return PluginShare.awake_holders
end

-- Skipped when KOReader's AutoSuspend also skips it: the keepalive plugin owns powerd, a reset while charging
-- causes problems, and it fails with the sleep screen up.
local function reset_idle_timer()
    local powerd = Device.powerd
    if PluginShare.keepalive or Device.screen_saver_mode or not powerd.resetT1Timeout then
        return
    end
    if powerd:isCharging() and not powerd:isCharged() then
        return
    end
    powerd:resetT1Timeout()
end

local function start_timer()
    if not Device:isKindle() then
        return
    end
    local task
    task = function()
        reset_idle_timer()
        UIManager:scheduleIn(T1_RESET_SECONDS, task)
    end
    PluginShare.awake_task = task
    task()
end

local function stop_timer()
    if PluginShare.awake_task then
        UIManager:unschedule(PluginShare.awake_task)
        PluginShare.awake_task = nil
    end
end

-- Earlier versions of this module turned preventScreenSaver on, with a marker while it was on: in the settings
-- folder, or in cache/ in the oldest ones.
local function legacy_marker_paths()
    return {
        DataStorage:getSettingsDir() .. "/" .. Awake.id .. ".awake",
        DataStorage:getDataDir() .. "/cache/" .. Awake.id .. ".awake",
    }
end

-- id: the plugin identifier. Call it when main.lua loads. It also undoes what an earlier version of this
-- module may have left on the system after a crash.
function Awake.install(id)
    assert(type(id) == "string" and id ~= "", "awake: the plugin id is required")
    Awake.id = id
    if Awake.recovered then
        return
    end
    Awake.recovered = true
    local found = false
    for _, path in ipairs(legacy_marker_paths()) do
        if lfs.attributes(path, "mode") == "file" then
            found = true
            os.remove(path)
        end
    end
    if found and Device:isKindle() and not PluginShare.keepalive then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
    end
end

-- holder: who needs the device awake, such as the screen with a clock; calls without one share a holder. Inside
-- the plugin the device stays awake while any holder holds it, so one screen letting go does not wake another's
-- clock up to the sleep screen. Letting go from a holder that holds nothing, or before install, does nothing.
function Awake.set(on, holder)
    on = on and true or false
    holder = holder == nil and DEFAULT_HOLDER or holder
    if on then
        assert(Awake.id, "awake: call Awake.install(id) when main.lua loads")
        Awake.held[holder] = true
    else
        Awake.held[holder] = nil
    end
    local held = next(Awake.held) ~= nil
    if Awake.on == held then
        return
    end
    Awake.on = held
    on = held
    local list = holders()
    if on then
        local first = next(list) == nil
        list[Awake.id] = true
        if first then
            PluginShare.awake_previous_pause = PluginShare.pause_auto_suspend
            PluginShare.pause_auto_suspend = true
            start_timer()
        end
    else
        list[Awake.id] = nil
        if next(list) == nil then
            stop_timer()
            PluginShare.pause_auto_suspend = PluginShare.awake_previous_pause
            PluginShare.awake_previous_pause = nil
        end
    end
end

return Awake
