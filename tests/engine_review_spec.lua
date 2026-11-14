package.path = "./?.lua;" .. package.path
local EngineReview = require("ink_knight/engine_review")
local Stockfish = require("ink_knight/stockfish")

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

local function eq(actual, expected, what)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
    end
end

test("a line of Stockfish read: depth, score and the best line, bounds and other lines left out", function()
    local into = {}
    assert(Stockfish.read_info("info depth 12 seldepth 18 multipv 1 score cp 35 nodes 99 nps 97073 pv e2e4 e7e5 g1f3", into))
    eq(into.depth, 12); eq(into.cp, 35); eq(into.mate, nil); eq(into.pv, "e2e4 e7e5 g1f3")
    assert(Stockfish.read_info("info depth 20 score mate -3 nodes 1 pv h7h8q", into))
    eq(into.mate, -3)
    assert(not Stockfish.read_info("info depth 13 score cp 50 lowerbound nodes 1 pv d2d4", {}), "a bound is no score")
    assert(not Stockfish.read_info("info depth 13 multipv 2 score cp 10 pv d2d4", {}), "only the best line")
    assert(not Stockfish.read_info("info string NNUE evaluation", {}))
end)

test("each move judged by the winning chances it lost, as on Lichess", function()
    -- White to move at 0; scores are for the side to move in each position.
    local scores = {
        [0] = { cp = 30 },   -- white +0.30
        [1] = { cp = -20 },  -- after 1. e4, black to move, -0.20 for black: +0.20 for white, a small loss
        [2] = { cp = 40 },   -- after black's move, white +0.40: black lost 0.20, nothing
        [3] = { cp = -350 }, -- after white's move, black is at -3.50: white gained
        [4] = { cp = 800 },  -- after black's move, white at +8: black lost a lot
        [5] = { mate = 0 },  -- white mated black
    }
    local movers = { "w", "b", "w", "b", "w" }
    local moves, summary = EngineReview.judge(scores, movers)
    eq(moves[1].judgment, nil, "a tenth of a pawn is nothing")
    eq(moves[4].judgment, "Blunder", "from -3.5 to -8 for black is a blunder")
    eq(moves[5].judgment, nil, "the mate is no mistake")
    eq(moves[5].eval_text, nil, "a move that mates leaves nothing to write")
    eq(moves[1].eval_text, "+0.20", "the score after the move, for white")
    eq(moves[4].eval_text, "+8.00")
    eq(summary.b.blunder, 1)
    eq(summary.w.blunder + summary.w.mistake + summary.w.inaccuracy, 0)
    assert(summary.w.accuracy > summary.b.accuracy, "the side that blundered is less accurate")
    assert(summary.w.accuracy <= 100 and summary.b.accuracy >= 0)
    eq(summary.b.acpl, math.floor((20 + 450) / 2 + 0.5), "the average loss in centipawns")
end)

test("a mate allowed, and a mate announced, written as Lichess writes them", function()
    local scores = { [0] = { cp = 0 }, [1] = { mate = 2 }, [2] = { mate = -1 } }
    local moves = EngineReview.judge(scores, { "w", "b" })
    eq(moves[1].judgment, "Blunder", "white allowed a mate")
    eq(moves[1].eval_text, "#-2", "black mates in 2")
    eq(moves[2].eval_text, "#-1")
    -- A mate allowed from equality loses at most a thousand centipawns, as on Lichess.
    local _, summary = EngineReview.judge(scores, { "w", "b" })
    eq(summary.w.acpl, 1000)
end)

test("the score after each move for white, for the chart, a mate counted as a thousand", function()
    local scores = { [0] = { cp = 30 }, [1] = { cp = -20 }, [2] = { cp = 2500 }, [3] = { mate = 0 } }
    local moves = EngineReview.judge(scores, { "w", "b", "w" })
    eq(moves[1].white_cp, 20, "black to move at -0.20 is white at +0.20")
    eq(moves[2].white_cp, 1000, "a large score is capped")
    eq(moves[3].white_cp, 1000, "white mated")
    local black_mates = EngineReview.judge({ [0] = { cp = -900 }, [1] = { mate = 0 } }, { "b" })
    eq(black_mates[1].white_cp, -1000, "black mated")
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
