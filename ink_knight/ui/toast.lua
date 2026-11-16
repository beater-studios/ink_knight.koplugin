-- A short notice in a black pill above the foot of the screen. It does not take taps, and leaves by itself.
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Sleep = require("ink_knight/sleep")
local StatusStrip = require("ink_knight/ui/status_strip")
local Style = require("ink_knight/ui/style")

local Screen = Device.screen

local Toast = WidgetContainer:extend{
    name = "ink_knight_toast",
    toast = true,
    text = "",
    timeout = 3,
}

function Toast:init()
    local width, height = Screen:getWidth(), Screen:getHeight()
    local scale = math.min(width / 600, height / 800)
    local margin = math.floor(Style.CARD_SHADOW * scale + 0.5) + math.floor(40 * scale)
    self.pad_x, self.pad_y = math.floor(24 * scale), math.floor(12 * scale)
    local face = Font:getFace(Style.BOLD, 16 * scale * 1000 / Screen:scaleBySize(1000))
    -- As wide as the text needs, up to the width of the screen less its margins, on more lines when it is long.
    local measure = TextWidget:new{ text = self.text, face = face }
    local text_w = math.min(measure:getSize().w + 2, width - 2 * margin - 2 * self.pad_x)
    measure:free()
    self.box = TextBoxWidget:new{
        text = self.text,
        face = face,
        width = text_w,
        alignment = "center",
        fgcolor = Style.WHITE,
        bgcolor = Style.BLACK,
    }
    local box = self.box:getSize()
    local w, h = box.w + 2 * self.pad_x, box.h + 2 * self.pad_y
    local bottom = height - StatusStrip.height() - math.floor(24 * scale)
    self.dimen = Geom:new{ x = math.floor((width - w) / 2), y = bottom - h, w = w, h = h }
    self.radius = math.min(math.floor(h / 2), math.floor(26 * scale))
end

-- A black pill, or a rounded card when the text takes several lines.
function Toast:paintTo(bb)
    local d = self.dimen
    bb:paintRoundedRect(d.x, d.y, d.w, d.h, Style.BLACK, self.radius)
    self.box:paintTo(bb, d.x + self.pad_x, d.y + self.pad_y)
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
