-- A game on Lichess: the stream feeds the state, and each action is one request.
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Api = require("ink_knight/api")
local Awake = require("ink_knight/ui/awake")
local BoardScreen = require("ink_knight/ui/board_screen")
local Chess = require("ink_knight/chess")
local Game = require("ink_knight/game")
local Players = require("ink_knight/ui/players")

local LiveGame = {}
LiveGame.__index = LiveGame

local RECONNECT_MIN, RECONNECT_MAX = 3, 30

function LiveGame.open(app, id)
    local self = setmetatable({ app = app, id = id, s = app.strings, game = Game.new(id, app.my_id), backoff = RECONNECT_MIN }, LiveGame)
    self.screen = BoardScreen:new{
        state = { status = self.s.loading, buttons = { { id = "back", label = self.s.back } } },
        on_square = function(square) self:on_square(square) end,
        on_button = function(button) self:on_button(button) end,
        on_close_request = function() self:request_close() end,
        on_closed = function() self:closed() end,
        on_suspend = function() self:suspend() end,
        on_resume = function() self:resume() end,
    }
    self.clock_tick = function() self:tick_clock() end
    UIManager:show(self.screen)
    self:connect()
    return self
end

function LiveGame:connect()
    if self.stream or self.is_closed then
        return
    end
    self.stream = self.app.net:stream(Api.stream_game(self.id), function(line)
        self:on_line(line)
    end, function()
        self.stream = nil
        self:connection_ended()
    end)
end

function LiveGame:on_line(line)
    local event = self.app.decode(line)
    if not event then
        return
    end
    if event.type == "error" or event.error then
        logger.warn("Ink Knight: the game stream reported an error")
        return
    end
    self.connected = true
    self.backoff = RECONNECT_MIN
    -- A chat line changes nothing on the board, and must not undo a move that is on its way.
    if event.type ~= "gameFull" and event.type ~= "gameState" and event.type ~= "opponentGone" then
        return
    end
    local moves_before = self.game.moves
    self.game:on_event(event, os.time())
    -- Only a new list of moves replaces the move on its way. A state that just brings an offer, while the move
    -- is still being sent, would otherwise put the piece back and let a second move go out.
    if event.type == "gameFull" or self.game.moves ~= moves_before or not self.game:is_active() then
        self.optimistic, self.optimistic_move = nil, nil
        self.pending = nil
        self.selected, self.targets = nil, nil
    end
    self:update_awake()
    self:render()
    self:schedule_clock()
end

-- The stream ends by itself when the game is over. If it ended before that, the network dropped.
function LiveGame:connection_ended()
    if self.is_closed or self.suspended or (self.game.loaded and not self.game:is_active()) then
        return
    end
    self.connected = false
    self:render()
    UIManager:scheduleIn(self.backoff, function()
        if not self.is_closed and not self.suspended then
            self:connect()
        end
    end)
    self.backoff = math.min(RECONNECT_MAX, self.backoff * 2)
end

function LiveGame:update_awake()
    Awake.set(self.game:is_active() and self.game:is_live())
end

function LiveGame:outcome_text()
    local s, game = self.s, self.game
    local outcome = game:outcome()
    if not outcome then
        return nil
    end
    return s[Game.ending_key(outcome, game.status)]
end

function LiveGame:status_text()
    local s, game = self.s, self.game
    if not game.loaded then
        return self.connected == false and s.reconnecting or s.loading
    end
    if not game:is_supported() then
        return s.variant_game_unsupported
    end
    local outcome = self:outcome_text()
    if outcome then
        return outcome
    end
    if self.connected == false then
        return s.reconnecting
    end
    if game.opponent_gone then
        return string.format(s.status_opponent_gone, self:opponent_name())
    end
    if self.pending then
        return s.confirm .. "?"
    end
    if Chess.in_check(game.position) then
        return s.status_check
    end
    if game:is_my_turn() then
        return s.status_your_turn
    end
    return string.format(s.status_their_turn, self:opponent_name())
end

function LiveGame:opponent_name()
    return self.game.my_color == "b" and self.game.white_name or self.game.black_name or "?"
end

