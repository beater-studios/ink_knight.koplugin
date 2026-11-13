-- The state of one game, fed by the lines of the Lichess stream. It knows nothing about the screen or the network.
local Api = require("ink_knight/api")
local Chess = require("ink_knight/chess")

local Game = {}
Game.__index = Game

local ACTIVE = { created = true, started = true }
-- Lichess sends a huge number instead of a clock when a game has none running.
local NO_CLOCK_MS = 2000000000

function Game.new(id, my_id)
    return setmetatable({
        id = id,
        my_id = my_id and my_id:lower() or nil,
        moves = "",
        status = "started",
        position = Chess.parse_fen(Chess.START_FEN),
        clock_at = 0,
    }, Game)
end

-- nil for a player who is not signed in, whom Lichess sends with no name: the screens call them anonymous.
local function name_of(player)
    if not player then
        return nil
    end
    if player.aiLevel then
        return "Stockfish " .. player.aiLevel
    end
    return player.name or player.id
end

function Game:apply_state(state, now)
    if state.moves and state.moves ~= self.moves then
        local position, last = Chess.from_moves(self.initial_fen, state.moves)
        if position then
            self.moves, self.position, self.last_move = state.moves, position, last
        end
    end
    if state.wtime then self.wtime = state.wtime end
    if state.btime then self.btime = state.btime end
    if state.status then self.status = state.status end
    self.winner = state.winner
    self.white_offers_draw, self.black_offers_draw = state.wdraw == true, state.bdraw == true
    self.white_offers_takeback, self.black_offers_takeback = state.wtakeback == true, state.btakeback == true
    self.clock_at = now or 0
end

-- event: a decoded line. now: the time of arrival, in seconds, from which the running clock counts.
function Game:on_event(event, now)
    if event.type == "gameFull" then
        self.white, self.black = event.white or {}, event.black or {}
        self.white_name, self.black_name = name_of(event.white), name_of(event.black)
        -- The computer has a level, which already goes in its name, instead of a rating.
        self.white_rating = not self.white.aiLevel and self.white.rating or nil
        self.black_rating = not self.black.aiLevel and self.black.rating or nil
        self.speed = event.speed
        self.rated = event.rated == true
        self.variant = event.variant and event.variant.key or "standard"
        self.clock = event.clock
        self.days_per_turn = event.daysPerTurn
        self.initial_fen = event.initialFen
        self.position = Chess.parse_fen((self.initial_fen == nil or self.initial_fen == "startpos") and Chess.START_FEN or self.initial_fen) or self.position
        self.moves = ""
        self.last_move = nil
        if self.my_id then
            if self.white.id and self.white.id:lower() == self.my_id then
                self.my_color = "w"
            elseif self.black.id and self.black.id:lower() == self.my_id then
                self.my_color = "b"
            end
        end
        self.loaded = true
        self:apply_state(event.state or {}, now)
    elseif event.type == "gameState" then
        self:apply_state(event, now)
    elseif event.type == "opponentGone" then
        self.opponent_gone = event.gone == true
        self.claim_in_seconds = event.claimWinInSeconds
    end
end

function Game:is_active()
    return ACTIVE[self.status] == true
end

function Game:is_my_turn()
    return self:is_active() and self.my_color == self.position.turn
end

function Game:is_supported()
    return self.variant == nil or self.variant == "standard" or self.variant == "fromPosition"
end

function Game:move_count()
    local _, count = self.moves:gsub("%S+", "")
    return count
end

-- Whether there is a clock that a person must keep an eye on, unlike correspondence.
function Game:is_live()
    return self.speed ~= "correspondence" and self.clock ~= nil
end

-- Milliseconds left for a color, or nil without a running clock.
function Game:time_left(color, now)
    local base = color == "w" and self.wtime or self.btime
    if not base or base >= NO_CLOCK_MS then
        return nil
    end
    -- The clock only starts after both players have moved.
    if self:is_active() and self.position.turn == color and self:move_count() >= 2 then
        return math.max(0, base - ((now or self.clock_at) - self.clock_at) * 1000)
    end
    return base
end

-- What goes beside a name: a running clock, or the days left when a move can take days.
function Game:clock_text(color, now)
    local left = self:time_left(color, now)
    if not left then
        return ""
    end
    return self:is_live() and Game.format_clock(left) or Api.format_left(left / 1000)
end

function Game:opponent_offers_draw()
    if self.my_color == "w" then return self.black_offers_draw end
    return self.white_offers_draw
end

function Game:i_offered_draw()
    if self.my_color == "w" then return self.white_offers_draw end
    return self.black_offers_draw
end

function Game:i_offered_takeback()
    if self.my_color == "w" then return self.white_offers_takeback end
    return self.black_offers_takeback
end

-- Lichess takes the usual draw request as a claim when the position has happened three times.
function Game:can_claim_repetition()
    if self.repetitions_of ~= self.moves then
        self.repetitions_of = self.moves
        self.repetitions = Chess.repetitions(self.initial_fen, self.moves)
    end
    return self.repetitions >= 3
end

function Game:opponent()
    if self.my_color == "b" then return self.white end
    return self.black
end

-- There is no rematch in the API, so it is a new challenge with the same time and the colors swapped.
-- Returns the request, and whether it starts right away, as a game against the computer does.
function Game:rematch_request()
    local opponent = self:opponent()
    if not opponent or not self:is_supported() then
        return nil
    end
    local color = self.my_color == "w" and "black" or "white"
    local minutes = self.clock and self.clock.initial and self.clock.initial / 60000
    local increment = self.clock and self.clock.increment and self.clock.increment / 1000 or 0
    if opponent.aiLevel then
        return Api.challenge_ai(opponent.aiLevel, minutes, increment, color, self.days_per_turn), true
    end
    if not Api.is_safe_id(opponent.id) then
        return nil
    end
    if minutes then
        return Api.challenge_clock(opponent.id, minutes, increment, self.rated, color), false
    elseif self.days_per_turn then
        return Api.challenge_days(opponent.id, self.days_per_turn, self.rated, color), false
    end
    return Api.challenge_no_limit(opponent.id, color), false
