-- A game against the small engine, with no network. It is saved after each move, so it can be continued later.
local UIManager = require("ui/uimanager")
local socket = require("socket")

local BoardScreen = require("ink_knight/ui/board_screen")
local Chess = require("ink_knight/chess")
local Engine = require("ink_knight/engine")
local Game = require("ink_knight/game")

local OfflineGame = {}
OfflineGame.__index = OfflineGame

-- How long the engine works before giving the screen its turn.
local SLICE_SECONDS = 0.04
local SLICE_PAUSE = 0.02

function OfflineGame.open(app, opts)
    local self = setmetatable({ app = app, s = app.strings }, OfflineGame)
    local saved = opts.resume and app.settings:readSetting("offline_game")
    self.level = saved and saved.level or opts.level or 1
    self.my_color = saved and saved.my_color or opts.my_color or (math.random(2) == 1 and "w" or "b")
    self.moves = saved and saved.moves or ""
    self.position, self.last_move = Chess.from_moves(nil, self.moves)
    self.seen = {}
    self:count_positions()
    self.screen = BoardScreen:new{
        state = { flipped = self.my_color == "b" },
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
        self.app.settings:delSetting("offline_game")
    else
        self.app.settings:saveSetting("offline_game", { level = self.level, my_color = self.my_color, moves = self.moves })
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
    if self.resigned then
        return s.ending_loss_resign
    end
    if self.ending == "mate" then
        return self.position.turn == self.my_color and s.ending_loss_mate or s.ending_win_mate
    elseif self.ending then
        return s[Game.ending_key("draw", self.ending)]
    end
    if self.thinking then
        return s.status_thinking
    end
    if Chess.in_check(self.position) then
        return s.status_check
    end
    return s.status_your_turn
end

function OfflineGame:render(what)
    local s = self.s
    local buttons = { { id = "back", label = s.back } }
    if self:is_over() then
        buttons[#buttons + 1] = { id = "again", label = s.new_game_again }
    else
        buttons[#buttons + 1] = { id = "resign", label = s.resign }
    end
    self.screen:show({
        flipped = self.my_color == "b",
        position = self.position,
        last_move = self.last_move,
        selected = self.selected,
        targets = self.targets,
        top = { name = string.format(s.offline_level, self.level) },
        bottom = { name = s.you },
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

function OfflineGame:maybe_think()
    if self:is_over() or self.position.turn == self.my_color or self.thinking then
        return
    end
    self.thinking = true
    self:render()
    -- os.time() only counts whole seconds, which would cut up to a second from each level's time to think.
    local search = Engine.search(self.position, { level = self.level, now = socket.gettime })
    self.search = search
    local function work()
        -- A resignation or a new game ends this search, and its move must not land on the board.
        if self.is_closed or self.search ~= search or self:is_over() then
            if self.search == search then
                self.search, self.thinking = nil, false
            end
            return
        end
        local until_time = os.clock() + SLICE_SECONDS
        while os.clock() < until_time do
            local ok, result = coroutine.resume(search)
            if not ok then
                error(result)
            end
            if coroutine.status(search) == "dead" then
                self.search, self.thinking = nil, false
                if result then
                    self:apply(result)
                end
                self:render()
                return
            end
        end
        UIManager:scheduleIn(SLICE_PAUSE, work)
    end
    UIManager:scheduleIn(SLICE_PAUSE, work)
end

function OfflineGame:on_square(square)
    if self:is_over() or self.thinking or self.position.turn ~= self.my_color then
        return
    end
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
    if piece and (piece == piece:upper()) == (self.my_color == "w") then
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
        self.app:ask{
            title = self.s.resign_question,
            ok_text = self.s.resign,
            on_ok = function()
                self.resigned = true
                self.search, self.thinking = nil, false
                self.selected, self.targets = nil, nil
                self:save()
                self:render()
            end,
        }
    elseif button == "again" then
        UIManager:close(self.screen)
        OfflineGame.open(self.app, { level = self.level })
    end
end

function OfflineGame:closed()
    self.is_closed = true
    self.app:refresh_list()
end

return OfflineGame
