-- A chess clock with an increment, for the game between two people and for the clock of a physical board. The time
-- is given by the caller, in seconds, so the tests can move it. Sides are "w" and "b". No KOReader here.
local Game = require("ink_knight/game")

local Clock = {}

-- Minutes and increment in seconds, as Lichess writes them: 3+2 is three minutes and two seconds a move.
Clock.PRESETS = { "3+2", "5+0", "5+3", "10+0", "10+5", "15+10", "30+0", "30+20" }

function Clock.parse(preset)
    local minutes, increment = tostring(preset):match("^(%d+)%+(%d+)$")
    if not minutes then
        return nil
    end
    return tonumber(minutes) * 60, tonumber(increment)
end

function Clock.new(seconds, increment)
    return { initial = seconds, increment = increment, left = { w = seconds, b = seconds }, moves = { w = 0, b = 0 } }
end

function Clock.other(side)
    return side == "w" and "b" or "w"
end

function Clock.left(clock, side, now)
    local left = clock.left[side]
    if clock.active == side and clock.since then
        left = left - (now - clock.since)
    end
    return math.max(0, left)
end

function Clock.running(clock)
    return clock.active ~= nil and clock.since ~= nil and not clock.flagged
end

-- The side whose time ran out, or nil. It stays out once it happened.
function Clock.check(clock, now)
    if not clock.flagged and clock.active and Clock.left(clock, clock.active, now) <= 0 then
        clock.left[clock.active] = 0
        clock.flagged, clock.since = clock.active, nil
    end
    return clock.flagged
end

-- side starts to think: the first press of a game.
function Clock.start(clock, side, now)
    clock.active, clock.since = side, now
end

-- The side thinking has moved: its time stops with the increment added, and the other side's starts. Returns false
-- when its time had already run out.
function Clock.press(clock, now)
    if Clock.check(clock, now) or not clock.active then
        return false
    end
    local side = clock.active
    clock.left[side] = Clock.left(clock, side, now) + clock.increment
    clock.moves[side] = clock.moves[side] + 1
    clock.active, clock.since = Clock.other(side), clock.since and now or nil
    return true
end

-- A move taken back: side moves again, without the increment its move had added.
function Clock.take_back(clock, side)
    if clock.moves[side] > 0 then
        clock.moves[side] = clock.moves[side] - 1
        clock.left[side] = math.max(0, clock.left[side] - clock.increment)
    end
    clock.active = side
end

-- How long until the time shown changes: the rest of the current second, so each redraw falls on the second.
function Clock.next_change(clock, now)
    local left = Clock.left(clock, clock.active, now)
    local rest = left - math.floor(left)
    return math.max(0.05, rest > 0.001 and rest or 1)
end

function Clock.pause(clock, now)
    if Clock.running(clock) then
        clock.left[clock.active] = Clock.left(clock, clock.active, now)
        clock.since = nil
    end
end

function Clock.resume(clock, now)
    if clock.active and not clock.since and not clock.flagged then
        clock.since = now
    end
end

-- What is kept between openings, always paused: { initial, increment, w, b, active, flagged, moves_w, moves_b }.
function Clock.save(clock, now)
    return {
        initial = clock.initial, increment = clock.increment,
        w = Clock.left(clock, "w", now), b = Clock.left(clock, "b", now),
        active = clock.active, flagged = clock.flagged,
        moves_w = clock.moves.w, moves_b = clock.moves.b,
    }
end

local function seconds(value)
    return type(value) == "number" and value >= 0 and value < 100000 and value or nil
end

local function count(value)
    return type(value) == "number" and value >= 0 and value == math.floor(value) and value or 0
end

-- A saved clock, paused, or nil when it does not make sense.
function Clock.restore(saved)
    if type(saved) ~= "table" or not seconds(saved.initial) or not seconds(saved.increment) or not seconds(saved.w)
        or not seconds(saved.b) then
        return nil
    end
    local clock = Clock.new(saved.initial, saved.increment)
    clock.left.w, clock.left.b = saved.w, saved.b
    clock.active = (saved.active == "w" or saved.active == "b") and saved.active or nil
    clock.flagged = (saved.flagged == "w" or saved.flagged == "b") and saved.flagged or nil
    clock.moves.w, clock.moves.b = count(saved.moves_w), count(saved.moves_b)
    return clock
end

-- Minutes and seconds, or hours past an hour, as the clocks of a game.
function Clock.text(left)
    return Game.format_clock(math.max(0, left) * 1000)
end

return Clock
