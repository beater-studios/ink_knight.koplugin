-- The positions of tests/perft (from scalachess, MIT), of standard chess and of Chess960: each depth's count of move
-- sequences must match, so any mistake in the rules shows. Only the depths up to PERFT_LIMIT sequences run: 20000 by
-- default, about 3 s on a Kindle, where the install runs the tests; tools/check.sh runs them to 1000000, and
-- PERFT_LIMIT=10000000 runs them deep. The first depth listed always runs, so no limit turns a file into a pass that
-- checked nothing.
package.path = "./?.lua;" .. package.path
local Chess = require("ink_knight/chess")

local LIMIT = tonumber(os.getenv("PERFT_LIMIT")) or 20000
-- The 960 starting positions of Chess960 are many, so by default one in CHESS960_EVERY runs, to CHESS960_LIMIT
-- sequences (the first two depths); tools/check.sh runs all of them deeper.
local CHESS960_EVERY = tonumber(os.getenv("CHESS960_EVERY")) or 4
local CHESS960_LIMIT = tonumber(os.getenv("CHESS960_LIMIT")) or 1000
-- What each file must run: a change of a file that loses a position fails here.
local EXPECTED = { ["tricky.perft"] = 18, ["chess960.perft"] = 960 }

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

local function run_file(name, limit, every)
    local cases = read("tests/perft/" .. name)
    test(name .. " has its positions", function()
        if #cases ~= EXPECTED[name] then
            error(string.format("expected %d, read %d", EXPECTED[name], #cases), 0)
        end
    end)
    for index, case in ipairs(cases) do
        if (index - 1) % every == 0 then
            -- The xfen positions write the castling of Chess960 as KQkq, so they are read as Chess960.
            local position = Chess.parse_fen(case.epd or "", case.id:match("^xfen") ~= nil)
            test(name .. " " .. case.id, function()
                if not position then
                    error("cannot read the position " .. tostring(case.epd), 0)
                end
                table.sort(case.counts, function(a, b) return a.depth < b.depth end)
                assert(#case.counts > 0, "no count to compare")
                for position_index, item in ipairs(case.counts) do
                    if position_index > 1 and item.count > limit then
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
end

run_file("tricky.perft", LIMIT, 1)
run_file("chess960.perft", CHESS960_LIMIT, CHESS960_EVERY)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
