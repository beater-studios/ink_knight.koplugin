-- A short notice over the bottom of the screen. It does not take taps, and leaves by itself.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Sleep = require("ink_knight/sleep")

local Screen = Device.screen

local Toast = WidgetContainer:extend{
    name = "ink_knight_toast",
    toast = true,
    text = "",
    timeout = 3,
}

function Toast:init()
    local width, height = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(14)
    self.box = TextBoxWidget:new{
        text = self.text,
        face = Font:getFace("noto/NotoSans-Regular.ttf", 17),
        width = width - 2 * pad,
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_WHITE,
        bgcolor = Blitbuffer.COLOR_BLACK,
    }
    local box_h = self.box:getSize().h
    self.pad = pad
    self.dimen = Geom:new{ x = 0, y = height - box_h - 2 * pad, w = width, h = box_h + 2 * pad }
end

function Toast:paintTo(bb)
    bb:paintRect(self.dimen.x, self.dimen.y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_BLACK)
    self.box:paintTo(bb, self.pad, self.dimen.y + self.pad)
end

-- window: the full screen of the plugin that owns the notice. While the device sleeps, the notice waits for it
-- to wake up, and so does its leaving, so neither is drawn over the sleep screen.
function Toast.show(window, text, timeout)
    local toast = Toast:new{ text = text, timeout = timeout or 3 }
    window._toasts = window._toasts or {}
    window._toasts[toast] = true
    Sleep.show(window, toast, "ui", toast.dimen)
    Sleep.schedule(window, toast.timeout, function()
        window._toasts[toast] = nil
        if UIManager:isWidgetShown(toast) then
            UIManager:close(toast, "ui", toast.dimen)
        end
    end)
    return toast
end

-- The window is closing, and with it the timers that would close its notices.
function Toast.close_all(window)
    for toast in pairs(window._toasts or {}) do
        if UIManager:isWidgetShown(toast) then
            UIManager:close(toast)
        end
    end
    window._toasts = {}
end

function Toast:onCloseWidget()
    self.box:free()
end

return Toast
