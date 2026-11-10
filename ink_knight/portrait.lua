-- Pattern "portrait". This file is copied unchanged into every
-- plugin, as <id>/portrait.lua: change the pattern first, then copy it again.
--
-- Keeps a full-screen window in portrait: it turns KOReader upright when it is in landscape, ignores rotation
-- while the window is open and gives the previous rotation back on close, also when opening fails.
local Device = require("device")

local Portrait = {}

-- For the window's init. Odd rotation modes are landscape: the screen turns upright and the previous mode is
-- kept in widget.restore_rotation. Then setup(widget) runs, if given; when it fails, the rotation is given
-- back before the error goes on, with its traceback, because onCloseWidget never runs for a window that was
-- never shown.
function Portrait.open(widget, setup)
    local screen = Device.screen
    local rotation = screen:getRotationMode()
    if rotation % 2 == 1 then
        widget.restore_rotation = rotation
        screen:setRotationMode(screen.DEVICE_ROTATED_UPRIGHT)
    end
    if setup then
        local ok, err = xpcall(setup, debug.traceback, widget)
        if not ok then
            Portrait.close(widget)
            error(err, 0)
        end
    end
end

-- For the window's onCloseWidget: gives the previous rotation back, once.
function Portrait.close(widget)
    local rotation = widget.restore_rotation
    if rotation then
        widget.restore_rotation = nil
        Device.screen:setRotationMode(rotation)
    end
end

-- For the window's onSetRotationMode: returning true stops KOReader from turning the screen while it is open.
function Portrait.ignore_rotation()
    return true
end

return Portrait
