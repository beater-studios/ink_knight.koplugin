-- Correspondence games kept on the device, so they can be seen and a move made with no network. Each comes from
-- the list of games Lichess sends (/api/account/playing), which has the whole position as a FEN. A move made
-- offline waits with the position it was made in, and goes out only if Lichess still has that position when the
-- network comes back. No KOReader here, so the tests can use it.
local Chess = require("ink_knight/chess")

local Correspondence = {}

-- The list asks for up to this many games: with as many, some may be missing, so none is forgotten for that.
Correspondence.LIST_LIMIT = 50

local function is_id(text)
    return type(text) == "string" and text:match("^[%w]+$") ~= nil and #text <= 16
end

-- The board, the side to move, castling and en passant: what makes two positions the same game for a move.
local function same_position(fen_a, fen_b)
    local a, b = Chess.parse_fen(fen_a), Chess.parse_fen(fen_b)
    return a ~= nil and b ~= nil and Chess.epd(a) == Chess.epd(b)
end
Correspondence.same_position = same_position

-- A game of the list, as kept, or nil for one that is not a standard correspondence game.
function Correspondence.from_playing(entry, now)
    if type(entry) ~= "table" or entry.speed ~= "correspondence" or not is_id(entry.gameId) then
        return nil
    end
    local variant = type(entry.variant) == "table" and entry.variant.key or entry.variant
    if variant ~= nil and variant ~= "standard" then
        return nil
    end
    local color = entry.color == "white" and "w" or entry.color == "black" and "b" or nil
    local position = type(entry.fen) == "string" and Chess.parse_fen(entry.fen)
    if not color or not position then
        return nil
    end
    local opponent = type(entry.opponent) == "table" and entry.opponent or {}
    local last = type(entry.lastMove) == "string" and entry.lastMove:match("^[a-h][1-8][a-h][1-8][qrbn]?$") or nil
    return {
        id = entry.gameId,
        color = color,
        fen = entry.fen,
        last_move = last,
        opponent = type(opponent.username) == "string" and opponent.username or nil,
        seconds_left = type(entry.secondsLeft) == "number" and entry.secondsLeft or nil,
        at = now,
    }
end

-- Brings the kept games in line with a fresh list: new and changed games come in with their position, a move
-- waiting stays on its game, and a game no longer listed leaves, unless the list may be cut short.
function Correspondence.merge(kept, playing, now)
    local by_id = {}
    for _, game in ipairs(kept or {}) do
        by_id[game.id] = game
    end
    local games = {}
    for _, entry in ipairs(playing or {}) do
        local fresh = Correspondence.from_playing(entry, now)
        if fresh then
            local old = by_id[fresh.id]
            fresh.pending = old and old.pending or nil
            -- Same position: the clock counted from the first list that had it is as good, and nothing changed.
            if old and old.fen == fresh.fen and old.seconds_left and old.at then
                fresh.seconds_left, fresh.at = old.seconds_left, old.at
            end
            games[#games + 1] = fresh
            by_id[fresh.id] = nil
        end
    end
    if #(playing or {}) >= Correspondence.LIST_LIMIT then
        for _, game in ipairs(kept or {}) do
            if by_id[game.id] then
                games[#games + 1] = game
            end
        end
    end
    return games
end

-- Whether two lists of kept games hold the same, so an unchanged list is not written again.
function Correspondence.same_games(a, b)
    if #a ~= #b then
        return false
    end
    for index, game in ipairs(a) do
        local other = b[index]
        for _, field in ipairs({ "id", "color", "fen", "last_move", "opponent", "seconds_left", "at" }) do
            if game[field] ~= other[field] then
                return false
            end
        end
        if (game.pending and game.pending.uci) ~= (other.pending and other.pending.uci) then
            return false
        end
    end
    return true
end

local function position_after(pending)
    local position = Chess.parse_fen(pending.fen)
    local after = position and Chess.apply_uci(position, pending.uci)
    return after and Chess.to_fen(after) or nil
end

-- What to do with each move waiting, given a fresh list, before the list replaces the kept positions:
-- { send = { game, ... }, landed = { game, ... }, gone = { game, ... } }. A move goes out only if the game is still
-- listed, it is still the reader's turn and the position is the one the move was made in. One whose game already
-- shows it played had reached Lichess, with the answer lost on the way back. Otherwise it is dropped.
function Correspondence.plan(kept, playing)
    local listed = {}
    for _, entry in ipairs(playing or {}) do
        if type(entry) == "table" and entry.gameId then
            listed[entry.gameId] = entry
        end
    end
    local plan = { send = {}, landed = {}, gone = {} }
    for _, game in ipairs(kept or {}) do
        if game.pending then
            local entry = listed[game.id]
            local after = entry and position_after(game.pending)
            if entry and entry.isMyTurn == true and same_position(entry.fen, game.pending.fen) then
                plan.send[#plan.send + 1] = game
            elseif after and same_position(entry.fen, after) then
                plan.landed[#plan.landed + 1] = game
            elseif entry or #(playing or {}) < Correspondence.LIST_LIMIT then
                plan.gone[#plan.gone + 1] = game
            end
        end
    end
    return plan
end

function Correspondence.find(games, id)
    for index, game in ipairs(games or {}) do
        if game.id == id then
            return game, index
        end
    end
    return nil
end

function Correspondence.is_my_turn(game)
    local position = Chess.parse_fen(game.fen)
    return position ~= nil and position.turn == game.color
end

-- The position on the board: the one Lichess sent, with the move waiting played on it.
function Correspondence.position(game)
    local position = Chess.parse_fen(game.fen)
    if position and game.pending then
        local after, move = Chess.apply_uci(position, game.pending.uci)
        return after, move
    end
    local last = game.last_move and position and Chess.parse_uci(position, game.last_move) or nil
    return position, last
end

-- Keeps move, legal in the position Lichess sent, as the move waiting. Returns false when it cannot be played.
function Correspondence.play(game, move)
    local position = Chess.parse_fen(game.fen)
    if not position or game.pending or position.turn ~= game.color then
        return false
    end
    for _, legal in ipairs(Chess.legal_moves(position)) do
        if legal.from == move.from and legal.to == move.to and legal.promotion == move.promotion then
            game.pending = { uci = Chess.move_to_uci(legal), san = Chess.to_san(position, legal), fen = game.fen }
            return true
        end
    end
    return false
end

-- The time left on the reader's clock, counted down from when the list came while it is the reader's turn.
function Correspondence.seconds_left(game, now)
    if not game.seconds_left then
        return nil
    end
    if not Correspondence.is_my_turn(game) then
        return game.seconds_left
    end
    return math.max(0, game.seconds_left - math.max(0, now - (game.at or now)))
end

return Correspondence
