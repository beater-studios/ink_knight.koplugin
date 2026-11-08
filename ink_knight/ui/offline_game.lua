-- A game with no network, against the small engine or between two people taking turns on the same device. It is
-- saved after each move, each kind under its own key, so it can be continued later.
local UIManager = require("ui/uimanager")
local socket = require("socket")

local BoardScreen = require("ink_knight/ui/board_screen")
local Chess = require("ink_knight/chess")
local Engine = require("ink_knight/engine")
local Game = require("ink_knight/game")
local MoveList = require("ink_knight/ui/move_list")

local OfflineGame = {}
OfflineGame.__index = OfflineGame

-- How long the engine works before giving the screen its turn.
local SLICE_SECONDS = 0.04
local SLICE_PAUSE = 0.02

function OfflineGame.open(app, opts)
    local self = setmetatable({ app = app, s = app.strings }, OfflineGame)
    self.two_players = opts.two_players == true
    self.save_key = self.two_players and "two_player_game" or "offline_game"
    local saved = opts.resume and app.settings:readSetting(self.save_key)
    if self.two_players then
        -- No side is the reader's: whoever is to move plays, and the board turns only when asked.
        self.flipped = saved and saved.flipped or false
    else
        self.level = saved and saved.level or opts.level or 1
        -- "random", "white" or "black": kept for the next game, so playing again keeps the choice.
        self.color_choice = saved and saved.color_choice or opts.color_choice or "random"
        local chosen = self.color_choice == "white" and "w" or self.color_choice == "black" and "b" or nil
        self.my_color = saved and saved.my_color or chosen or (math.random(2) == 1 and "w" or "b")
        self.flipped = self.my_color == "b"
    end
    self.moves = saved and saved.moves or ""
    self.position, self.last_move = Chess.from_moves(nil, self.moves)
    self.seen = {}
    self:count_positions()
    self.screen = BoardScreen:new{
        state = { flipped = self.flipped },
        on_square = function(square) self:on_square(square) end,
        on_button = function(button) self:on_button(button) end,
        on_closed = function() self:closed() end,
    }
    UIManager:show(self.screen)
    self:check_end()
    self:render("full")
    self:maybe_think()
    return self
end

-- Three times the same position is a draw, so each one is counted from the start of the game.
function OfflineGame:count_positions()
    local position = Chess.parse_fen(Chess.START_FEN)
    self.seen = { [Chess.position_key(position)] = 1 }
    for uci in self.moves:gmatch("%S+") do
        position = Chess.apply_uci(position, uci)
        local key = Chess.position_key(position)
        self.seen[key] = (self.seen[key] or 0) + 1
    end
end

function OfflineGame:save()
    if self:is_over() then
        self.app.settings:delSetting(self.save_key)
    elseif self.two_players then
        self.app.settings:saveSetting(self.save_key, { flipped = self.flipped, moves = self.moves })
    else
        self.app.settings:saveSetting(self.save_key, { level = self.level, my_color = self.my_color, color_choice = self.color_choice, moves = self.moves })
    end
    self.app.settings:flush()
end

function OfflineGame:check_end()
    local ending = Chess.ending(self.position)
    if not ending and (self.seen[Chess.position_key(self.position)] or 0) >= 3 then
        ending = "repetition"
    end
    self.ending = ending
end

function OfflineGame:status_text()
    local s = self.s
    local turn = self.position.turn
    if self.resigned then
        return self.two_players and s["local_resigned_" .. self.resigned_color] or s.ending_loss_resign
    end
    if self.ending == "mate" then
        if self.two_players then
            return s["local_mate_" .. (turn == "w" and "b" or "w")]
        end
        return turn == self.my_color and s.ending_loss_mate or s.ending_win_mate
    elseif self.ending then
        return s[Game.ending_key("draw", self.ending)]
    end
    if self.two_players then
        return s[(Chess.in_check(self.position) and "local_check_" or "local_turn_") .. turn]
    end
    if self.thinking then
        return s.status_thinking
    end
    if self.hinting then
        return s.hint_thinking
    end
    if self.hint_text then
        return self.hint_text
    end
    if Chess.in_check(self.position) then
        return s.status_check
    end
    return s.status_your_turn
end

-- The moves after undo: the last one alone between two people, or back to the reader's last move against the engine.
function OfflineGame:moves_after_undo()
    if self.resigned then
        return nil
    end
    if self.two_players then
        return self.moves ~= "" and (self.moves:match("^(.*)%s+%S+$") or "") or nil
    end
    return Chess.take_back(self.moves, self.my_color)
end

function OfflineGame:can_undo()
    return self:moves_after_undo() ~= nil
end

function OfflineGame:can_hint()
    return not self.two_players and not self:is_over() and not self.thinking and not self.hinting
        and self.position.turn == self.my_color
end

