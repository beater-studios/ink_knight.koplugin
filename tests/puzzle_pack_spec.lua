package.path = "./?.lua;" .. package.path
local Pack = require("ink_knight/puzzle_pack")
local Puzzles = require("ink_knight/puzzles")
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

test("every level has its puzzles, in its ratings, with no id twice", function()
    eq(Pack.per_level(), Pack.GENERATED_PER_LEVEL)
    eq(Pack.total(), Pack.GENERATED_PER_LEVEL * #Pack.LEVELS)
    local seen = {}
    for _, level in ipairs(Pack.LEVELS) do
        local list = Pack.list(level)
        eq(#list, Pack.GENERATED_PER_LEVEL)
        local range = Pack.RANGES[level]
        for _, entry in ipairs(list) do
            assert(type(entry[1]) == "string" and entry[1]:match("^%w+$"), level .. ": bad id")
            assert(not seen[entry[1]], "repeated id " .. entry[1])
            seen[entry[1]] = true
            assert(entry[4] >= range[1] and entry[4] <= range[2], level .. ": rating " .. entry[4] .. " out of its level")
        end
    end
end)

-- The reader plays the expected move each time and the replies come, as on the screen. All of them, since every
-- package has the first ones of the same files.
test("every puzzle can be solved to the end by the puzzle rules", function()
    for _, level in ipairs(Pack.LEVELS) do
        for index, entry in ipairs(Pack.list(level)) do
            local puzzle = Pack.prepare(entry, level, index)
            local session = assert(Puzzles.new_session(puzzle), entry[1] .. ": the start cannot be played")
            eq(session.my_color, Pack.reader_color(entry[2]))
            while not session.solved do
                local outcome = Puzzles.try_move(session, Puzzles.hint(session))
                assert(outcome ~= "wrong", entry[1] .. ": the expected move was refused")
                if outcome == "correct" then
                    assert(Puzzles.play_reply(session), entry[1] .. ": the reply cannot be played")
                    if session.step > #puzzle.solution then
                        session.solved = true
                    end
                end
            end
        end
    end
end)

test("the next puzzle keeps the color chosen and goes round at the end", function()
    local list = Pack.list("normal")
    local first = Pack.puzzle("normal", 1, "any")
    eq(first.id, list[1][1]); eq(first.pack, "normal"); eq(first.pack_index, 1)
    local reader = Pack.reader_color(list[1][2])
    local other = reader == "w" and "black" or "white"
    local found = Pack.puzzle("normal", 1, other)
    assert(found.pack_index > 1, "a puzzle of the other color should be skipped")
    eq(Pack.reader_color(found.fen) == "w", other == "white")
    eq(Pack.next_index("normal", #list), 1)
    eq(Pack.next_index("normal", 5), 6)
    eq(Pack.puzzle("normal", #list + 1, "any").pack_index, 1)
end)

test("the progress of each level is read back without what makes no sense", function()
    local progress = State.read_pack_progress({ easiest = 12, normal = 1.5, harder = 0, hardest = "3", other = 4 })
    eq(progress.easiest, 12); eq(progress.normal, nil); eq(progress.harder, nil); eq(progress.hardest, nil); eq(progress.other, nil)
    eq(next(State.read_pack_progress(nil)), nil)
end)

test("a package keeps the first puzzles of each level, the same ones in every size", function()
    local folder = os.tmpname()
    os.remove(folder)
    -- os.execute gives 0 in Lua 5.1 and true with the Lua 5.2 behavior some LuaJIT builds turn on.
    local function run(command)
        local result = os.execute(command)
        assert(result == 0 or result == true, "failed: " .. command)
    end
    run("mkdir -p " .. folder .. " && cp ink_knight/data/puzzles/*.lua " .. folder)
    run("luajit tools/puzzles/trim.lua " .. folder .. " 3")
    local manifest = dofile(folder .. "/manifest.lua")
    eq(manifest.per_level, 3)
    for _, level in ipairs(Pack.LEVELS) do
        local cut = dofile(folder .. "/" .. level .. ".lua")
        eq(#cut, 3)
        for index = 1, 3 do
            eq(cut[index][1], Pack.list(level)[index][1])
        end
    end
    run("rm -r " .. folder)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
