-- Coordinate training on the board, with no coordinates drawn. The square to find shows large in the box of the
-- top bar; to name a square, it is marked and the names to choose from are the buttons. Only the bars change with
-- the clock, as with the clocks of a game, and the run pauses while the device sleeps.
local UIManager = require("ui/uimanager")
local socket = require("socket")

local BoardScreen = require("ink_knight/ui/board_screen")
local Chess = require("ink_knight/chess")
local Coordinates = require("ink_knight/coordinates")
local Game = require("ink_knight/game")
local Sleep = require("ink_knight/sleep")

local CoordinatesScreen = {}
CoordinatesScreen.__index = CoordinatesScreen

-- Parsed once: the clock redraws the board state every second.
local WITH_PIECES = Chess.parse_fen(Chess.START_FEN)
local EMPTY = Chess.parse_fen("8/8/8/8/8/8/8/8 w - - 0 1")

-- opts.on_closed: what to do when the screen closes, such as showing a new best on the page underneath.
function CoordinatesScreen.open(app, opts)
    opts = opts or {}
    local self = setmetatable({ app = app, s = app.strings, phase = "ready" }, CoordinatesScreen)
    self.tick_callback = function() self:tick() end
    self.resume_callback = function() self:restart_clock() end
    self.screen = BoardScreen:new{
        state = {},
        coordinates = false,
        on_square = function(square) self:on_square(square) end,
        on_button = function(button) self:on_button(button) end,
        on_suspend = function() self:pause() end,
        on_resume = function() self:resume() end,
        on_closed = function()
            self.is_closed = true
            if opts.on_closed then
                opts.on_closed()
            end
        end,
        broken_text = app.strings.unexpected_error,
    }
    self:choose_side()
    UIManager:show(self.screen)
    self:render("full")
    return self
end

function CoordinatesScreen:choose_side()
    local side = self.app:option("coordinates_side")
    self.color = side == "black" and "b" or side == "white" and "w" or (math.random(2) == 1 and "w" or "b")
end

function CoordinatesScreen:timed()
    return self.app:option("coordinates_time") == "seconds"
end

function CoordinatesScreen:seconds_left()
    return math.max(0, self.deadline - socket.gettime())
end

function CoordinatesScreen:start()
    -- The side drawn when the screen opened is the one shown, so it only changes for the next run.
    if self.phase == "over" then
        self:choose_side()
    end
    self.mode = self.app:option("coordinates_mode")
    self.session = Coordinates.new(self.mode, self.color)
    self.phase, self.feedback, self.new_record = "running", nil, false
    if self:timed() then
        self.deadline = socket.gettime() + Coordinates.SECONDS
        self:schedule_tick()
    end
    self:render()
end

-- Each second, or sooner when less is left, so the run ends on time.
function CoordinatesScreen:schedule_tick()
    Sleep.schedule(self.screen, math.max(0.05, math.min(1, self:seconds_left())), self.tick_callback)
end

function CoordinatesScreen:time_is_up()
    return self.phase == "running" and self:timed() and not self.paused_left and self:seconds_left() <= 0
end

function CoordinatesScreen:tick()
    if self.phase ~= "running" or self.is_closed then
        return
    end
    if self:time_is_up() then
        self:finish()
        return
    end
    self:render("clock")
    self:schedule_tick()
end

function CoordinatesScreen:finish()
    Sleep.unschedule(self.screen, self.tick_callback)
    self.phase = "over"
    if self:timed() then
        self.new_record = self.app:keep_coordinate_score(self.mode, self.color, self.session.score)
    end
    self:render()
end

-- A run with a clock waits while the device sleeps, with the time it had.
function CoordinatesScreen:pause()
    if self.phase == "running" and self:timed() then
        self.paused_left = self:seconds_left()
        Sleep.unschedule(self.screen, self.tick_callback)
    end
end

-- Resume can come while the sleep screen still waits for a tap; the clock restarts only once it is gone, when the
-- sleep module lets the scheduled call run.
function CoordinatesScreen:resume()
    if self.paused_left then
        Sleep.schedule(self.screen, 0, self.resume_callback)
    end
end

function CoordinatesScreen:restart_clock()
    if self.paused_left and self.phase == "running" then
        self.deadline = socket.gettime() + self.paused_left
        self.paused_left = nil
        self:schedule_tick()
        self:render("clock")
    end
end

function CoordinatesScreen:status_text()
    local s = self.s
    if self.phase == "ready" then
        return s.coord_ready
    elseif self.phase == "over" then
        return string.format(self.new_record and s.coord_over_record or s.coord_over, self.session.score)
    end
    return self.feedback or ""
end

function CoordinatesScreen:buttons()
    local s = self.s
    local buttons = { { id = "back", label = s.back } }
    if self.phase ~= "running" then
        buttons[#buttons + 1] = { id = "start", label = self.phase == "over" and s.coord_again or s.coord_start }
        return buttons
    end
    for index, name in ipairs(self.session.choices or {}) do
        buttons[#buttons + 1] = { id = "choice" .. index, label = name }
    end
    if not self:timed() then
        buttons[#buttons + 1] = { id = "stop", label = s.coord_stop }
    end
    return buttons
end

function CoordinatesScreen:render(what)
    if self.is_closed then
        return
    end
    local s, session = self.s, self.session
    local running = self.phase == "running"
    local find = running and session.mode == "find"
    local position = self.app:option("coordinates_pieces") and WITH_PIECES or EMPTY
    local clock
    if running and self:timed() then
        clock = Game.format_clock((self.paused_left or self:seconds_left()) * 1000)
    end
    self.screen:show({
        flipped = self.color == "b",
        position = position,
        selected = running and session.mode == "name" and session.target or nil,
        top = {
            name = running and (find and s.coord_prompt_find or s.coord_prompt_name) or s.coordinates,
            clock = find and Chess.square_name(session.target) or nil,
            active = find,
        },
        bottom = {
            name = string.format(s.coord_score, session and session.score or 0),
            clock = clock,
            active = running,
        },
        status = self:status_text(),
        buttons = self:buttons(),
    }, what)
end

-- A wrong answer says which square or name it was, so a second wrong tap still changes the screen.
function CoordinatesScreen:answer(value, shown)
    if self:time_is_up() then
        self:finish()
        return
    end
    local right = Coordinates.answer(self.session, value)
    self.feedback = right and self.s.coord_right or string.format(self.session.mode == "find" and self.s.coord_wrong_find or self.s.coord_wrong_name, shown)
    self:render()
end

function CoordinatesScreen:on_square(square)
    if self.phase == "running" and self.session.mode == "find" then
        self:answer(square, Chess.square_name(square))
    end
end

function CoordinatesScreen:on_button(button)
    if button == "back" then
        UIManager:close(self.screen)
    elseif button == "start" then
        self:start()
    elseif button == "stop" then
        self:finish()
    elseif self.phase == "running" and button:match("^choice%d$") then
        local name = self.session.choices[tonumber(button:sub(7))]
        if name then
            self:answer(name, name)
        end
    end
end

return CoordinatesScreen
