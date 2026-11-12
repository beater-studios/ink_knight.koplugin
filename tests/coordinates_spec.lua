package.path = "./?.lua;" .. package.path
local Chess = require("ink_knight/chess")
local Coordinates = require("ink_knight/coordinates")
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

-- Draws in a fixed order, so the tests know the squares.
local function draws(...)
    local list, index = { ... }, 0
    return function()
        index = index + 1
        return list[(index - 1) % #list + 1]
    end
end

test("a right square scores and moves on, a wrong one keeps the same square", function()
    local session = Coordinates.new("find", "w", draws(Chess.square_from_name("e4"), Chess.square_from_name("e4"), Chess.square_from_name("a1")))
    eq(Chess.square_name(session.target), "e4")
    eq(Coordinates.answer(session, Chess.square_from_name("d4")), false)
    eq(session.score, 0); eq(session.misses, 1); eq(Chess.square_name(session.target), "e4")
    eq(Coordinates.answer(session, Chess.square_from_name("e4")), true)
    eq(session.score, 1)
    -- The same square is never asked twice in a row.
    eq(Chess.square_name(session.target), "a1")
    eq(session.choices, nil)
end)

test("to name a square, the right name is among four, in the order of the names", function()
    for seed = 1, 50 do
        math.randomseed(seed)
        local session = Coordinates.new("name", "b")
        eq(#session.choices, Coordinates.CHOICES)
        local seen, has_target = {}, false
        for index, name in ipairs(session.choices) do
            assert(not seen[name], "a name twice: " .. name)
            seen[name] = true
            has_target = has_target or name == Chess.square_name(session.target)
            if index > 1 then
                assert(session.choices[index - 1] < name, "the names should be in order")
            end
        end
        assert(has_target, "the right name should be offered")
        eq(Coordinates.answer(session, Chess.square_name(session.target)), true)
        eq(#session.choices, Coordinates.CHOICES)
    end
end)

test("each mode and side has its own record", function()
    eq(Coordinates.record_key("find", "w"), "find_w"); eq(Coordinates.record_key("name", "b"), "name_b")
end)

test("the options and the records are read back without what makes no sense", function()
    eq(State.option("coordinates_mode", "other"), "find")
    eq(State.option("coordinates_time", "none"), "none")
    eq(State.option("coordinates_pieces", nil), true)
    local records = State.read_coordinate_records({ find_w = 21, find_b = -1, name_w = 2.5, name_b = "4", other = 9 })
    eq(records.find_w, 21); eq(records.find_b, nil); eq(records.name_w, nil); eq(records.name_b, nil); eq(records.other, nil)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
