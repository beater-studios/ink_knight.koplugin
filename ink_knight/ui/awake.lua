-- Keeps the device awake during a game with a clock: if it slept, the Wi-Fi would drop while the clock keeps running.
local DataStorage = require("datastorage")
local Device = require("device")
local PluginShare = require("pluginshare")
local lfs = require("libs/libkoreader-lfs")

local Awake = { on = false }

local function marker_path()
    return DataStorage:getDataDir() .. "/cache/ink_knight.awake"
end

local function set_system(on)
    if Device:isKindle() and not PluginShare.keepalive then
        os.execute(string.format("lipc-set-prop com.lab126.powerd preventScreenSaver %d", on and 1 or 0))
    end
end

function Awake.set(on)
    if Awake.on == on then
        return
    end
    Awake.on = on
    if on then
        Awake.previous_pause = PluginShare.pause_auto_suspend
        PluginShare.pause_auto_suspend = true
        local marker = io.open(marker_path(), "w")
        if marker then
            marker:close()
        end
    else
        PluginShare.pause_auto_suspend = Awake.previous_pause
        os.remove(marker_path())
    end
    set_system(on)
end

-- A crash or a forced quit during a game would leave the device unable to sleep.
function Awake.recover()
    if lfs.attributes(marker_path(), "mode") == "file" then
        set_system(false)
        os.remove(marker_path())
    end
end

return Awake
