-- A correspondence game as Lichess last sent it, with no network. On the reader's turn a move can be made: it
-- waits on the device, can be taken back until then, and goes to Lichess the next time the reader plays online.
local UIManager = require("ui/uimanager")

local Api = require("ink_knight/api")
local BoardScreen = require("ink_knight/ui/board_screen")
local Chess = require("ink_knight/chess")
local Correspondence = require("ink_knight/correspondence")

local CorrespondenceScreen = {}
CorrespondenceScreen.__index = CorrespondenceScreen

function CorrespondenceScreen.open(app, id)
    local self = setmetatable({ app = app, s = app.strings, id = id }, CorrespondenceScreen)
    self.screen = BoardScreen:new{
        state = {},
        on_square = function(square) self:on_square(square) end,
        on_button = function(button) self:on_button(button) end,
        on_closed = function()
            self.is_closed = true
            if app.correspondence_closed then
                app:correspondence_closed()
            end
        end,
        broken_text = app.strings.unexpected_error,
    }
    UIManager:show(self.screen)
    app.correspondence_view = self
    self:render("full")
    return self
end

-- The kept games are read once for each drawing, and the taps use what is on the board.
function CorrespondenceScreen:game()
    return self.data and Correspondence.find(self.data.games, self.id)
end

function CorrespondenceScreen:status_text(game)
    local s = self.s
    if game.pending then
        return string.format(s.correspondence_status_saved, game.pending.san)
    end
    if Correspondence.is_my_turn(game) then
        return s.status_your_turn
    end
    return string.format(s.status_their_turn, game.opponent or s.anonymous)
end

function CorrespondenceScreen:render(what)
    if self.is_closed then
        return
    end
    self.data = self.app:correspondence()
    local s, game = self.s, self:game()
    if not game then
        self.screen:show({ status = s.unexpected_error, buttons = { { id = "back", label = s.back } } }, what)
        return
    end
    local position, last_move = Correspondence.position(game)
    local buttons = { { id = "back", label = s.back } }
    if game.pending then
        buttons[#buttons + 1] = { id = "undo", label = s.undo }
    end
    local left = Correspondence.seconds_left(game, os.time())
    self.screen:show({
        flipped = game.color == "b",
        position = position,
        last_move = last_move,
        selected = self.selected,
        targets = self.targets,
        top = { name = game.opponent or s.anonymous },
        bottom = {
            name = self.data.name or s.you,
            clock = left and Api.format_left(left) or nil,
            active = Correspondence.is_my_turn(game) and not game.pending,
        },
        status = self:status_text(game),
        buttons = buttons,
    }, what)
end

function CorrespondenceScreen:on_square(square)
    local game = self:game()
    if not game or game.pending or not Correspondence.is_my_turn(game) then
        return
    end
    local position = Chess.parse_fen(game.fen)
    if self.targets and self.targets[square] then
        local moves = self.targets[square]
        self.selected, self.targets = nil, nil
        if #moves == 1 then
            self:play(moves[1])
        else
            self.app:choose_promotion(moves, function(move) self:play(move) end)
        end
        return
    end
    local piece = position.board[square]
    if piece and (piece == piece:upper()) == (game.color == "w") then
        self.selected = square
        self.targets = Chess.targets_from(position, square)
    else
        self.selected, self.targets = nil, nil
    end
    self:render()
end

function CorrespondenceScreen:play(move)
    local kept, sending = self.app:keep_correspondence_move(self.id, move)
    -- Online, the move goes out at once and the reader is told when it is sent.
    if kept and not sending then
        self.app:info(self.s.correspondence_move_kept, 4)
    end
    self:render()
end

function CorrespondenceScreen:on_button(button)
    if button == "back" then
        UIManager:close(self.screen)
    elseif button == "undo" then
        self.app:forget_correspondence_move(self.id)
        self:render()
    end
end

return CorrespondenceScreen
