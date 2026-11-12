-- A chess clock for a game on a physical board: the screen in two halves, the top one turned round for the player
-- across, with the buttons between them. Each player taps their own half after moving. The half of the side to
-- move is inverted, so who is thinking shows from afar; each second only its time is redrawn.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local socket = require("socket")

local Awake = require("ink_knight/awake")
local ChessClock = require("ink_knight/chess_clock")
local Page = require("ink_knight/ui/page")
local Portrait = require("ink_knight/portrait")
local Refresh = require("ink_knight/refresh")
local Sleep = require("ink_knight/sleep")
local StatusStrip = require("ink_knight/ui/status_strip")

local Screen = Device.screen

local BOLD = "noto/NotoSans-Bold.ttf"
local REGULAR = "noto/NotoSans-Regular.ttf"
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

-- The top half belongs to black and the bottom to white, only to tell them apart: the screen never names them.
local TOP, BOTTOM = "b", "w"

local ClockScreen = InputContainer:extend{
    name = "ink_knight_clock",
    covers_fullscreen = true,
    stop_events_propagation = true,
    app = nil,
    preset = nil,
}

local function face(name, size)
    return Font:getFace(name, size * 1000 / Screen:scaleBySize(1000))
end

function ClockScreen.open(app, preset)
    local screen = ClockScreen:new{ app = app, preset = preset }
    UIManager:show(screen)
    return screen
end

function ClockScreen:init()
    self.s = self.app.strings
    self.clock = ChessClock.new(ChessClock.parse(self.preset))
    self.tick_callback = function() self:tick() end
    -- Each turn changes both halves; after this many without a flash, one clears what e-ink leaves behind.
    self.refresh_count = Refresh.new(20)
    Sleep.watch(self)
    Portrait.open(self, self.setup)
end

function ClockScreen:setup()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
    self.scale = math.min(self.width / 600, self.height / 800)
    local px = function(value) return math.floor(value * self.scale + 0.5) end
    self.px = px
    local bar_h = px(72)
    local half_h = math.floor((self.height - StatusStrip.height() - bar_h) / 2)
    self.halves = {
        [TOP] = { x = 0, y = 0, w = self.width, h = half_h },
        [BOTTOM] = { x = 0, y = half_h + bar_h, w = self.width, h = half_h },
    }
    self.bar = { x = 0, y = half_h, w = self.width, h = bar_h }
    -- Each second redraws the screen, so what does not change is worked out once: the sizes that fit, by text
    -- length, and the buffer the top half is drawn on before it is turned round.
    self.sizes = {}
    if self.top_buffer then
        self.top_buffer:free()
        self.top_buffer = nil
    end
end

function ClockScreen:paint_text(bb, text, name, size, x, y, w, h, color)
    local widget = TextWidget:new{ text = text, face = face(name, size), fgcolor = color, max_width = w }
    local measured = widget:getSize()
    widget:paintTo(bb, x + math.floor((w - measured.w) / 2), y + math.floor((h - measured.h) / 2))
    widget:free()
end

-- The largest size up to max at which text fits width.
local function fit(text, name, max, width)
    local size = max
    while size > 12 do
        local widget = TextWidget:new{ text = text, face = face(name, size) }
        local w = widget:getSize().w
        widget:free()
        if w <= width then
            return size
        end
        size = size - 4
    end
    return size
end

-- digits: a time, measured with its digits as zeros, so the size changes with its length only and not every second.
function ClockScreen:fitting(text, name, max, width, digits)
    local sample = digits and (text:gsub("%d", "0")) or text
    local key = table.concat({ sample, name, max, width }, "|")
    local size = self.sizes[key]
    if not size then
        size = fit(sample, name, max, width)
        self.sizes[key] = size
    end
    return size
end

function ClockScreen:half_label(side)
    local s, clock = self.s, self.clock
    if clock.flagged == side then
        return s.clock_flagged
    elseif not clock.active then
        return s.clock_tap_start
    elseif self.paused then
        return s.clock_paused
    end
    return string.format(s.clock_moves, clock.moves[side])
end

