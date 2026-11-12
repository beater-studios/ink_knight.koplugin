package.path = "./?.lua;" .. package.path
local Chess = require("ink_knight/chess")
local ChessClock = require("ink_knight/chess_clock")
local State = require("ink_knight/state")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAILED: " .. name .. "\n  " .. tostring(err))
    end
end
local function eq(actual, expected)
    if actual ~= expected then
        error(string.format("expected %s, got %s", tostring(expected), tostring(actual)), 2)
    end
end

test("a preset is minutes and an increment in seconds", function()
    local seconds, increment = ChessClock.parse("5+3")
    eq(seconds, 300); eq(increment, 3)
    eq(ChessClock.parse("five"), nil)
    for _, preset in ipairs(ChessClock.PRESETS) do
        assert(ChessClock.parse(preset), preset)
    end
end)

test("the side to move loses time, and gets the increment after moving", function()
    local clock = ChessClock.new(300, 3)
    ChessClock.start(clock, "b", 0)
    eq(ChessClock.left(clock, "b", 10), 290); eq(ChessClock.left(clock, "w", 10), 300)
    eq(ChessClock.press(clock, 10), true)
    eq(clock.left.b, 293); eq(clock.moves.b, 1); eq(clock.active, "w")
    eq(ChessClock.left(clock, "w", 15), 295)
end)

test("a move taken back gives its side the turn again without the increment it had added", function()
    local clock = ChessClock.new(300, 3)
    ChessClock.start(clock, "b", 0)
    ChessClock.press(clock, 10)
    eq(clock.left.b, 293)
    ChessClock.pause(clock, 15)
    ChessClock.take_back(clock, "b")
    eq(clock.left.b, 290); eq(clock.moves.b, 0); eq(clock.active, "b")
    eq(clock.left.w, 295)
end)

test("the next redraw falls when the time shown changes", function()
    local clock = ChessClock.new(300, 0)
    ChessClock.start(clock, "w", 0)
    eq(ChessClock.next_change(clock, 0), 1)
    assert(math.abs(ChessClock.next_change(clock, 0.3) - 0.7) < 1e-9)
    eq(ChessClock.next_change(clock, 299.99) >= 0.05, true)
end)

test("a pause stops the time of the side to move", function()
    local clock = ChessClock.new(60, 0)
    ChessClock.start(clock, "w", 0)
    ChessClock.pause(clock, 20)
    eq(ChessClock.running(clock), false)
    eq(ChessClock.left(clock, "w", 1000), 40)
    ChessClock.resume(clock, 1000)
    eq(ChessClock.left(clock, "w", 1010), 30)
end)

test("a side out of time is flagged, and stays so", function()
    local clock = ChessClock.new(60, 5)
    ChessClock.start(clock, "w", 0)
    eq(ChessClock.check(clock, 59), nil)
    eq(ChessClock.check(clock, 61), "w")
    eq(ChessClock.press(clock, 62), false)
    eq(clock.left.w, 0); eq(clock.moves.w, 0); eq(ChessClock.running(clock), false)
    ChessClock.resume(clock, 70)
    eq(ChessClock.running(clock), false)
end)

test("a saved clock comes back paused, and a broken one is left out", function()
    local clock = ChessClock.new(600, 5)
    ChessClock.start(clock, "b", 0)
    ChessClock.press(clock, 30)
    local saved = ChessClock.save(clock, 40)
    eq(saved.w, 590); eq(saved.b, 575); eq(saved.active, "w"); eq(saved.moves_b, 1)
    local back = ChessClock.restore(saved)
    eq(back.active, "w"); eq(back.since, nil); eq(ChessClock.left(back, "w", 999), 590)
    eq(ChessClock.restore({ initial = 600, increment = 5, w = -1, b = 10 }), nil)
    eq(ChessClock.restore("x"), nil)
end)

test("the time reads as minutes and seconds", function()
    eq(ChessClock.text(300), "5:00"); eq(ChessClock.text(9.2), "0:10"); eq(ChessClock.text(-3), "0:00"); eq(ChessClock.text(3700), "1:01:40")
end)

test("running out of time against a side that cannot mate is a draw", function()
    local function can(fen, color) return Chess.can_mate(Chess.parse_fen(fen), color) end
    eq(can("8/8/8/8/8/8/8/K6k w - - 0 1", "w"), false)
    eq(can("8/8/8/8/8/8/8/KN5k w - - 0 1", "w"), false)
    eq(can("8/8/8/8/8/8/7p/KN5k w - - 0 1", "w"), true)
    eq(can("8/8/8/8/8/8/8/KNN4k w - - 0 1", "w"), true)
    eq(can("8/8/8/8/8/8/8/KR5k w - - 0 1", "w"), true)
    eq(can("8/8/8/8/8/8/P7/K6k w - - 0 1", "w"), true)
end)

test("a game between two people keeps its clock only with a preset that exists", function()
    local saved = { version = 1, moves = "e2e4", flipped = false, clock_preset = "5+3",
        clock = { initial = 300, increment = 3, w = 300, b = 280, active = "b", moves_w = 0, moves_b = 0 } }
    local read = State.read_game(saved, true)
    eq(read.clock_preset, "5+3"); eq(read.clock.b, 280); eq(read.clock.active, "b")
    saved.clock_preset = "7+7"
    read = State.read_game(saved, true)
    eq(read.clock, nil); eq(read.clock_preset, nil); eq(read.moves, "e2e4")
    eq(State.read_game({ version = 1, moves = "e2e4" }, true).clock, nil)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