function OfflineGame:render(what)
    local s = self.s
    local buttons = { { id = "back", label = s.back } }
    if self:can_undo() then
        buttons[#buttons + 1] = { id = "undo", label = s.undo }
    end
    if not self:is_over() and self:can_hint() then
        buttons[#buttons + 1] = { id = "hint", label = s.hint }
    end
    if self.moves ~= "" then
        buttons[#buttons + 1] = { id = "moves", label = s.moves }
    end
    if self.two_players then
        buttons[#buttons + 1] = { id = "flip", label = s.flip_board }
    end
    if self:is_over() then
        buttons[#buttons + 1] = { id = "again", label = s.new_game_again }
    else
        buttons[#buttons + 1] = { id = "resign", label = s.resign }
    end
    local top, bottom = { name = string.format(s.offline_level, self.level or 1) }, { name = s.you }
    if self.two_players then
        top, bottom = { name = s.color_black }, { name = s.color_white }
        if self.flipped then
            top, bottom = bottom, top
        end
    end
    self.screen:show({
        flipped = self.flipped,
        position = self.position,
        last_move = self.last_move,
        selected = self.selected,
        targets = self.targets,
        top = top,
        bottom = bottom,
        status = self:status_text(),
        buttons = buttons,
    }, what)
end

function OfflineGame:is_over()
    return self.ending ~= nil or self.resigned == true
end

function OfflineGame:apply(move)
    self.position = Chess.play(self.position, move)
    self.last_move = move
    local uci = Chess.move_to_uci(move)
    self.moves = self.moves == "" and uci or (self.moves .. " " .. uci)
    local key = Chess.position_key(self.position)
    self.seen[key] = (self.seen[key] or 0) + 1
    self:check_end()
    self:save()
end

-- Runs a search a slice at a time, so the screen keeps answering. Whoever replaces or clears self.search cancels
-- it, and then on_done is not called. A game that ended meanwhile gets on_done(nil).
function OfflineGame:run_search(opts, on_done)
    -- os.time() only counts whole seconds, which would cut up to a second from each level's time to think.
    opts.now = socket.gettime
    local search = Engine.search(self.position, opts)
    self.search = search
    local function work()
        if self.is_closed or self.search ~= search then
            return
        end
        if self:is_over() then
            self.search = nil
            on_done(nil)
            return
        end
        local until_time = os.clock() + SLICE_SECONDS
        while os.clock() < until_time do
            local ok, result = coroutine.resume(search)
            if not ok then
                error(result)
            end
            if coroutine.status(search) == "dead" then
                self.search = nil
                on_done(result)
                return
            end
        end
        UIManager:scheduleIn(SLICE_PAUSE, work)
    end
    UIManager:scheduleIn(SLICE_PAUSE, work)
end

-- Stops the computer or a hint, so nothing found for a position that is gone lands on the board.
function OfflineGame:stop_search()
    self.search, self.thinking, self.hinting = nil, false, false
end

function OfflineGame:maybe_think()
    if self.two_players or self:is_over() or self.position.turn == self.my_color or self.thinking then
        return
    end
    self.thinking = true
    self:render()
    self:run_search({ level = self.level }, function(move)
        self.thinking = false
        if move then
            self:apply(move)
        end
        self:render()
    end)
end

-- Marks the piece and its square, so a tap on the square plays it, and names the move below the board.
function OfflineGame:hint()
    if not self:can_hint() then
        return
    end
    local position = self.position
    self.hinting = true
    self.selected, self.targets, self.hint_text = nil, nil, nil
    self:render()
    self:run_search({ limits = Engine.HINT }, function(move)
        self.hinting = false
        if move and self.position == position then
            self.selected = move.from
            self.targets = { [move.to] = Chess.targets_from(position, move.from)[move.to] }
            self.hint_text = string.format(self.s.hint_status, Chess.to_san(position, move))
        end
        self:render()
    end)
end

-- Back to the reader's last move: the computer's answer to it goes too, and so does a search under way.
function OfflineGame:undo()
    local moves = self:moves_after_undo()
    if not moves then
        return
    end
    self:stop_search()
    self.moves = moves
    self.position, self.last_move = Chess.from_moves(nil, moves)
    self:count_positions()
    self:check_end()
    self.selected, self.targets, self.hint_text = nil, nil, nil
    self:save()
    self:render()
end

function OfflineGame:on_square(square)
    -- Between two people, whoever is to move plays.
    local mover = self.two_players and self.position.turn or self.my_color
    if self:is_over() or self.thinking or self.hinting or self.position.turn ~= mover then
        return
    end
    self.hint_text = nil
    if self.targets and self.targets[square] then
        local moves = self.targets[square]
        self.selected, self.targets = nil, nil
        if #moves == 1 then
            self:apply(moves[1])
            self:maybe_think()
            self:render()
        else
            self:choose_promotion(moves)
        end
        return
    end
    local piece = self.position.board[square]
    if piece and (piece == piece:upper()) == (mover == "w") then
        self.selected = square
        self.targets = Chess.targets_from(self.position, square)
    else
        self.selected, self.targets = nil, nil
    end
    self:render()
end

function OfflineGame:choose_promotion(moves)
    self.app:choose_promotion(moves, function(move)
        self:apply(move)
        self:maybe_think()
        self:render()
    end)
end

function OfflineGame:on_button(button)
    if button == "back" then
        UIManager:close(self.screen)
    elseif button == "resign" then
        local turn = self.position.turn
        self.app:ask{
            title = self.two_players and self.s["local_resign_question_" .. turn] or self.s.resign_question,
            ok_text = self.s.resign,
            on_ok = function()
                self.resigned = true
                self.resigned_color = turn
                self:stop_search()
                self.selected, self.targets, self.hint_text = nil, nil, nil
                self:save()
                self:render()
            end,
        }
    elseif button == "undo" then
        self:undo()
    elseif button == "hint" then
        self:hint()
    elseif button == "flip" then
        self.flipped = not self.flipped
        self.selected, self.targets = nil, nil
        self:save()
        self:render()
    elseif button == "moves" then
        self.san_cache = self.san_cache or {}
        MoveList.show(self.app, Chess.san_list(nil, self.moves, self.san_cache))
    elseif button == "again" then
        UIManager:close(self.screen)
        if self.two_players then
            OfflineGame.open(self.app, { two_players = true })
        else
            OfflineGame.open(self.app, { level = self.level, color_choice = self.color_choice })
        end
    end
end

function OfflineGame:closed()
    self.is_closed = true
    self.app:refresh_list()
end

return OfflineGame