-- One half, drawn upright at 0, 0 of bb, as big as rect.
function ClockScreen:paint_half(bb, side, rect)
    local px, clock = self.px, self.clock
    local inverted = (clock.active == side and not self.paused and not clock.flagged) or clock.flagged == side
    local ink = inverted and WHITE or BLACK
    bb:paintRect(0, 0, rect.w, rect.h, inverted and BLACK or WHITE)
    local text = ChessClock.text(ChessClock.left(clock, side, socket.gettime()))
    local size = self:fitting(text, BOLD, math.floor(rect.h * 0.42), rect.w - px(40), true)
    local time_h = math.floor(rect.h * 0.62)
    self:paint_text(bb, text, BOLD, size, 0, 0, rect.w, time_h, ink)
    self:paint_text(bb, self:half_label(side), REGULAR, 22 * self.scale, px(16), time_h, rect.w - px(32), rect.h - time_h - px(16), ink)
end

-- The top half is drawn on its own and turned round, so the player across reads it the right way up.
function ClockScreen:paint_side(bb, side)
    local rect = self.halves[side]
    if side == BOTTOM then
        local view = bb:viewport(rect.x, rect.y, rect.w, rect.h)
        self:paint_half(view, side, rect)
        return
    end
    if not self.top_buffer or self.top_buffer:getType() ~= bb:getType() then
        if self.top_buffer then
            self.top_buffer:free()
        end
        self.top_buffer = Blitbuffer.new(rect.w, rect.h, bb:getType())
    end
    local buffer = self.top_buffer
    buffer:setRotation(0)
    self:paint_half(buffer, side, rect)
    buffer:rotate(180)
    bb:blitFrom(buffer, rect.x, rect.y, 0, 0, rect.w, rect.h)
end