function LiveGame:buttons()
    local s, game = self.s, self.game
    local list = { { id = "back", label = s.back } }
    if self.pending then
        return { { id = "cancel_move", label = s.cancel }, { id = "confirm_move", label = s.confirm } }
    end
    if not game.loaded then
        return list
    end
    if not game:is_active() then
        if game:rematch_request() then
            list[#list + 1] = { id = "rematch", label = s.rematch }
        end
        if game.opponent_id then
            list[#list + 1] = { id = "profile", label = s.view_profile }
        end
        return list
    end
    if game:opponent_offers_draw() then
        list[#list + 1] = { id = "draw_yes", label = s.accept_draw }
        list[#list + 1] = { id = "draw_no", label = s.decline_draw }
        return list
    end
    if game:opponent_offers_takeback() then
        list[#list + 1] = { id = "takeback_yes", label = s.accept_takeback }
        list[#list + 1] = { id = "takeback_no", label = s.decline_takeback }
        return list
    end
    local actions = self:actions()
    -- Only what fits goes on the bar: the rest waits behind one button.
    self.more_actions = nil
    if #actions <= 3 then
        for _, action in ipairs(actions) do
            list[#list + 1] = action
        end
        return list
    end
    list[#list + 1] = actions[1]
    list[#list + 1] = actions[2]
    list[#list + 1] = { id = "more", label = s.more }
    self.more_actions = { unpack(actions, 3) }
    return list
end

-- What can be done in a game under way, most urgent first.
function LiveGame:actions()
    local s, game = self.s, self.game
    local list = {}
    if game.opponent_gone and game.claim_in_seconds == 0 then
        list[#list + 1] = { id = "claim", label = s.claim_victory }
        list[#list + 1] = { id = "claim_draw", label = s.claim_draw }
    end
    if game:move_count() < 2 then
        list[#list + 1] = { id = "abort", label = s.abort }
    else
        local draw_label = game:can_claim_repetition() and s.draw_repetition or (game:i_offered_draw() and s.draw_offered or s.offer_draw)
        list[#list + 1] = { id = "draw", label = draw_label }
        list[#list + 1] = { id = "resign", label = s.resign }
        list[#list + 1] = { id = "takeback", label = game:i_offered_takeback() and s.takeback_asked or s.ask_takeback }
    end
    local opponent = game:opponent()
    if game:is_live() and opponent and not opponent.aiLevel then
        list[#list + 1] = { id = "give_time", label = string.format(s.give_time, Api.GIVE_TIME_SECONDS) }
    end
    if game.opponent_id then
        list[#list + 1] = { id = "profile", label = s.view_profile }
    end
    return list
end

function LiveGame:player_info(color, now)
    local game = self.game
    local name = color == "w" and game.white_name or game.black_name
    local rating = game:rating_text(color)
    return {
        name = (name or "?") .. (rating and (" (" .. rating .. ")") or ""),
        clock = game:clock_text(color, now),
        active = game:is_active() and game.position.turn == color,
    }
end

function LiveGame:render(what)
    local game = self.game
    local me = game.my_color or "w"
    local other = me == "w" and "b" or "w"
    local now = os.time()
    if game.white and not game.opponent_id then
        local opponent = me == "w" and game.black or game.white
        game.opponent_id = opponent and opponent.id
    end
    self.screen:show({
        position = self.optimistic or game.position,
        last_move = self.optimistic_move or game.last_move,
        flipped = me == "b",
        selected = self.selected,
        targets = self.targets,
        top = self:player_info(other, now),
        bottom = self:player_info(me, now),
        status = self:status_text(),
        buttons = self:buttons(),
    }, what)
end

-- The clock only needs seconds when it is short, which saves refreshes and battery.
function LiveGame:schedule_clock()
    UIManager:unschedule(self.clock_tick)
    local game = self.game
    if self.is_closed or not game:is_active() or not game:is_live() or game:move_count() < 2 then
        return
    end
    local left = game:time_left(game.position.turn, os.time()) or 0
    UIManager:scheduleIn(left < 60000 and 1 or 10, self.clock_tick)
end

function LiveGame:tick_clock()
    if self.is_closed then
        return
    end
    local now = os.time()
    local me = self.game.my_color or "w"
    self.screen.state.top = self:player_info(me == "w" and "b" or "w", now)
    self.screen.state.bottom = self:player_info(me, now)
    self.screen:refresh("clock")
    self:schedule_clock()
end

function LiveGame:on_square(square)
    local game = self.game
    if self.pending or not game.loaded or not game:is_my_turn() or not game:is_supported() or self.optimistic then
        return
    end
    if self.targets and self.targets[square] then
        self:choose_move(self.targets[square])
        return
    end
    local piece = game.position.board[square]
    if piece and (piece == piece:upper()) == (game.my_color == "w") then
        self.selected = square
        self.targets = Chess.targets_from(game.position, square)
    else
        self.selected, self.targets = nil, nil
    end
    self:render()
end

function LiveGame:choose_move(moves)
    if #moves == 1 then
        self:prepare_move(moves[1])
    else
        self.app:choose_promotion(moves, function(move) self:prepare_move(move) end)
    end
end

function LiveGame:prepare_move(move)
    self.selected, self.targets = nil, nil
    self.optimistic = Chess.play(self.game.position, move)
    self.optimistic_move = move
    if self.app.settings:isTrue("confirm_moves") then
        self.pending = move
        self:render()
    else
        self:send_move(move)
    end
end

function LiveGame:send_move(move)
    self.pending = nil
    self:render()
    self.app.net:request(Api.move(self.id, Chess.move_to_uci(move)), function(status)
        if status ~= 200 then
            self:revert_move()
            self:report(status)
        end
    end)
end

function LiveGame:revert_move()
    self.optimistic, self.optimistic_move, self.pending = nil, nil, nil
    if not self.is_closed then
        self:render()
    end
end

function LiveGame:report(status)
    self.app:info(self.app:error_text(status))
end

function LiveGame:simple_action(request)
    self.app.net:request(request, function(status)
        if status ~= 200 then
            self:report(status)
        end
    end)
end

function LiveGame:confirm_action(question, request, ok_text)
    self.app:ask{
        title = question,
        ok_text = ok_text,
        on_ok = function() self:simple_action(request) end,
    }
end

function LiveGame:on_button(button)
    local s = self.s
    if button == "back" then
        self:request_close()
    elseif button == "confirm_move" then
        self:send_move(self.pending)
    elseif button == "cancel_move" then
        self:revert_move()
    elseif button == "more" then
        local rows = {}
        for _, action in ipairs(self.more_actions or {}) do
            rows[#rows + 1] = { text = action.label, callback = function() self:on_button(action.id) end }
        end
        self.app:choose(s.more, rows, { close_on_tap = true })
    elseif button == "draw" then
        if self.game:can_claim_repetition() or not self.game:i_offered_draw() then
            self:simple_action(Api.draw(self.id, true))
        end
    elseif button == "takeback" then
        if not self.game:i_offered_takeback() then
            self:simple_action(Api.takeback(self.id, true))
        end
    elseif button == "give_time" then
        self.app:with_feature("give_time", function()
            self:simple_action(Api.give_time(self.id, Api.GIVE_TIME_SECONDS))
        end)
    elseif button == "claim_draw" then
        self:simple_action(Api.claim_draw(self.id))
    elseif button == "rematch" then
        local game = self.game
        UIManager:close(self.screen)
        self.app:send_rematch(game, self:opponent_name())
    elseif button == "profile" then
        Players.show(self.app, self.game.opponent_id)
    elseif button == "draw_yes" then
        self:simple_action(Api.draw(self.id, true))
    elseif button == "draw_no" then
        self:simple_action(Api.draw(self.id, false))
    elseif button == "takeback_yes" then
        self:simple_action(Api.takeback(self.id, true))
    elseif button == "takeback_no" then
        self:simple_action(Api.takeback(self.id, false))
    elseif button == "resign" then
        self:confirm_action(s.resign_question, Api.resign(self.id), s.resign)
    elseif button == "abort" then
        self:confirm_action(s.abort_question, Api.abort(self.id), s.abort)
    elseif button == "claim" then
        self:simple_action(Api.claim_victory(self.id))
    end
end

-- Leaving a game with a running clock costs time, so it asks first.
function LiveGame:request_close()
    local game = self.game
    if game:is_active() and game:is_live() and game:move_count() >= 1 then
        self.app:ask{
            title = self.s.leave_live_question,
            ok_text = self.s.leave,
            cancel_text = self.s.stay,
            on_ok = function() UIManager:close(self.screen) end,
        }
    else
        UIManager:close(self.screen)
    end
end

function LiveGame:disconnect()
    if self.stream then
        self.app.net:close_stream(self.stream)
        self.stream = nil
    end
end

function LiveGame:suspend()
    self.suspended = true
    self:disconnect()
    UIManager:unschedule(self.clock_tick)
end

function LiveGame:resume()
    self.suspended = false
    self.backoff = RECONNECT_MIN
    self:connect()
end

function LiveGame:closed()
    self.is_closed = true
    UIManager:unschedule(self.clock_tick)
    self:disconnect()
    Awake.set(false)
    self.app:game_closed(self.id)
end

return LiveGame
