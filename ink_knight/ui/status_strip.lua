-- The time and the battery, centered at the bottom of every full screen of the plugin.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local datetime = require("datetime")

local Screen = Device.screen

local BOLD = "noto/NotoSans-Bold.ttf"
local BLACK = Blitbuffer.COLOR_BLACK
local LINE = Blitbuffer.Color8(0xBB)
local HEIGHT, TEXT_SIZE = 24, 15
local BATTERY_W, BATTERY_H, BATTERY_NUB = 22, 12, 2
local GAP_GROUP, GAP_BATTERY = 16, 4
-- Wide enough for "12:59 PM" and "100%".
local REGION_W = 220

local StatusStrip = {}

local function px(value)
    return math.floor(value * math.min(Screen:getWidth() / 600, Screen:getHeight() / 800) + 0.5)
end

function StatusStrip.height()
    return px(HEIGHT)
end

local function battery_percent()
    if not Device:hasBattery() then
        return nil
    end
    local ok, capacity = pcall(function() return Device:getPowerDevice():getCapacity() end)
    return ok and tonumber(capacity) or nil
end

local function new_text(text)
    return TextWidget:new{
        text = text,
        face = Font:getFace(BOLD, px(TEXT_SIZE) * 1000 / Screen:scaleBySize(1000)),
        fgcolor = BLACK,
    }
end

local function paint_battery(bb, x, y, h, percent)
    local w, box_h = px(BATTERY_W), px(BATTERY_H)
    local box_y = y + math.floor((h - box_h) / 2)
    local nub = px(BATTERY_NUB)
    bb:paintBorder(x, box_y, w, box_h, 1, BLACK)
    bb:paintRect(x + w, box_y + nub + 1, nub, box_h - 2 * nub - 2, BLACK)
    local inner = w - 2 * nub
    local fill = math.max(1, math.floor(inner * math.max(0, math.min(percent, 100)) / 100 + 0.5))
    bb:paintRect(x + nub, box_y + nub, fill, box_h - 2 * nub, BLACK)
end

-- width and height: of the screen the strip belongs to.
function StatusStrip.paint(bb, width, height)
    local strip_h = StatusStrip.height()
    local y = height - strip_h
    bb:paintRect(0, y, width, 1, LINE)
    local clock = new_text(datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock")))
    local clock_w = clock:getSize().w
    local percent = battery_percent()
    local level = percent and new_text(string.format("%d%%", percent))
    local total = clock_w
    if level then
        total = total + px(GAP_GROUP) + px(BATTERY_W + BATTERY_NUB) + px(GAP_BATTERY) + level:getSize().w
    end
    local x = math.floor((width - total) / 2)
    local text_y = y + math.floor((strip_h - clock:getSize().h) / 2)
    clock:paintTo(bb, x, text_y)
    clock:free()
    if level then
        x = x + clock_w + px(GAP_GROUP)
        paint_battery(bb, x, y, strip_h, percent)
        level:paintTo(bb, x + px(BATTERY_W + BATTERY_NUB) + px(GAP_BATTERY), text_y)
        level:free()
    end
end

-- Only the middle, so the minute going by touches as little of the screen as it can.
function StatusStrip.region(width, height)
    local strip_h = StatusStrip.height()
    local w = px(REGION_W)
    return Geom:new{ x = math.floor((width - w) / 2), y = height - strip_h + 1, w = w, h = strip_h - 1 }
end

return StatusStrip
