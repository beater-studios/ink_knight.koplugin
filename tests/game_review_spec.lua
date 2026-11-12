package.path = "./?.lua;" .. package.path
local Chess = require("ink_knight/chess")
local Engine = require("ink_knight/engine")
local GameReview = require("ink_knight/game_review")

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

local MATE = Engine.MATE

test("only clear losses are marked, as Lichess names them", function()
    eq(GameReview.judge(50, 40), nil)
    eq(GameReview.judge(50, -90), nil)
    eq(GameReview.judge(50, -110), "Mistake")
    eq(GameReview.judge(50, -260), "Blunder")
    eq(GameReview.judge(nil, 0), nil)
end)

test("walking into a mate is a blunder, and missing one depends on what is left", function()
    eq(GameReview.judge(0, -(MATE - 2)), "Blunder")
    eq(GameReview.judge(-(MATE - 4), -(MATE - 2)), nil)
    eq(GameReview.judge(MATE - 1, 900), "Mistake")
    eq(GameReview.judge(MATE - 1, 100), "Blunder")
    eq(GameReview.judge(MATE - 3, MATE - 5), nil)
end)

test("the score is written for white, as Lichess writes it", function()
    eq(GameReview.eval_text(120, "w"), "+1.20")
    eq(GameReview.eval_text(120, "b"), "-1.20")
    -- A move that mates leaves nothing to write; mates count from the position after the move.
    eq(GameReview.eval_text(MATE - 1, "w"), nil)
    eq(GameReview.eval_text(MATE - 3, "w"), "#1")
    eq(GameReview.eval_text(MATE - 3, "b"), "#-1")
    eq(GameReview.eval_text(-(MATE - 2), "b"), "#1")
    eq(GameReview.eval_text(-(MATE - 4), "w"), "#-2")
    eq(GameReview.eval_text(nil, "w"), nil)
end)

test("the moves looked at: the reader's only against the engine, and none with a single legal move", function()
    local all = GameReview.moves(nil, "e2e4 e7e5 g1f3")
    eq(#all, 3); eq(all[2].mover, "b"); eq(all[2].uci, "e7e5")
    local mine = GameReview.moves(nil, "e2e4 e7e5 g1f3", "w")
    eq(#mine, 2); eq(mine[2].index, 3)
    -- After Rh7 the black king on a8 has b8 only, so that move is not judged.
    eq(#Chess.legal_moves(Chess.from_moves("k7/8/1K6/8/8/8/8/7R w - - 0 1", "h1h7")), 1)
    eq(#GameReview.moves("k7/8/1K6/8/8/8/8/7R w - - 0 1", "h1h7 a8b8", "b"), 0)
    local from_black = GameReview.moves("4k3/8/8/8/8/8/8/4K2R b K - 0 1", "e8d7 h1h7", "w")
    eq(#from_black, 1); eq(from_black[1].index, 2)
end)

local function report(fen, uci)
    local search = Engine.search(Chess.parse_fen(fen), { limits = { seconds = 30, depth = 3, noise = 0 }, report = true, exact = uci, now = os.clock })
    local ok, result
    repeat
        ok, result = coroutine.resume(search)
        assert(ok, result)
    until coroutine.status(search) == "dead"
    return result
end

test("the engine marks a queen left to be taken, and names the better move", function()
    -- White can mate on f7; moving the queen to f6 instead loses it to the pawn.
    local fen = "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5Q2/PPPP1PPP/RNB1K1NR w KQkq - 2 3"
    local result = report(fen, "f3f6")
    eq(Chess.move_to_uci(result.best), "f3f7")
    eq(GameReview.judge(result.score, result.played), "Blunder")
    local good = report(fen, "f3f7")
    eq(GameReview.judge(good.score, good.played), nil)
end)

test("an exchange is searched to its end, so taking a defended piece is not counted as winning it", function()
    -- The queen can take the knight on d5, but the pawn on c6 takes her back.
    local fen = "4k3/8/2p5/3n4/8/8/8/3QK3 w - - 0 1"
    local function at_depth_one(quiescence)
        local search = Engine.search(Chess.parse_fen(fen), { limits = { seconds = 30, depth = 1, noise = 0, quiescence = quiescence },
            report = true, exact = "d1d5", now = os.clock })
        local ok, result
        repeat
            ok, result = coroutine.resume(search)
            assert(ok, result)
        until coroutine.status(search) == "dead"
        return result
    end
    local blind = at_depth_one(nil)
    assert(blind.played > 300, "without the capture search the queen seems to win the knight: " .. blind.played)
    local seeing = at_depth_one(GameReview.LIMITS.quiescence)
    assert(seeing.played < 0, "with it, the queen is lost for the knight: " .. seeing.played)
    assert(Chess.move_to_uci(seeing.best) ~= "d1d5", "and taking is not the best move")
end)

test("the marks are counted for each side", function()
    local counts = GameReview.count({ [1] = { mover = "w", judgment = "Blunder" }, [2] = { mover = "b", judgment = "Mistake" }, [3] = { mover = "w" } })
    eq(counts.w.Blunder, 1); eq(counts.w.Mistake, 0); eq(counts.b.Mistake, 1)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
