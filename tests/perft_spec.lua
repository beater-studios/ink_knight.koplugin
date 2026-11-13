-- The positions of tests/perft (from scalachess, MIT): each depth's count of move sequences must match, so any mistake
-- in the rules shows. Only the depths up to PERFT_LIMIT sequences run: 20000 by default, about 3 s on a Kindle, where
-- the install runs the tests; tools/check.sh runs them to 1000000, and PERFT_LIMIT=10000000 runs them deep. The first
-- depth listed always runs, so no limit turns the file into a pass that checked nothing.
-- Positions with the castling of Chess960, which the plugin does not play, are left out.
package.path = "./?.lua;" .. package.path
local Chess = require("ink_knight/chess")
local Editor = require("ink_knight/editor")

local LIMIT = tonumber(os.getenv("PERFT_LIMIT")) or 20000
-- The positions of standard chess in the file: a change of the file that loses one fails here.
local STANDARD_POSITIONS = 12

local passed, failed, skipped = 0, 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAILED: " .. name .. "\n  " .. tostring(err))
    end
end

local function read(path)
    local cases, current = {}, nil
    for line in io.lines(path) do
        local id = line:match("^id%s+(%S+)")
        local epd = line:match("^epd%s+(.+)$")
        local depth, count = line:match("^perft%s+(%d+)%s+(%d+)")
        if id then
            current = { id = id, counts = {} }
            cases[#cases + 1] = current
        elseif epd and current then
            current.epd = epd
        elseif depth and current then
            -- Some positions skip depths (a forced line is counted far down), so the depths are kept with their count.
            current.counts[#current.counts + 1] = { depth = tonumber(depth), count = tonumber(count) }
        end
    end
    return cases
end

-- Every right the position states has its king and rook where standard castling wants them; otherwise it is the
-- castling of Chess960.
local function standard(position)
    local possible = Editor.possible_castling(position)
    for letter in position.castling:gmatch(".") do
        if not possible:find(letter, 1, true) then
            return false
        end
    end
    return true
end

local ran = 0
for _, case in ipairs(read("tests/perft/tricky.perft")) do
    local position = Chess.parse_fen(case.epd or "")
    if not position then
        test("perft " .. case.id, function() error("cannot read the position " .. tostring(case.epd), 0) end)
    elseif not standard(position) then
        skipped = skipped + 1
    else
        ran = ran + 1
        test("perft " .. case.id, function()
            table.sort(case.counts, function(a, b) return a.depth < b.depth end)
            assert(#case.counts > 0, "no count to compare")
            for index, item in ipairs(case.counts) do
                if index > 1 and item.count > LIMIT then
                    break
                end
                local got = Chess.perft(position, item.depth)
                if got ~= item.count then
                    error(string.format("depth %d: expected %d, got %d", item.depth, item.count, got), 0)
                end
            end
        end)
    end
end
test("the file has its positions of standard chess", function()
    if ran ~= STANDARD_POSITIONS then
        error(string.format("expected %d, ran %d", STANDARD_POSITIONS, ran), 0)
    end
end)

print(string.format("%d passed, %d failed (%d positions with the castling of Chess960 left out)", passed, failed, skipped))
os.exit(failed == 0 and 0 or 1)
