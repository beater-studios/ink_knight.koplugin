-- Reads back what Ink Knight keeps in koreader/settings/ink_knight.lua, whichever version saved it: the options,
-- the games without internet and the puzzles kept for when there is no connection. Whatever does not make sense
-- any more is left out, so an update or a damaged file never stops the plugin from opening. No KOReader here, so
-- the tests can use it.
local Api = require("ink_knight/api")
local Chess = require("ink_knight/chess")
local Puzzles = require("ink_knight/puzzles")
local SavedState = require("ink_knight/saved_state")

local State = {}

-- Goes up only when a field of a saved game changes its meaning. A field added later gets its default instead.
State.GAME_VERSION = 1

-- key = { allowed values, default }. A value that no longer exists, or of another type, gets the default.
State.OPTIONS = {
    refresh_minutes = { { 1, 5, 15, 0 }, 5 },
    rating_margin = { { 0, 100, 200, 300, 500 }, 0 },
    rated = { { true, false }, false },
    confirm_moves = { { true, false }, false },
    auto_queen = { { true, false }, false },
    variant = { { "standard", "chess960" }, "standard" },
    board_coordinates = { { true, false }, false },
    board_style = { { "plain", "newspaper", "crosshatch", "dotted", "contrast" }, "plain" },
    piece_set = { { "classic", "cburnett", "merida", "chessnut", "mpchess", "kiwen-suwi", "shapes" }, "classic" },
    puzzle_difficulty = { { "easiest", "easier", "normal", "harder", "hardest" }, "normal" },
    puzzle_color = { { "any", "white", "black" }, "any" },
    clock_preset = { (function()
        local list = { "none" }
        for _, preset in ipairs(require("ink_knight/chess_clock").PRESETS) do
            list[#list + 1] = preset
        end
        return list
    end)(), "none" },
    coordinates_mode = { { "find", "name" }, "find" },
    coordinates_side = { { "white", "black", "random" }, "white" },
    coordinates_time = { { "seconds", "none" }, "seconds" },
    coordinates_pieces = { { true, false }, true },
}

-- The preferences of the site that the plugin also has, from /api/account/preferences: promoting to a queen only
-- when Lichess does it always (not only when premoving, which the plugin does not do), the coordinates when shown in
-- any way, confirming moves when on for any kind of game the plugin plays (unlimited, correspondence, classical,
-- rapid, and blitz in challenges), and the piece set when it is one the plugin draws, piece_set_other telling when the
-- site has a set the plugin does not. nil for what the answer does not say.
local SUBMIT_MOVE_PLAYED = { 1, 2, 4, 8, 16 }

function State.from_site_preferences(data, piece_sets)
    local prefs = type(data) == "table" and type(data.prefs) == "table" and data.prefs or {}
    local result = {}
    if type(prefs.autoQueen) == "number" then
        result.auto_queen = prefs.autoQueen == 3
    end
    if type(prefs.coords) == "number" then
        result.board_coordinates = prefs.coords ~= 0
    end
    if type(prefs.submitMove) == "number" then
        local on = false
        for _, flag in ipairs(SUBMIT_MOVE_PLAYED) do
            on = on or math.floor(prefs.submitMove / flag) % 2 == 1
        end
        result.confirm_moves = on
    end
    for _, name in ipairs(piece_sets or {}) do
        if prefs.pieceSet == name then
            result.piece_set = name
        end
    end
    if type(prefs.pieceSet) == "string" and not result.piece_set then
        result.piece_set_other = true
    end
    return result
end

function State.option(key, saved)
    local option = assert(State.OPTIONS[key], "state: unknown option " .. tostring(key))
    return SavedState.one_of(saved, option[1], option[2])
end

-- Moves as Lichess writes them, "e2e4 e7e5 e7e8q", separated by single spaces.
local function is_moves(text)
    if type(text) ~= "string" or text:find("^ ") or text:find(" $") or text:find("  ") then
        return false
    end
    for move in text:gmatch("[^ ]+") do
        if not move:match("^[a-h][1-8][a-h][1-8][qrbn]?$") then
            return false
        end
    end
    return true
end

-- Whether every move is legal where it was played, from the start or from a position set up in the editor.
local function plays_from_start(moves, initial_fen)
    local position = Chess.parse_fen(initial_fen or Chess.START_FEN)
    if not position then
        return false
    end
    for uci in moves:gmatch("[^ ]+") do
        local legal = false
        for _, move in ipairs(Chess.legal_moves(position)) do
            if Chess.move_to_uci(move) == uci then
                legal = true
                break
            end
        end
        if not legal then
            return false
        end
        position = Chess.apply_uci(position, uci)
    end
    return true
end

-- A game without internet, against the engine or between two people. Returns the game to continue, or nil when the
-- save does not hold one that can be played: the moves must still be legal from the start.
function State.read_game(data, two_players)
    if type(data) ~= "table" then
        return nil
    end
    -- Saves from before the version field have the same format as version 1.
    local version = data.version == nil and 1 or data.version
    -- Only since 0.4.0: a game from a position, which must still be one that can be played.
    local initial_fen = nil
    if data.initial_fen ~= nil then
        local Editor = require("ink_knight/editor")
        local position = type(data.initial_fen) == "string" and Chess.parse_fen(data.initial_fen)
        if not position or Editor.problem(position) then
            return nil
        end
        initial_fen = data.initial_fen
    end
    if version ~= State.GAME_VERSION or not is_moves(data.moves) or not plays_from_start(data.moves, initial_fen) then
        return nil
    end
    if two_players then
        local ChessClock = require("ink_knight/chess_clock")
        local clock = ChessClock.restore(data.clock)
        local preset = SavedState.one_of(data.clock_preset, ChessClock.PRESETS, nil)
        return {
            version = State.GAME_VERSION, moves = data.moves, flipped = data.flipped == true,
            -- Only since 0.4.0, and only with a clock chosen.
            clock = clock and preset and ChessClock.save(clock, 0) or nil,
            clock_preset = clock and preset or nil,
            clock_paused = clock and preset and data.clock_paused == true or nil,
            initial_fen = initial_fen,
        }
    end
    local my_color = SavedState.one_of(data.my_color, { "w", "b" }, nil)
    if not my_color then
        return nil
    end
    return {
        version = State.GAME_VERSION,
        moves = data.moves,
        my_color = my_color,
        level = SavedState.one_of(data.level, { 1, 2, 3, 4 }, 1),
        -- Only since 0.3.0: an older game had no choice, and the next one is random again.
        color_choice = SavedState.one_of(data.color_choice, { "random", "white", "black" }, "random"),
        initial_fen = initial_fen,
    }
end

local function is_text_list(list)
    if type(list) ~= "table" or #list == 0 then
        return false
    end
    for index = 1, #list do
        if type(list[index]) ~= "string" then
            return false
        end
    end
    return true
end

function State.read_recent_openings(saved)
    local list, seen = {}, {}
    for _, item in ipairs(type(saved) == "table" and saved or {}) do
        if type(item) == "table" and Api.is_safe_id(item.key) and type(item.name) == "string" and not seen[item.key]
            and #list < Puzzles.RECENT_OPENINGS then
            seen[item.key] = true
            list[#list + 1] = { key = item.key, name = item.name }
        end
    end
    return list
end

-- A pile of puzzles, in its order, without the ones that cannot be played and without repeated ids.
function State.read_pile(saved)
    local pile, seen = {}, {}
    if type(saved) ~= "table" then
        return pile
    end
    for _, puzzle in ipairs(SavedState.list(saved, nil, {})) do
        if type(puzzle) == "table" and type(puzzle.id) == "string" and not seen[puzzle.id]
            and is_moves(puzzle.played) and is_text_list(puzzle.solution) then
            seen[puzzle.id] = true
            puzzle.rating = type(puzzle.rating) == "number" and puzzle.rating or nil
            puzzle.angle = type(puzzle.angle) == "string" and puzzle.angle or nil
            puzzle.pile = type(puzzle.pile) == "string" and puzzle.pile or nil
            puzzle.wanted = type(puzzle.wanted) == "string" and puzzle.wanted or nil
            pile[#pile + 1] = puzzle
        end
    end
    return pile
end

-- The correspondence games kept for when there is no connection: { account, games }. A game must still have a
-- position, and a move waiting must still be legal in the position it was made in, or the move is dropped.
function State.read_correspondence(saved)
    local Correspondence = require("ink_knight/correspondence")
    if type(saved) ~= "table" or type(saved.account) ~= "string" then
        return { games = {} }
    end
    local games, seen = {}, {}
    for _, game in ipairs(SavedState.list(saved.games, nil, {})) do
        local position = type(game) == "table" and type(game.fen) == "string" and Chess.parse_fen(game.fen)
        if position and type(game.id) == "string" and game.id:match("^%w+$") and not seen[game.id]
            and (game.color == "w" or game.color == "b") then
            seen[game.id] = true
            local kept = {
                id = game.id,
                color = game.color,
                fen = game.fen,
                last_move = is_moves(game.last_move) and not game.last_move:find(" ") and game.last_move or nil,
                opponent = type(game.opponent) == "string" and game.opponent or nil,
                seconds_left = type(game.seconds_left) == "number" and game.seconds_left or nil,
                at = type(game.at) == "number" and game.at or nil,
            }
            local pending = game.pending
            if type(pending) == "table" and type(pending.uci) == "string" and type(pending.fen) == "string"
                and Correspondence.same_position(pending.fen, game.fen) then
                local move = Chess.parse_uci(position, pending.uci)
                if move then
                    Correspondence.play(kept, move)
                end
            end
            games[#games + 1] = kept
        end
    end
    return { account = saved.account, name = type(saved.name) == "string" and saved.name or nil, games = games }
end

-- Where each level of the package goes on, { [level] = index }, without what is not a level or a whole number.
function State.read_pack_progress(saved)
    local Pack = require("ink_knight/puzzle_pack")
    local progress = {}
    for _, level in ipairs(Pack.LEVELS) do
        local index = type(saved) == "table" and saved[level]
        if type(index) == "number" and index >= 1 and index == math.floor(index) then
            progress[level] = index
        end
    end
    return progress
end

-- The best score in 30 seconds of each mode and side, { find_w = 12, ... }, without what makes no sense.
function State.read_coordinate_records(saved)
    local Coordinates = require("ink_knight/coordinates")
    local records = {}
    for _, mode in ipairs(State.OPTIONS.coordinates_mode[1]) do
        for _, color in ipairs({ "w", "b" }) do
            local key = Coordinates.record_key(mode, color)
            local score = type(saved) == "table" and saved[key]
            if type(score) == "number" and score >= 0 and score == math.floor(score) then
                records[key] = score
            end
        end
    end
    return records
end

-- The best score of each level of "Learn chess", { [stage key] = { [level] = score } }, without what makes no sense.
function State.read_learn_progress(saved)
    local progress = {}
    if type(saved) ~= "table" then
        return progress
    end
    for key, levels in pairs(saved) do
        if type(key) == "string" and type(levels) == "table" then
            local kept = {}
            for index, score in pairs(levels) do
                if type(index) == "number" and index >= 1 and index == math.floor(index) and type(score) == "number" and score >= 0 then
                    kept[index] = score
                end
            end
            progress[key] = kept
        end
    end
    return progress
end

-- The practice lessons done: the fewest moves of each chapter, by id.
function State.read_practice_progress(saved)
    local progress = {}
    if type(saved) ~= "table" then
        return progress
    end
    for id, moves in pairs(saved) do
        if type(id) == "string" and type(moves) == "number" and moves >= 0 and moves == math.floor(moves) then
            progress[id] = moves
        end
    end
    return progress
end

-- The results waiting to reach Lichess, without the ones that could not be sent.
function State.read_results(saved)
    local results = {}
    if type(saved) ~= "table" then
        return results
    end
    for _, result in ipairs(SavedState.list(saved, nil, {})) do
        if type(result) == "table" and type(result.id) == "string" and type(result.win) == "boolean" then
            results[#results + 1] = {
                id = result.id,
                win = result.win,
                angle = type(result.angle) == "string" and result.angle or nil,
                rated = result.rated ~= false,
            }
        end
    end
    return results
end

return State
