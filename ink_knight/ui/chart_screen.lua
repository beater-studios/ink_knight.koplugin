-- The rating of a player in one kind of game: the chart, with the numbers that matter below it.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")

local RatingChart = require("ink_knight/rating_chart")
local StatusStrip = require("ink_knight/ui/status_strip")

local Screen = Device.screen

local BOLD = "noto/NotoSans-Bold.ttf"
local REGULAR = "noto/NotoSans-Regular.ttf"
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRID = Blitbuffer.Color8(0xCC)

local ChartScreen = InputContainer:extend{
    name = "ink_knight_chart",
    covers_fullscreen = true,
    stop_events_propagation = true,
    title = "",
    points = nil,
    stats = nil,
    strings = nil,
}

local function face(name, size)
    return Font:getFace(name, size * 1000 / Screen:scaleBySize(1000))
end

function ChartScreen:init()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self.scale = math.min(self.width / 600, self.height / 800)
    local px = function(value) return math.floor(value * self.scale + 0.5) end
    self.px = px
    local line_h = px(30)
    self.line_h = line_h
    self.title_h = px(66)
    local lines_y = self.height - StatusStrip.height() - px(8)
    self.plot = {
        x = px(62),
        y = self.title_h + px(16),
        w = self.width - px(62) - px(50),
        h = lines_y - self.title_h - px(16) - px(40) - line_h * 5,
    }
    self.layout = RatingChart.layout(self.points or {}, self.plot)
    self.lines = RatingChart.stat_lines(self.strings, self.stats, self.layout)
end

function ChartScreen:paint_text(bb, text, name, size, x, y, w, h, align)
    local widget = TextWidget:new{ text = text, face = face(name, size * self.scale), fgcolor = BLACK, max_width = w }
    local measured = widget:getSize()
    local tx = x
    if align == "center" then
        tx = x + math.floor((w - measured.w) / 2)
    elseif align == "right" then
        tx = x + w - measured.w
    end
    widget:paintTo(bb, tx, y + math.floor((h - measured.h) / 2))
    widget:free()
end

-- A straight line, two pixels thick.
local function paint_segment(bb, x0, y0, x1, y1, thickness)
    local dx, dy = math.abs(x1 - x0), -math.abs(y1 - y0)
    local sx, sy = x0 < x1 and 1 or -1, y0 < y1 and 1 or -1
    local err = dx + dy
    while true do
        bb:paintRect(x0, y0, thickness, thickness, BLACK)
        if x0 == x1 and y0 == y1 then
            return
        end
        local doubled = 2 * err
        if doubled >= dy then
            err, x0 = err + dy, x0 + sx
        end
        if doubled <= dx then
            err, y0 = err + dx, y0 + sy
        end
    end
end

function ChartScreen:paint_chart(bb)
    local plot, layout, px = self.plot, self.layout, self.px
    for _, tick in ipairs(layout.ticks) do
        bb:paintRect(plot.x, tick.y, plot.w, 1, GRID)
        self:paint_text(bb, tostring(tick.value), REGULAR, 15, 0, tick.y - px(12), plot.x - px(8), px(24), "right")
    end
    local previous
    for _, mark in ipairs(layout.path) do
        if previous and (previous.x ~= mark.x or previous.y ~= mark.y) then
            paint_segment(bb, previous.x, previous.y, mark.x, mark.y, px(2))
        end
        previous = mark
    end
    local last = layout.path[#layout.path]
    bb:paintCircle(last.x, last.y, px(5), BLACK)
    self:paint_text(bb, tostring(layout.current), BOLD, 15, last.x + px(8), last.y - px(12), self.width - last.x - px(10), px(24), "left")
    local labels_y = plot.y + plot.h + px(6)
    self:paint_text(bb, os.date("%m/%Y", layout.first_time), REGULAR, 15, plot.x, labels_y, plot.w, px(24), "left")
    if layout.last_time ~= layout.first_time then
        self:paint_text(bb, os.date("%m/%Y", layout.last_time), REGULAR, 15, plot.x, labels_y, plot.w, px(24), "right")
    end
end

function ChartScreen:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local px = self.px
    bb:paintRect(0, 0, self.width, self.height, WHITE)
    self:paint_text(bb, "\226\128\185", BOLD, 40, 0, 0, px(60), self.title_h - px(6), "center")
    self:paint_text(bb, self.title, BOLD, 24, px(60), 0, self.width - px(76), self.title_h, "left")
    bb:paintRect(0, self.title_h - px(2), self.width, px(2), BLACK)
    local lines_y
    if self.layout then
        self:paint_chart(bb)
        lines_y = self.plot.y + self.plot.h + px(38)
    else
        self:paint_text(bb, self.strings.chart_empty, REGULAR, 18, px(10), self.plot.y, self.width - px(20), self.plot.h, "center")
        lines_y = self.plot.y + self.plot.h
    end
    for index, line in ipairs(self.lines) do
        self:paint_text(bb, line, REGULAR, 18, px(14), lines_y + (index - 1) * self.line_h, self.width - px(28), self.line_h, "left")
    end
    StatusStrip.paint(bb, self.width, self.height)
end

function ChartScreen:strip_region()
    return StatusStrip.region(self.width, self.height)
end

function ChartScreen:onTap(_, ges)
    if ges.pos.y < self.title_h then
        UIManager:close(self)
    end
    return true
end

function ChartScreen:onClose()
    UIManager:close(self)
    return true
end

function ChartScreen:onCloseWidget()
    UIManager:setDirty(nil, "ui")
end

function ChartScreen:onShow()
    UIManager:setDirty(self, "full")
    return true
end

return ChartScreen
