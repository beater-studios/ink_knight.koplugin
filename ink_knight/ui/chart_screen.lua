-- The rating of a player in one kind of game: the chart, with the numbers that matter below it.
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Draw = require("ink_knight/ui/draw")
local Page = require("ink_knight/ui/page")
local Portrait = require("ink_knight/portrait")
local RatingChart = require("ink_knight/rating_chart")
local StatusStrip = require("ink_knight/ui/status_strip")
local Style = require("ink_knight/ui/style")

local Screen = Device.screen

local BOLD, REGULAR = Style.BOLD, Style.REGULAR
local BLACK, WHITE = Style.BLACK, Style.WHITE
local GRID = Style.LIGHT

local DAY = 86400
local PERIODS = {
    { key = "month", seconds = 31 * DAY, label = "period_month" },
    { key = "quarter", seconds = 92 * DAY, label = "period_quarter" },
    { key = "year", seconds = 366 * DAY, label = "period_year" },
    { key = "all", label = "period_all" },
}

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
    Portrait.open(self, self.setup)
end

function ChartScreen:setup()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
    self.scale = math.min(self.width / 600, self.height / 800)
    local px = function(value) return math.floor(value * self.scale + 0.5) end
    self.px = px
    local line_h = px(28)
    self.line_h = line_h
    self.title_h = px(Style.BAND)
    local shadow = px(Style.CARD_SHADOW)
    local m = px(16)
    local card_w = self.width - 2 * m - shadow
    -- The rating now in a card, the chart in another, and the numbers that matter in a third at the foot.
    self.now_card = { x = m, y = self.title_h + px(14), w = card_w, h = px(80) }
    -- The numbers do not depend on the size of the chart, so they are counted first, to size their card.
    local count = #RatingChart.stat_lines(self.strings, self.stats, RatingChart.layout(self.points or {}, { x = 0, y = 0, w = 100, h = 100 }))
    local lines_h = line_h * math.max(1, count) + px(24)
    self.lines_card = { x = m, y = self.height - StatusStrip.height() - px(12) - shadow - lines_h, w = card_w, h = lines_h }
    -- The periods to show, in pills between the chart and the numbers.
    local pill_h, gap = px(40), px(10)
    local pills_y = self.lines_card.y - px(14) - pill_h
    local pill_w = math.floor((self.width - 2 * m - gap * (#PERIODS - 1)) / #PERIODS)
    self.period_rects = {}
    for index, period in ipairs(PERIODS) do
        self.period_rects[index] = { key = period.key, x = m + (index - 1) * (pill_w + gap), y = pills_y, w = pill_w, h = pill_h }
    end
    local chart_y = self.now_card.y + self.now_card.h + shadow + px(14)
    self.chart_card = { x = m, y = chart_y, w = card_w, h = pills_y - px(14) - chart_y }
    self.plot = {
        x = m + px(58),
        y = chart_y + px(18),
        w = card_w - px(58) - px(34),
        h = self.chart_card.h - px(18) - px(40),
    }
    self.period = self.period or "all"
    -- The numbers are of the whole history, as Lichess gives them; only the chart follows the period.
    self.lines = RatingChart.stat_lines(self.strings, self.stats, RatingChart.layout(self.points or {}, self.plot))
    self:apply_period()
end

-- The points of the period chosen: since that long before the last one, with at least the last two, so a quiet month still has a line.
function ChartScreen:period_points()
    local points = self.points or {}
    local seconds
    for _, period in ipairs(PERIODS) do
        if period.key == self.period then
            seconds = period.seconds
        end
    end
    if not seconds or #points < 3 then
        return points
    end
    local since = points[#points].time - seconds
    local chosen = {}
    for _, point in ipairs(points) do
        if point.time >= since then
            chosen[#chosen + 1] = point
        end
    end
    while #chosen < 2 and #chosen < #points do
        table.insert(chosen, 1, points[#points - #chosen])
    end
    return chosen
end

function ChartScreen:apply_period()
    self.layout = RatingChart.layout(self:period_points(), self.plot)
end

function ChartScreen:paint_text(bb, text, name, size, x, y, w, h, align, color)
    if not text or text == "" then
        return
    end
    local widget = TextWidget:new{ text = text, face = face(name, size * self.scale), fgcolor = color or BLACK, max_width = w }
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
    local bottom = plot.y + plot.h
    -- The area under the line in light gray, a column at a time between the points.
    for index = 2, #layout.path do
        local a, b = layout.path[index - 1], layout.path[index]
        for x = a.x, b.x do
            local y = b.x == a.x and b.y or math.floor(a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x) + 0.5)
            bb:paintRect(x, y, 1, bottom - y, Style.PALE)
        end
    end
    for _, tick in ipairs(layout.ticks) do
        bb:paintRect(plot.x, tick.y, plot.w, 1, GRID)
        self:paint_text(bb, tostring(tick.value), REGULAR, 13, self.chart_card.x, tick.y - px(12), plot.x - self.chart_card.x - px(8), px(24), "right")
    end
    local previous
    for _, mark in ipairs(layout.path) do
        if previous and (previous.x ~= mark.x or previous.y ~= mark.y) then
            paint_segment(bb, previous.x, previous.y, mark.x, mark.y, px(3))
        end
        previous = mark
    end
    -- The highest point solid, and where it is now as a ring.
    local top
    for _, mark in ipairs(layout.path) do
        if not top or mark.y < top.y then
            top = mark
        end
    end
    local last = layout.path[#layout.path]
    if top and top ~= last then
        bb:paintCircle(top.x, top.y, px(6), BLACK)
    end
    bb:paintCircle(last.x, last.y, px(7), BLACK)
    bb:paintCircle(last.x, last.y, px(4), WHITE)
    local labels_y = bottom + px(8)
    self:paint_text(bb, os.date("%m/%Y", layout.first_time), REGULAR, 13, plot.x, labels_y, plot.w, px(24), "left")
    if layout.last_time ~= layout.first_time then
        self:paint_text(bb, os.date("%m/%Y", layout.last_time), REGULAR, 13, plot.x, labels_y, plot.w, px(24), "right")
    end
end

function ChartScreen:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local px = self.px
    bb:paintRect(0, 0, self.width, self.height, Style.PAPER)
    bb:paintRect(0, 0, self.width, self.title_h, BLACK)
    Draw.icon(bb, "back", px(26), math.floor(self.title_h / 2), px(24), WHITE)
    self:paint_text(bb, self.title, BOLD, Style.TITLE, px(52), 0, self.width - px(68), self.title_h, "left", WHITE)
    -- The history comes from Lichess. If it cannot be drawn, a short message takes its place, and the way back
    -- in the title still works.
    local ok, err = pcall(self.paint_content, self, bb)
    if not ok then
        logger.warn("Ink Knight: could not draw the chart", err)
        bb:paintRect(0, self.title_h, self.width, self.height - self.title_h, Style.PAPER)
        self:paint_text(bb, self.strings and self.strings.unexpected_error or "", REGULAR, 18, px(10), self.plot.y, self.width - px(20), self.plot.h, "center")
    end
    StatusStrip.paint(bb, self.width, self.height)
end

function ChartScreen:paint_content(bb)
    local px, s = self.px, self.strings
    for _, card in ipairs({ self.now_card, self.chart_card, self.lines_card }) do
        Draw.card(bb, card.x, card.y, card.w, card.h, self.scale)
    end
    local now = self.now_card
    self:paint_text(bb, Draw.upper(s.chart_now), BOLD, 12, now.x + px(16), now.y + px(10), now.w - px(32), px(18), "left", Style.DARK)
    if self.layout then
        self:paint_text(bb, tostring(self.layout.current), BOLD, 38, now.x + px(16), now.y + px(28), px(160), px(44), "left")
        self:paint_chart(bb)
    else
        self:paint_text(bb, s.chart_empty, REGULAR, 18, self.chart_card.x + px(10), self.chart_card.y, self.chart_card.w - px(20), self.chart_card.h, "center")
    end
    for index, rect in ipairs(self.period_rects) do
        local chosen = rect.key == self.period
        Draw.pill(bb, rect.x, rect.y, rect.w, rect.h, self.scale, chosen)
        self:paint_text(bb, s[PERIODS[index].label], BOLD, 15, rect.x + px(8), rect.y, rect.w - px(16), rect.h, "center", chosen and WHITE or BLACK)
    end
    local lines = self.lines_card
    for index, line in ipairs(self.lines) do
        self:paint_text(bb, line, REGULAR, 16, lines.x + px(16), lines.y + px(12) + (index - 1) * self.line_h, lines.w - px(32), self.line_h, "left")
    end
end

function ChartScreen:strip_region()
    return StatusStrip.region(self.width, self.height)
end

function ChartScreen:onTap(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    if y < self.title_h then
        UIManager:close(self)
        return true
    end
    for _, rect in ipairs(self.period_rects or {}) do
        if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h and rect.key ~= self.period then
            self.period = rect.key
            self:apply_period()
            UIManager:setDirty(self, function() return Page.refresh:mode("chart"), self.dimen end)
            return true
        end
    end
    return true
end

function ChartScreen:onBack()
    UIManager:close(self)
    return true
end

-- KOReader sends Close to every window before it quits, and with keep_screensaver before powering off, when the
-- window stays so the sleep screen is left alone.
function ChartScreen:onClose(arg)
    if not (arg and arg.keep_screensaver) then
        UIManager:close(self)
    end
end

ChartScreen.onSetRotationMode = Portrait.ignore_rotation

-- The page underneath shows again, counted with the pages. Coming after the chart, it flashes.
function ChartScreen:onCloseWidget()
    Portrait.close(self)
    UIManager:setDirty(nil, Page.refresh_mode())
end

-- A chart is a layout of its own among the pages, so it opens with a flash.
function ChartScreen:onShow()
    UIManager:setDirty(self, Page.refresh:mode("chart"))
    return true
end

return ChartScreen
