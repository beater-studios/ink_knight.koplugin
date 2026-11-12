package.path = "./?.lua;" .. package.path
local Chess = require("ink_knight/chess")
local Correspondence = require("ink_knight/correspondence")
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

local AFTER_E4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
local AFTER_E5 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"

-- An entry of /api/account/playing, as Lichess sends it.
local function entry(fields)
    local game = {
        gameId = "abcd1234", fullId = "abcd1234wxyz", color = "black", fen = AFTER_E4, lastMove = "e2e4",
        isMyTurn = true, secondsLeft = 172800, speed = "correspondence", variant = { key = "standard", name = "Standard" },
        opponent = { id = "helena", username = "Helena", rating = 1600 },
    }
    for key, value in pairs(fields or {}) do
        game[key] = value
    end
    return game
end

local function move(position_fen, uci)
    return Chess.parse_uci(Chess.parse_fen(position_fen), uci)
end

test("only standard correspondence games with a position are kept", function()
    local game = Correspondence.from_playing(entry(), 1000)
    eq(game.id, "abcd1234"); eq(game.color, "b"); eq(game.opponent, "Helena"); eq(game.last_move, "e2e4"); eq(game.at, 1000)
    eq(Correspondence.from_playing(entry({ speed = "rapid" }), 1000), nil)
    eq(Correspondence.from_playing(entry({ variant = { key = "chess960" } }), 1000), nil)
    eq(Correspondence.from_playing(entry({ fen = "not a position" }), 1000), nil)
    eq(Correspondence.from_playing(entry({ gameId = "../x" }), 1000), nil)
end)

test("a move waits only on the reader's turn and must be legal", function()
    local game = Correspondence.from_playing(entry(), 1000)
    eq(Correspondence.play(game, move(AFTER_E4, "e7e6")), true)
    eq(game.pending.uci, "e7e6"); eq(game.pending.san, "e6"); eq(game.pending.fen, AFTER_E4)
    eq(Correspondence.play(game, move(AFTER_E4, "d7d5")), false)
    local position, last = Correspondence.position(game)
    eq(position.board[Chess.square_from_name("e6")], "p")
    eq(Chess.square_name(last.to), "e6")
    local theirs = Correspondence.from_playing(entry({ fen = AFTER_E5, color = "black" }), 1000)
    eq(Correspondence.play(theirs, move(AFTER_E5, "g1f3")), false)
    local illegal = Correspondence.from_playing(entry(), 1000)
    eq(Correspondence.play(illegal, move(AFTER_E4, "e7e4")), false)
end)

test("a move goes out only if the game is still where it was made", function()
    local kept = { Correspondence.from_playing(entry(), 1000) }
    Correspondence.play(kept[1], move(AFTER_E4, "e7e5"))
    local plan = Correspondence.plan(kept, { entry() })
    eq(#plan.send, 1); eq(#plan.gone, 0)
    -- The opponent took the move back, resigned or the game ended: the position or the turn changed, or it left.
    plan = Correspondence.plan(kept, { entry({ fen = Chess.START_FEN, isMyTurn = false }) })
    eq(#plan.send, 0); eq(#plan.gone, 1)
    plan = Correspondence.plan(kept, {})
    eq(#plan.send, 0); eq(#plan.gone, 1)
end)

test("a game missing from a list that may be cut short keeps its move and its place", function()
    local kept = { Correspondence.from_playing(entry(), 1000) }
    Correspondence.play(kept[1], move(AFTER_E4, "e7e5"))
    local full = {}
    for index = 1, Correspondence.LIST_LIMIT do
        full[index] = entry({ gameId = "other" .. index })
    end
    local plan = Correspondence.plan(kept, full)
    eq(#plan.send, 0); eq(#plan.gone, 0)
    local games = Correspondence.merge(kept, full, 2000)
    eq(#games, Correspondence.LIST_LIMIT + 1)
    eq(Correspondence.find(games, "abcd1234").pending.uci, "e7e5")
end)

test("a fresh list replaces the positions, keeps the moves waiting and forgets finished games", function()
    local kept = { Correspondence.from_playing(entry(), 1000), Correspondence.from_playing(entry({ gameId = "gone0001" }), 1000) }
    Correspondence.play(kept[1], move(AFTER_E4, "e7e5"))
    local games = Correspondence.merge(kept, { entry({ secondsLeft = 100000 }), entry({ gameId = "new00001", speed = "rapid" }) }, 2000)
    eq(#games, 1)
    eq(games[1].pending.uci, "e7e5")
    -- The same position keeps the clock of the first list that had it, so an unchanged list is not written again.
    eq(games[1].seconds_left, 172800); eq(games[1].at, 1000)
    eq(Correspondence.same_games(kept, games), false)
    eq(Correspondence.same_games(games, Correspondence.merge(games, { entry({ secondsLeft = 90000 }) }, 3000)), true)
    -- A new position takes the fresh clock.
    games = Correspondence.merge(games, { entry({ fen = AFTER_E5, secondsLeft = 100000 }) }, 4000)
    eq(games[1].seconds_left, 100000); eq(games[1].at, 4000)
end)

test("a move whose game already shows it played had reached Lichess", function()
    local kept = { Correspondence.from_playing(entry(), 1000) }
    Correspondence.play(kept[1], move(AFTER_E4, "e7e5"))
    local plan = Correspondence.plan(kept, { entry({ fen = AFTER_E5, isMyTurn = false, lastMove = "e7e5" }) })
    eq(#plan.landed, 1); eq(#plan.send, 0); eq(#plan.gone, 0)
end)

test("the reader's clock runs down only on the reader's turn", function()
    local mine = Correspondence.from_playing(entry({ secondsLeft = 1000 }), 0)
    eq(Correspondence.seconds_left(mine, 300), 700)
    eq(Correspondence.seconds_left(mine, 5000), 0)
    local theirs = Correspondence.from_playing(entry({ fen = AFTER_E5, secondsLeft = 1000 }), 0)
    eq(Correspondence.seconds_left(theirs, 300), 1000)
end)

test("the kept games are read back, and a move that no longer fits is dropped", function()
    local good = Correspondence.from_playing(entry(), 1000)
    Correspondence.play(good, move(AFTER_E4, "e7e5"))
    local stale = Correspondence.from_playing(entry({ gameId = "stale001" }), 1000)
    stale.pending = { uci = "e7e5", san = "e5", fen = Chess.START_FEN }
    local broken = Correspondence.from_playing(entry({ gameId = "broken01" }), 1000)
    broken.pending = { uci = "a1a8", san = "?", fen = AFTER_E4 }
    local read = State.read_correspondence({
        account = "reader", name = "Reader",
        games = { good, stale, broken, { id = "nofen001", color = "w" }, { id = "../bad", color = "w", fen = AFTER_E4 } },
    })
    eq(read.account, "reader"); eq(read.name, "Reader"); eq(#read.games, 3)
    eq(read.games[1].pending.uci, "e7e5"); eq(read.games[1].pending.san, "e5")
    eq(read.games[2].pending, nil)
    eq(read.games[3].pending, nil)
    eq(#State.read_correspondence(nil).games, 0)
    eq(#State.read_correspondence({ games = { good } }).games, 0)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
