package.path = "./?.lua;" .. package.path
local Chess = require("ink_knight/chess")
local SavedState = require("ink_knight/saved_state")
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

-- What the first page shows and uses, read from a whole settings file as the plugin reads it.
local function read_all(saved)
    local options = {}
    for key in pairs(State.OPTIONS) do
        options[key] = State.option(key, saved[key])
    end
    local function game(key, two_players)
        return SavedState.restore(function(data) return State.read_game(data, two_players) end, saved[key], function() end)
    end
    return {
        options = options,
        offline = game("offline_game", false),
        two_players = game("two_player_game", true),
        pile = State.read_pile(saved.puzzles),
        review = State.read_pile(saved.puzzles_review),
        results = State.read_results(saved.puzzle_results),
    }
end

test("a game against the engine comes back as it was saved, and goes on", function()
    local position = Chess.parse_fen(Chess.START_FEN)
    local moves = {}
    for _, uci in ipairs({ "e2e4", "e7e5", "g1f3", "b8c6", "f1b5" }) do
        position = Chess.apply_uci(position, uci)
        moves[#moves + 1] = uci
    end
    local saved = SavedState.copy({ version = 1, level = 3, my_color = "b", color_choice = "black", moves = table.concat(moves, " ") })
    local game = State.read_game(saved, false)
    eq(game.level, 3); eq(game.my_color, "b"); eq(game.color_choice, "black")
    eq(Chess.position_key(Chess.from_moves(nil, game.moves)), Chess.position_key(position))
    local after = Chess.from_moves(nil, game.moves .. " a7a6")
    assert(after, "the game should go on after it was read back")
end)

test("a game between two people keeps the side the board faces", function()
    local game = State.read_game({ version = 1, flipped = true, moves = "d2d4 d7d5" }, true)
    eq(game.flipped, true); eq(game.moves, "d2d4 d7d5")
    eq(State.read_game({ moves = "" }, true).flipped, false)
end)

test("what no longer exists gets its default, and the rest stays", function()
    local read = read_all({
        board_style = "marble", piece_set = "glass", refresh_minutes = 7, rating_margin = "200", rated = "yes",
        confirm_moves = true, board_coordinates = true,
        offline_game = { level = 9, my_color = "w", color_choice = "purple", moves = "e2e4" },
        puzzles = {
            { id = "kept", played = "e2e4", solution = { "e7e5" }, rating = 1500 },
            { id = "no_solution", played = "e2e4" },
            { id = "odd_moves", played = "e2e4; rm", solution = { "e7e5" } },
            { id = "kept", played = "e2e4", solution = { "e7e5" } },
            "a text where a puzzle was",
        },
    })
    eq(read.options.board_style, "plain"); eq(read.options.piece_set, "classic")
    eq(read.options.refresh_minutes, 5); eq(read.options.rating_margin, 0); eq(read.options.rated, false)
    eq(read.options.confirm_moves, true); eq(read.options.board_coordinates, true)
    eq(read.offline.level, 1); eq(read.offline.color_choice, "random"); eq(read.offline.moves, "e2e4")
    eq(#read.pile, 1); eq(read.pile[1].id, "kept")
end)

test("a damaged game is dropped, and the options and puzzles stay", function()
    local warned = 0
    local saved = {
        board_style = "dotted",
        offline_game = { version = 1, level = 2, my_color = "w", moves = 5 },
        two_player_game = { version = 1, moves = "e2e5" },
        puzzles = { { id = "p1", played = "", solution = { "e2e4" } } },
        puzzle_results = { { id = "p0", win = true }, { id = 3, win = true }, { id = "p2", win = "no" } },
    }
    eq(SavedState.restore(function(data) return State.read_game(data, false) end, saved.offline_game, function() warned = warned + 1 end), nil)
    local read = read_all(saved)
    eq(read.offline, nil); eq(read.two_players, nil)
    eq(read.options.board_style, "dotted")
    eq(#read.pile, 1)
    eq(#read.results, 1); eq(read.results[1].id, "p0"); eq(read.results[1].rated, true)
    eq(State.read_game({ version = 2, my_color = "w", moves = "" }, false), nil)
    eq(State.read_game({ my_color = "x", moves = "" }, false), nil)
    eq(State.read_game("not a game", false), nil)
    eq(#State.read_pile("not a pile"), 0)
    eq(warned, 0)
end)

test("a save of 0.2.0 opens with everything it had", function()
    local saved = dofile("tests/saves/0.2.0.lua")
    local read = read_all(saved)
    eq(read.options.board_style, "newspaper"); eq(read.options.piece_set, "merida")
    eq(read.options.board_coordinates, true); eq(read.options.refresh_minutes, 15)
    eq(read.options.rated, true); eq(read.options.rating_margin, 200); eq(read.options.confirm_moves, true)
    assert(read.offline, "the game against the engine should continue")
    eq(read.offline.version, State.GAME_VERSION)
    eq(read.offline.level, 2); eq(read.offline.my_color, "w"); eq(read.offline.color_choice, "random")
    eq(read.offline.moves, saved.offline_game.moves)
    eq(read.two_players, nil)
    eq(#read.pile, 3); eq(read.pile[1].id, "p0001"); eq(read.pile[3].solution[3], "d4b3")
    for _, puzzle in ipairs(read.pile) do
        assert(Chess.from_moves(nil, puzzle.played), "the puzzle " .. puzzle.id .. " should still be playable")
    end
    eq(#read.review, 0)
    eq(#read.results, 1); eq(read.results[1].id, "p0009"); eq(read.results[1].win, false)
end)

test("every save kept in tests/saves opens", function()
    local listing = io.popen("ls tests/saves/*.lua")
    local count = 0
    for path in listing:lines() do
        count = count + 1
        local read = read_all(dofile(path))
        assert(read.options.board_style, path)
    end
    listing:close()
    assert(count > 0, "no saves found")
end)

test("the puzzle choices fall back to normal and either color, and a pile keeps what each was asked with", function()
    eq(State.option("puzzle_difficulty", "impossible"), "normal")
    eq(State.option("puzzle_color", nil), "any")
    eq(State.option("puzzle_color", "black"), "black")
    local pile = State.read_pile({
        { id = "a", played = "e2e4", solution = { "e7e5" }, wanted = "harder black" },
        { id = "b", played = "e2e4", solution = { "e7e5" }, wanted = 3 },
    })
    eq(pile[1].wanted, "harder black")
    eq(pile[2].wanted, nil)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