end

function Game:opponent_offers_takeback()
    if self.my_color == "w" then return self.black_offers_takeback end
    return self.white_offers_takeback
end

-- "win", "loss", "draw" or "aborted" for a finished game, and nil while it goes on.
function Game:outcome()
    if self:is_active() then
        return nil
    end
    if self.status == "aborted" or self.status == "noStart" then
        return "aborted"
    end
    if not self.winner then
        return "draw"
    end
    local me = self.my_color == "w" and "white" or "black"
    return self.winner == me and "win" or "loss"
end

local ENDINGS = {
    win = { mate = "ending_win_mate", resign = "ending_win_resign", outoftime = "ending_win_time", timeout = "ending_win_left" },
    loss = { mate = "ending_loss_mate", resign = "ending_loss_resign", outoftime = "ending_loss_time", timeout = "ending_loss_left" },
    draw = {
        stalemate = "ending_draw_stalemate",
        insufficient = "ending_draw_insufficient",
        fifty = "ending_draw_fifty",
        repetition = "ending_draw_repetition",
    },
}

-- The name of the sentence that tells how a game ended. A whole sentence reads better than two pieces joined.
function Game.ending_key(outcome, status)
    return ENDINGS[outcome] and ENDINGS[outcome][status] or ("outcome_" .. outcome)
end

-- With a question mark when Lichess is not sure of the rating yet, as on the site. nil for the computer.
function Game:rating_text(color)
    local rating, player = self.black_rating, self.black
    if color == "w" then
        rating, player = self.white_rating, self.white
    end
    if not rating then
        return nil
    end
    return tostring(rating) .. (player and player.provisional and "?" or "")
end

-- anonymous: what to call a player who is not signed in, whom Lichess sends with no name.
function Game.player_name(player, anonymous)
    if player and player.aiLevel then
        return "Stockfish " .. player.aiLevel
    end
    return player and (player.user and player.user.name or player.name) or anonymous or "?"
end

local function player_id_of(player)
    return player and player.user and player.user.id
end

-- "white" or "black" when my_id played the game, nil otherwise.
function Game.color_of(game, my_id)
    local players = type(game) == "table" and type(game.players) == "table" and game.players or {}
    if my_id and player_id_of(players.white) == my_id then
        return "white"
    elseif my_id and player_id_of(players.black) == my_id then
        return "black"
    end
end

-- What a row of finished games says, from the side of player_id. Only the reader is called "you":
-- the list may be someone else's, and a favorite may be a game neither of them played.
-- Returns the title, the detail and whether player_id had the black pieces.
function Game.past_summary(s, game, player_id, my_id)
    local players = game.players or {}
    local white, black = Game.player_name(players.white, s.anonymous), Game.player_name(players.black, s.anonymous)
    local on_white = player_id ~= nil and player_id_of(players.white) == player_id
    local on_black = player_id ~= nil and player_id_of(players.black) == player_id
    local mine = player_id ~= nil and player_id == my_id
    local title
    if not on_white and not on_black then
        title = white .. " x " .. black
    elseif mine then
        title = on_black and white or black
    else
        title = string.format(s.played_against, on_black and white or black)
    end
    local detail
    if game.status == "aborted" or game.status == "noStart" then
        detail = s.outcome_aborted
    elseif not game.winner then
        detail = s.outcome_draw
    elseif my_id and player_id_of(players[game.winner]) == my_id then
        detail = s.outcome_win
    elseif mine and (on_white or on_black) then
        detail = s.outcome_loss
    else
        detail = string.format(s.player_won, game.winner == "white" and white or black)
    end
    return title, detail, on_black
end

function Game.format_clock(ms)
    if not ms then
        return ""
    end
    local total = math.ceil(ms / 1000)
    local hours, minutes, seconds = math.floor(total / 3600), math.floor(total / 60) % 60, total % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, seconds)
    end
    return string.format("%d:%02d", minutes, seconds)
end

local function count(value)
    return type(value) == "number" and value >= 0 and math.floor(value) or nil
end

-- { white = { accuracy, inaccuracy, mistake, blunder, acpl }, black = ..., middle, ending }, nil for a game the site
-- did not analyze.
function Game.analysis_summary(game)
    local players = type(game) == "table" and type(game.players) == "table" and game.players or {}
    local summary = {}
    for _, color in ipairs({ "white", "black" }) do
        local player = type(players[color]) == "table" and players[color] or {}
        local analysis = type(player.analysis) == "table" and player.analysis or {}
        local inaccuracy, mistake, blunder = count(analysis.inaccuracy), count(analysis.mistake), count(analysis.blunder)
        if inaccuracy and mistake and blunder then
            local phases = type(analysis.phases) == "table" and analysis.phases or {}
            local opening, middlegame, endgame = count(phases.opening), count(phases.middlegame), count(phases.endgame)
            summary[color] = {
                accuracy = count(analysis.accuracy), inaccuracy = inaccuracy, mistake = mistake, blunder = blunder, acpl = count(analysis.acpl),
                phases = opening and middlegame and endgame and { opening = opening, middlegame = middlegame, endgame = endgame } or nil,
            }
        end
    end
    if not summary.white or not summary.black then
        return nil
    end
    local division = type(game.division) == "table" and game.division or {}
    summary.middle, summary.ending = count(division.middle), count(division["end"])
    return summary
end

return Game