function ClockScreen:buttons()
    local s, clock = self.s, self.clock
    local buttons = { { id = "back", label = s.back } }
    if clock.active and not clock.flagged then
        buttons[#buttons + 1] = self.paused and { id = "resume", label = s.clock_resume } or { id = "pause", label = s.clock_pause }
    end
    buttons[#buttons + 1] = { id = "restart", label = s.clock_restart }
    return buttons
end

function ClockScreen:button_rects()
    local px, bar = self.px, self.bar
    local buttons = self:buttons()
    local gap = px(8)
    local w = math.floor((bar.w - px(16) - gap * (#buttons - 1)) / #buttons)
    local rects = {}
    for index, button in ipairs(buttons) do
        rects[index] = { id = button.id, label = button.label, x = px(8) + (index - 1) * (w + gap), y = bar.y + px(8), w = w, h = bar.h - px(16) }
    end
    return rects
end

function ClockScreen:paint_bar(bb)
    local px = self.px
    bb:paintRect(self.bar.x, self.bar.y, self.bar.w, self.bar.h, WHITE)
    for _, rect in ipairs(self:button_rects()) do
        bb:paintBorder(rect.x, rect.y, rect.w, rect.h, px(2), BLACK)
        local size = self:fitting(rect.label, BOLD, 20 * self.scale, rect.w - px(12))
        self:paint_text(bb, rect.label, BOLD, size, rect.x, rect.y, rect.w, rect.h, BLACK)
    end
end

function ClockScreen:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(0, 0, self.width, self.height, WHITE)
    local ok, err = pcall(function()
        self:paint_side(bb, TOP)
        self:paint_side(bb, BOTTOM)
        self:paint_bar(bb)
    end)
    if not ok then
        logger.warn("Ink Knight: could not draw the clock", err)
        bb:paintRect(0, 0, self.width, self.bar.y, WHITE)
        self:paint_text(bb, self.s.unexpected_error, REGULAR, 18 * self.scale, 0, 0, self.width, self.bar.y, BLACK)
    end
    StatusStrip.paint(bb, self.width, self.height)
end

function ClockScreen:strip_region()
    return StatusStrip.region(self.width, self.height)
end

-- what: "time" for the second of the side to move, which only touches its half, with "fast"; otherwise the halves
-- and the buttons, counted for a flash now and then.
function ClockScreen:redraw(what)
    if what == "time" and self.clock.active then
        local rect = self.halves[self.clock.active]
        Sleep.dirty(self, function() return "fast", Geom:new(rect) end)
        return
    end
    local mode = self.refresh_count:mode("clock")
    Sleep.dirty(self, function() return mode, self.dimen end)
end

function ClockScreen:running()
    return ChessClock.running(self.clock) and not self.paused
end

function ClockScreen:schedule()
    Sleep.unschedule(self, self.tick_callback)
    if self:running() then
        Sleep.schedule(self, ChessClock.next_change(self.clock, socket.gettime()), self.tick_callback)
    end
    Awake.set(self:running(), self)
end

function ClockScreen:tick()
    if not self:running() then
        return
    end
    if ChessClock.check(self.clock, socket.gettime()) then
        self:schedule()
        self:redraw()
        return
    end
    self:redraw("time")
    self:schedule()
end

function ClockScreen:press(side)
    local clock, now = self.clock, socket.gettime()
    if self.paused or clock.flagged or ChessClock.check(clock, now) then
        self:schedule()
        self:redraw()
        return
    end
    if not clock.active then
        ChessClock.start(clock, ChessClock.other(side), now)
    elseif clock.active == side then
        ChessClock.press(clock, now)
    else
        return
    end
    self:schedule()
    self:redraw()
end

function ClockScreen:set_paused(paused)
    local now = socket.gettime()
    self.paused = paused
    if paused then
        ChessClock.pause(self.clock, now)
    else
        ChessClock.resume(self.clock, now)
    end
    self:schedule()
    self:redraw()
end

function ClockScreen:restart()
    local function reset()
        self.clock = ChessClock.new(ChessClock.parse(self.preset))
        self.paused = false
        self:schedule()
        self:redraw()
    end
    -- Nothing to lose before the first tap or after a flag.
    if not self.clock.active or self.clock.flagged then
        reset()
        return
    end
    local was_paused = self.paused
    self:set_paused(true)
    self.app:ask{
        title = self.s.chess_clock, text = self.s.clock_restart_question, ok_text = self.s.clock_restart,
        on_ok = reset,
        on_cancel = function() self:set_paused(was_paused) end,
    }
end

function ClockScreen:onTap(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    for _, rect in ipairs(self:button_rects()) do
        if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
            self:on_button(rect.id)
            return true
        end
    end
    for side, rect in pairs(self.halves) do
        if y >= rect.y and y < rect.y + rect.h then
            self:press(side)
            return true
        end
    end
    return true
end

function ClockScreen:on_button(id)
    if id == "back" then
        self:onBack()
    elseif id == "pause" then
        self:set_paused(true)
    elseif id == "resume" then
        self:set_paused(false)
    elseif id == "restart" then
        self:restart()
    end
end

-- With the clock running, leaving asks first, as a game with a clock does.
function ClockScreen:onBack()
    if not self:running() then
        UIManager:close(self)
        return true
    end
    self:set_paused(true)
    self.app:ask{
        title = self.s.chess_clock, text = self.s.clock_leave_question, ok_text = self.s.clock_leave,
        on_ok = function() UIManager:close(self) end,
        on_cancel = function() self:set_paused(false) end,
    }
    return true
end

-- Asleep, the players cannot see the clock, so it waits for Continue.
function ClockScreen:onSuspend()
    if self:running() then
        self:set_paused(true)
    end
end

function ClockScreen:onResume()
    self.refresh_count:reset()
end

function ClockScreen:onClose(arg)
    if not (arg and arg.keep_screensaver) then
        UIManager:close(self)
    end
end

ClockScreen.onSetRotationMode = Portrait.ignore_rotation

function ClockScreen:onCloseWidget()
    Sleep.unschedule(self)
    Awake.set(false, self)
    if self.top_buffer then
        self.top_buffer:free()
        self.top_buffer = nil
    end
    Portrait.close(self)
    UIManager:setDirty(nil, Page.refresh_mode())
end

-- A layout of its own, so it opens with a flash.
function ClockScreen:onShow()
    self.refresh_count:reset()
    UIManager:setDirty(self, self.refresh_count:mode("clock"))
    return true
end

return ClockScreen
