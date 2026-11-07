-- One puzzle after another. Results stay saved until they can reach Lichess.
local UIManager = require("ui/uimanager")

local BoardScreen = require("ink_knight/ui/board_screen")
local Chess = require("ink_knight/chess")
local Puzzles = require("ink_knight/puzzles")

local PuzzleScreen = {}
PuzzleScreen.__index = PuzzleScreen

local REPLY_DELAY = 0.7

-- opts.puzzle: a prepared puzzle. Without it, the next saved one is used, of the theme in opts.angle.
-- Daily puzzles do not report a result.
function PuzzleScreen.open(app, opts)
    local self = setmetatable({ app = app, s = app.strings, daily = opts.daily, angle = opts.angle }, PuzzleScreen)
    self.screen = BoardScreen:new{
        state = {},
        on_square = function(square) self:on_square(square) end,
        on_button = function(button) self:on_button(button) end,
        on_closed = function() self:closed() end,
    }
    UIManager:show(self.screen)
    self:start(opts.puzzle or app:next_puzzle(opts.angle))
    return self
end

function PuzzleScreen:start(puzzle)
    self.session = puzzle and Puzzles.new_session(puzzle) or nil
    self.selected, self.targets, self.message = nil, nil, nil
    if self.session then
        self.message = self.s.puzzle_find
    end
    self:render("full")
end

function PuzzleScreen:render(what)
    local s, session = self.s, self.session
    if not session then
        self.screen:show({ status = s.puzzle_empty, buttons = { { id = "back", label = s.back } } }, what)
        return
    end
    local buttons = { { id = "back", label = s.back } }
    if session.solved then
        if not self.daily then
            buttons[#buttons + 1] = { id = "next", label = s.puzzle_next_button }
        end
    else
        buttons[#buttons + 1] = { id = "show", label = s.puzzle_show }
    end
    self.screen:show({
        position = session.position,
        last_move = session.last_move,
        flipped = session.my_color == "b",
        selected = self.selected,
        targets = self.targets,
        top = { name = string.format(s.puzzle_rating, session.puzzle.rating or 0) },
        bottom = { name = session.my_color == "w" and s.plays_white or s.plays_black },
        status = self.message,
        buttons = buttons,
    }, what)
end

function PuzzleScreen:finish()
    local session, s = self.session, self.s
    self.message = (session.mistakes == 0 and not session.revealed) and s.puzzle_solved or s.puzzle_solved_after
    if not self.daily and not self.recorded then
        self.recorded = true
        self.app:add_puzzle_result(Puzzles.result(session))
    end
    self:render()
end

function PuzzleScreen:play(uci)
    local session = self.session
    local outcome = Puzzles.try_move(session, uci)
    if outcome == "wrong" then
        self.message = self.s.puzzle_wrong
        self:render()
    elseif outcome == "solved" then
        self:finish()
    else
        self.message = self.s.puzzle_correct
        self:render()
        self.waiting = true
        UIManager:scheduleIn(REPLY_DELAY, function()
            self.waiting = false
            if self.is_closed or self.session ~= session then
                return
            end
            Puzzles.play_reply(session)
            if session.step > #session.puzzle.solution then
                session.solved = true
                self:finish()
            else
                self.message = self.s.puzzle_find
                self:render()
            end
        end)
    end
end

function PuzzleScreen:on_square(square)
    local session = self.session
    if not session or session.solved or self.waiting then
        return
    end
    if self.targets and self.targets[square] then
        local moves = self.targets[square]
        self.selected, self.targets = nil, nil
        if #moves == 1 then
            self:play(Chess.move_to_uci(moves[1]))
        else
            self:choose_promotion(moves)
        end
        return
    end
    local piece = session.position.board[square]
    if piece and (piece == piece:upper()) == (session.my_color == "w") then
        self.selected = square
        self.targets = Chess.targets_from(session.position, square)
    else
        self.selected, self.targets = nil, nil
    end
    self:render()
end

function PuzzleScreen:choose_promotion(moves)
    self.app:choose_promotion(moves, function(move) self:play(Chess.move_to_uci(move)) end)
end

function PuzzleScreen:on_button(button)
    if button == "back" then
        UIManager:close(self.screen)
    elseif button == "show" then
        local session = self.session
        if session and not self.waiting then
            local uci = Puzzles.hint(session)
            session.revealed = true
            if uci then
                self:play(uci)
            end
        end
    elseif button == "next" then
        self.recorded = false
        self:start(self.app:next_puzzle(self.angle))
    end
end

function PuzzleScreen:closed()
    self.is_closed = true
    -- Leaving a puzzle unsolved does not count against it: it just goes back to the pile.
    if self.session and not self.session.solved and not self.daily then
        self.app:return_puzzle(self.session.puzzle)
    end
    self.app:flush_puzzles()
    self.app:refresh_list()
end

return PuzzleScreen
