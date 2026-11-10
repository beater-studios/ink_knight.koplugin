-- Pattern "fuzz". This file is copied unchanged into every
-- plugin as tools/koreader/fuzz.lua: change the pattern first, then copy it again.
--
-- Random touches through the real screens of the plugin, inside the desktop KOReader, with a paint after
-- each one, so errors in the touch handlers and in painting both show up. Touches go through
-- UIManager:sendEvent, the same path as a finger on the device, so they reach whatever window is on top,
-- and the tasks that are already due (nextTick, tickAfterNext, a scheduleIn that has expired) run before
-- the paint, as in the KOReader loop between two touches.
-- The plugin script loads this file first (it prepares KOReader), opens its screen and says what each
-- run starts from; this module sends the touches, catches the errors and prints how to repeat them.
--
--   local Fuzz = dofile(os.getenv("PLUGIN_DIR") .. "/tools/koreader/fuzz.lua")
--   local Screen = require("<id>/ui/screen")
--   local screen = Screen:new{ plugin_dir = Fuzz.plugin_dir }
--   local fuzz = Fuzz.new{ screen = screen }
--   fuzz:run{ label = "home", setup = function() screen:show_home() end }
--   fuzz:finish()
--
-- Run it with tools/koreader/run_headless.sh. Environment: ACTIONS (touches per run), SEED, ONLY (only the
-- run with this exact label), MAX_ERRORS (stops at this many errors).
local plugin_dir = assert(os.getenv("PLUGIN_DIR"), "fuzz: run it with tools/koreader/run_headless.sh")

if not G_reader_settings then
    require("setupkoenv")
    local DataStorage = require("datastorage")
    G_defaults = require("luadefaults"):open()
    G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
    package.path = plugin_dir .. "/?.lua;" .. package.path
    require("document/canvascontext"):init(require("device"))
    require("ui/uimanager"):init()
end

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local time = require("ui/time")

local Fuzz = { plugin_dir = plugin_dir }
Fuzz.__index = Fuzz

local DIRECTIONS = { "north", "south", "east", "west" }

-- Park-Miller: the same seed gives the same touches on any machine.
local function make_random(seed)
    local state = math.floor(seed) % 2147483646 + 1
    return function(a, b)
        state = state * 48271 % 2147483647
        local unit = (state - 1) / 2147483646
        if not a then
            return unit
        end
        return a + math.floor(unit * (b - a + 1))
    end
end

local function env_number(name)
    return tonumber(os.getenv(name) or "")
end

-- opts: screen (the plugin window, required), actions (touches per run, 250), seed (1), max_errors (20),
-- weights ({ tap = 80, hold = 15, swipe = 5 }). The environment variables win over opts.
function Fuzz.new(opts)
    local self = setmetatable({}, Fuzz)
    self.screen = assert(opts.screen, "fuzz: the plugin screen is required")
    self.actions = env_number("ACTIONS") or opts.actions or 250
    self.seed = env_number("SEED") or opts.seed or 1
    self.max_errors = env_number("MAX_ERRORS") or opts.max_errors or 20
    self.only = os.getenv("ONLY")
    self.weights = opts.weights or { tap = 80, hold = 15, swipe = 5 }
    self.total, self.errors, self.runs, self.ran = 0, 0, 0, 0
    self.random = make_random(self.seed)
    local size = Device.screen:getSize()
    self.width, self.height = size.w, size.h
    if not UIManager:isWidgetShown(self.screen) then
        UIManager:show(self.screen)
    end
    UIManager:forceRePaint()
    return self
end

function Fuzz:showing()
    return UIManager:isWidgetShown(self.screen)
end

