package.path = "./?.lua;" .. package.path
local Chess = require("ink_knight/chess")
local Openings = require("ink_knight/openings")

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

test("a game is named after the last opening it went through", function()
    eq(Openings.name(nil, "e2e4"), "King's Pawn Game")
    eq(Openings.name(nil, "e2e4 e7e5 g1f3 b8c6 f1c4"), "Italian Game")
    eq(Openings.name("startpos", "e2e4 e7e5 g1f3 b8c6 f1c4 f8c5"), "Italian Game: Giuoco Piano")
end)

test("the name stays after the game leaves the list", function()
    eq(Openings.name(nil, "e2e4 e7e5 g1f3 b8c6 f1c4 f8c5 a2a3 a7a6 h2h3 h7h6 a3a4 h6h5"), "Italian Game: Giuoco Piano")
end)

test("the same position by another order of moves has the same name", function()
    eq(Openings.name(nil, "g1f3 d7d5 d2d4"), "Queen's Pawn Game: Zukertort Variation")
    eq(Openings.name(nil, "d2d4 d7d5 g1f3"), "Queen's Pawn Game: Zukertort Variation")
end)

test("a square passed over that cannot be taken does not change the position", function()
    eq(Chess.epd(Chess.from_moves(nil, "e2e4")), "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -")
    eq(Chess.epd(Chess.from_moves(nil, "e2e4 a7a6 e4e5 d7d5")), "rnbqkbnr/1pp1pppp/p7/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6")
end)

test("no name without moves, from another start or with a move that does not fit", function()
    eq(Openings.name(nil, ""), nil)
    eq(Openings.name(nil, nil), nil)
    eq(Openings.name("8/8/8/8/8/8/8/K6k w - - 0 1", "a1a2"), nil)
    eq(Openings.name(nil, "e2e4 zz e7e5 g1f3"), "King's Pawn Game")
    eq(Openings.name(nil, "e3e4"), nil)
end)

test("the list has names for positions only", function()
    local data = require("ink_knight/data/openings")
    local count = 0
    for key, name in pairs(data.names) do
        count = count + 1
        assert(key:match("^[1-8KQRBNPkqrbnp/]+ [wb] [KQkq-]+ [a-h36-]+$"), key)
        assert(type(name) == "string" and name:match("%S"), key)
    end
    assert(count > 3000, "too few openings: " .. count)
    assert(data.max_plies > 0)
end)

test("the list of moves puts the name first, preferring the one Lichess gave", function()
    local MoveList = require("ink_knight/ui/move_list")
    local sans = { "e4", "e5", "Nf3" }
    local rows = MoveList.page_rows(sans, 1, "w", { moves = "e2e4 e7e5 g1f3" })
    eq(rows[1].kind, "text")
    eq(rows[1].text, "King's Knight Opening")
    eq(rows[2].white, "e4")
    eq(MoveList.page_rows(sans, 1, "w", { opening = "From Lichess", moves = "e2e4 e7e5 g1f3" })[1].text, "From Lichess")
    eq(MoveList.page_rows(sans, 1, "w", {})[1].kind, "moves")
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
