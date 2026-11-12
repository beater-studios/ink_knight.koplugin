package.path = "./?.lua;" .. package.path
local Chess = require("ink_knight/chess")
local Editor = require("ink_knight/editor")
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
local function sq(name) return Chess.square_from_name(name) end

test("a piece goes where it is put, and the same piece again takes it away", function()
    local position = Editor.new(Editor.EMPTY)
    Editor.place(position, sq("e4"), "Q")
    eq(position.board[sq("e4")], "Q")
    Editor.place(position, sq("e4"), "n")
    eq(position.board[sq("e4")], "n")
    Editor.place(position, sq("e4"), "n")
    eq(position.board[sq("e4")], nil)
    Editor.place(position, sq("d4"), "P")
    Editor.place(position, sq("d4"), nil)
    eq(position.board[sq("d4")], nil)
end)

test("castling follows the king and the rooks", function()
    local position = Editor.new()
    eq(position.castling, "KQkq")
    Editor.place(position, sq("h1"), nil)
    eq(position.castling, "Qkq")
    Editor.toggle_castling(position, "K")
    eq(position.castling, "Qkq")
    Editor.place(position, sq("h1"), "R")
    eq(Editor.possible_castling(position), "KQkq")
    Editor.toggle_castling(position, "K")
    eq(position.castling, "KQkq")
    Editor.toggle_castling(position, "q")
    eq(position.castling, "KQk")
end)

test("a position that cannot be played says why", function()
    eq(Editor.problem(Editor.new()), nil)
    eq(Editor.problem(Editor.new(Editor.EMPTY)), "kings")
    eq(Editor.problem(Editor.new("4k3/8/8/8/8/8/8/4K2P w - - 0 1")), "pawn_rank")
    eq(Editor.problem(Editor.new("4k3/8/8/8/8/8/PPPPPPPP/P3K3 w - - 0 1")), "pawn_rank")
    eq(Editor.problem(Editor.new("4k3/8/8/8/8/PPPPPPPP/P7/4K3 w - - 0 1")), "too_many")
    eq(Editor.problem(Editor.new("4k3/8/8/8/8/8/8/4KR2 b - - 0 1")), nil)
    eq(Editor.problem(Editor.new("4k3/4R3/8/8/8/8/8/4K3 w - - 0 1")), "check")
    eq(Editor.problem(Editor.new("k7/1Q6/1K6/8/8/8/8/8 b - - 0 1")), "over")
end)

test("a FEN typed in is read, and one that is not a position is refused", function()
    local position = Editor.read_fen("  4k3/8/8/8/8/8/8/4K2R w KQ - 3 40  ")
    eq(Editor.fen(position), "4k3/8/8/8/8/8/8/4K2R w K - 0 1")
    local missing, why = Editor.read_fen("not a fen")
    eq(missing, nil); eq(why, "fen")
end)

test("taking back counts the moves from who moved first", function()
    eq(Chess.take_back("e2e4 e7e5 g1f3", "w"), "e2e4 e7e5")
    -- From a position with black to move, black's moves are the odd ones.
    eq(Chess.take_back("e7e5 g1f3 b8c6", "b", "b"), "e7e5 g1f3")
    eq(Chess.take_back("e7e5 g1f3", "w", "b"), "e7e5")
    eq(Chess.take_back("e7e5", "w", "b"), nil)
end)

test("a game from a position is kept with it, and one that no longer fits is left out", function()
    local fen = "4k3/8/8/8/8/8/8/4K2R b K - 0 1"
    local game = State.read_game({ version = 1, moves = "e8d7 h1h7", my_color = "w", level = 2, initial_fen = fen }, false)
    eq(game.initial_fen, fen); eq(game.moves, "e8d7 h1h7")
    eq(State.read_game({ version = 1, moves = "e2e4", my_color = "w", initial_fen = fen }, false), nil)
    eq(State.read_game({ version = 1, moves = "", my_color = "w", initial_fen = "8/8/8/8/8/8/8/8 w - - 0 1" }, false), nil)
    eq(State.read_game({ version = 1, moves = "e8d7", flipped = true, initial_fen = fen }, true).initial_fen, fen)
    eq(State.read_game({ version = 1, moves = "e2e4", my_color = "w" }, false).initial_fen, nil)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