-- Closes every window above the plugin screen (dialogs, menus, keyboards), or all of them if the screen
-- itself was closed.
function Fuzz:close_above()
    local stack = UIManager._window_stack
    local shown = self:showing()
    while #stack > 0 and (not shown or stack[#stack].widget ~= self.screen) do
        UIManager:close(stack[#stack].widget)
    end
end

-- Runs the tasks that are due, as the KOReader loop does between two inputs, then paints. Tasks scheduled
-- for later (a clock, a message that closes itself) only run when their time comes.
function Fuzz:settle()
    UIManager:_checkTasks()
    UIManager:forceRePaint()
end

-- Sends one gesture as KOReader would, then settles: the hit areas of many widgets are only known after
-- a paint, so the next touch must find the screen already updated.
function Fuzz:gesture(ges)
    ges.time = ges.time or time.now()
    UIManager:sendEvent(Event:new("Gesture", ges))
    self:settle()
end

local function point(x, y)
    return Geom:new{ x = x, y = y, w = 0, h = 0 }
end

function Fuzz:tap(x, y)
    self:gesture{ ges = "tap", pos = point(x, y) }
end

function Fuzz:hold(x, y)
    self:gesture{ ges = "hold", pos = point(x, y) }
    self:gesture{ ges = "hold_release", pos = point(x, y) }
end

-- direction: north, south, east or west (where the finger goes). distance in pixels.
function Fuzz:swipe(x, y, direction, distance)
    local dx = direction == "east" and distance or direction == "west" and -distance or 0
    local dy = direction == "south" and distance or direction == "north" and -distance or 0
    self:gesture{
        ges = "swipe",
        pos = point(x, y),
        end_pos = point(x + dx, y + dy),
        direction = direction,
        multiswipe_directions = direction,
        distance = distance,
    }
end

function Fuzz:point()
    return self.random(0, self.width - 1), self.random(0, self.height - 1)
end

-- One random touch at a random point, by the weights.
function Fuzz:touch()
    local x, y = self:point()
    local w = self.weights
    local pick = self.random(1, (w.tap or 0) + (w.hold or 0) + (w.swipe or 0))
    if pick <= (w.tap or 0) then
        self:tap(x, y)
    elseif pick <= (w.tap or 0) + (w.hold or 0) then
        self:hold(x, y)
    else
        self:swipe(x, y, DIRECTIONS[self.random(1, 4)], self.random(40, math.max(41, math.floor(self.width / 2))))
    end
end

-- run: label (names the run in the report), setup(fuzz) (puts the screen where the run starts; may return
-- a new screen), again(fuzz) (optional: true when setup must run again before the next step, like when
-- the run left the part of the plugin it tests), step(fuzz, i) (optional: one action; a random touch by
-- default). setup also runs again after an error and when the plugin screen was closed.
function Fuzz:run(run)
    self.runs = self.runs + 1
    if self.only and run.label ~= self.only then
        return
    end
    if self.errors >= self.max_errors then
        return
    end
    self.ran = self.ran + 1
    self.random = make_random(self.seed * 1000 + self.runs)
    local errors_before = self.errors
    local fresh = true
    for i = 1, self.actions do
        self.total = self.total + 1
        local ok, err = xpcall(function()
            if fresh or not self:showing() or (run.again and run.again(self)) then
                fresh = false
                self:close_above()
                self.screen = run.setup and run.setup(self) or self.screen
                if not self:showing() then
                    UIManager:show(self.screen)
                end
                self:settle()
            end
            if run.step then
                run.step(self, i)
            else
                self:touch()
            end
            self:settle()
        end, debug.traceback)
        if not ok then
            self.errors = self.errors + 1
            fresh = true
            print(string.format("ERROR in %q, step %d (repeat with SEED=%d ACTIONS=%d ONLY=%q):\n%s",
                run.label, i, self.seed, i, run.label, tostring(err)))
            pcall(self.close_above, self)
            if self.errors >= self.max_errors then
                print("too many errors, stopping")
                return
            end
        end
    end
    print(string.format("%s: %d actions, %d errors", run.label, self.actions, self.errors - errors_before))
end

-- Prints the totals and exits with 1 if anything failed, or if no run matched ONLY.
function Fuzz:finish()
    print(string.format("%d actions in %d of %d runs, %d errors", self.total, self.ran, self.runs, self.errors))
    UIManager:close(self.screen)
    if self.ran == 0 then
        print(string.format("no run was made%s", self.only and string.format(" (no label is %q)", self.only) or ""))
        os.exit(1)
    end
    os.exit(self.errors == 0 and 0 or 1)
end

return Fuzz
