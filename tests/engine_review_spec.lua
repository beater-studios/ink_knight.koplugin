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
    -- As on the Kindle when the time ran out: the last line has only its first move, and the line before stays.
    local stopped = {}
    assert(Stockfish.read_info("info depth 13 score cp 36 pv b2b3 e7d6 c1b2 b7b6", stopped))
    assert(Stockfish.read_info("info depth 14 score cp 46 time 2514 pv b2b3", stopped))
    eq(stopped.depth, 14); eq(stopped.cp, 46); eq(stopped.pv, "b2b3 e7d6 c1b2 b7b6")
    assert(Stockfish.read_info("info depth 15 score cp 20 pv d4c5", stopped))
    eq(stopped.pv, "d4c5", "another first move replaces the line")
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

test("the end of the engine is read in the same batch as its answer, and after a line it left unfinished", function()
    local path = os.tmpname()
    local function engine_with(text)
        local file = assert(io.open(path, "wb"))
        file:write(text)
        file:close()
        return setmetatable({ out_path = path, offset = 0, partial = "", searching = true, result = { depth = 0 } }, Stockfish)
    end
    local answered = engine_with("info depth 5 score cp 10 pv e2e4\nbestmove e2e4\n\n" .. Stockfish.ENDED .. "\n")
    local result = answered:poll()
    eq(result and result.best, "e2e4", "the answer")
    eq(answered.ended, true, "and the end right after it")
    -- Killed in the middle of a line: the shell starts a line of its own for the end.
    local cut = engine_with("info depth 9 sco\n" .. Stockfish.ENDED .. "\n")
    eq(cut:poll(), nil, "no answer")
    eq(cut.ended, true, "but the end is seen")
    os.remove(path)
end)

test("a stopped search never answers for the next one, even when Stockfish says readyok before its bestmove", function()
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    file:write("info depth 3 score cp 5 pv a2a3\nreadyok\nbestmove a2a3\ninfo depth 9 score cp 30 pv e2e4\nbestmove e2e4\n")
    file:close()
    local engine = setmetatable({ out_path = path, offset = 0, partial = "", searching = true, result = { depth = 0 }, pipe = nil }, Stockfish)
    engine.searching, engine.dropped = true, 1
    local result = engine:poll()
    eq(result and result.best, "e2e4", "the answer of the search asked")
    eq(result.depth, 9)
    eq(engine.dropped, 0)
    os.remove(path)
end)

test("the search of a move alone is asked with its depth and its time", function()
    local sent = {}
    local engine = setmetatable({ send = function(_, line) sent[#sent + 1] = line end }, { __index = Stockfish })
    engine:search("8/8/8/8/8/8/8/K6k w - - 0 1", 5000, "a1a2", 12, "h1h2")
    eq(sent[1], "position fen 8/8/8/8/8/8/8/K6k w - - 0 1 moves a1a2")
    eq(sent[2], "go depth 12 movetime 5000 searchmoves h1h2")
    engine:search("8/8/8/8/8/8/8/K6k w - - 0 1", 700)
    eq(sent[4], "go movetime 700")
end)

test("a move judged against the best one of the same position", function()
    -- An engine that favors the side to move by 30: every position is +30 for whoever plays, so before against after would cost each move 60.
    local scores = { [0] = { cp = 30 }, [1] = { cp = 30 }, [2] = { cp = 30 }, [3] = { cp = 330 } }
    local movers = { "w", "b", "w" }
    local plain = EngineReview.judge(scores, movers)
    eq(plain[1].loss, 60, "before against after counts the favor twice")
    -- With each move searched alone from its position: the first two are the best ones, the third drops three pawns.
    local played = { { cp = 30 }, { cp = 35 }, { cp = -270 } }
    local judged, summary = EngineReview.judge(scores, movers, played)
    eq(judged[1].loss, 0); eq(judged[1].judgment, nil)
    eq(judged[2].loss, 0, "a move searched alone never counts as better than the best one")
    eq(judged[3].judgment, "Blunder"); eq(judged[3].loss, 300)
    eq(summary.w.blunder, 1); eq(summary.b.accuracy, 100)
    -- The score shown after a move is the middle of the two, where the favor cancels: white played, +30 for white alone and +30 for black after.
    eq(judged[1].white_score, 0); eq(judged[1].eval_text, "+0.00"); eq(judged[1].white_cp, 0)
    eq(judged[3].white_score, -300); eq(judged[3].white_cp, -300)
    -- A move that mates: the position after is mate, and the move alone is a mate in one.
    local mating = EngineReview.judge({ [0] = { mate = 1 }, [1] = { mate = 0 } }, { "w" }, { { mate = 1 } })
    eq(mating[1].judgment, nil); eq(mating[1].loss, 0)
    -- A move that walks into a mate only the position after shows: marked, and counted, as the score shown says.
    local walked, walked_summary = EngineReview.judge({ [0] = { cp = 20 }, [1] = { mate = 3 } }, { "w" }, { { cp = -30 } })
    eq(walked[1].judgment, "Blunder"); eq(walked[1].eval_text, "#-3"); eq(walked[1].white_cp, -1000); eq(walked_summary.w.blunder, 1)
    -- The text and the chart agree, whoever moved and however the middle rounds.
    local odd = EngineReview.judge({ [0] = { cp = 20 }, [1] = { cp = 15 } }, { "b" }, { { cp = -10 } })
    eq(odd[1].white_cp, odd[1].white_score); eq(odd[1].eval_text, string.format("%+.2f", odd[1].white_score / 100))
    -- A mate missed: the best mates in two, the move played only wins a pawn.
    local missed = EngineReview.judge({ [0] = { mate = 2 }, [1] = { cp = -100 } }, { "w" }, { { cp = 120 } })
    eq(missed[1].judgment, "Blunder")
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
