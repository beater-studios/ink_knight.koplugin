-- One puzzle after another. Results stay saved until they can reach Lichess.
local UIManager = require("ui/uimanager")

local BoardScreen = require("ink_knight/ui/board_screen")
local Chess = require("ink_knight/chess")
local Puzzles = require("ink_knight/puzzles")
local Sleep = require("ink_knight/sleep")

local PuzzleScreen = {}
PuzzleScreen.__index = PuzzleScreen

local REPLY_DELAY = 0.7

-- opts.puzzle: a prepared puzzle. Without it, the next saved one is used, of the theme in opts.angle, or with
-- opts.pack the next one of the package. Daily puzzles and the ones of the package do not report a result. With
-- opts.single, a puzzle that reports its result but has no next one, as one of the history.
function PuzzleScreen.open(app, opts)
    local self = setmetatable({ app = app, s = app.strings, daily = opts.daily, single = opts.single, angle = opts.angle, review = opts.review, pack = opts.pack, on_closed = opts.on_closed }, PuzzleScreen)
    self.screen = BoardScreen:new{
        state = {},
        -- What happens is said in the plates, so the board takes the room of the line of text.
        status_line = false,
        on_square = function(square) self:on_square(square) end,
        on_button = function(button) self:on_button(button) end,
        on_closed = function() self:closed() end,
        broken_text = app.strings.unexpected_error,
    }
    UIManager:show(self.screen)
    self:start(opts.puzzle or self:next())
    return self
end

function PuzzleScreen:next()
    if self.pack then
        return self.app:pack_puzzle()
    end
    return self.app:next_puzzle(self.angle)
end

function PuzzleScreen:start(puzzle)
    self.session = puzzle and Puzzles.new_session(puzzle) or nil
    self.selected, self.targets, self.message, self.card_closed, self.counted = nil, nil, nil, nil, nil
    if self.session then
        self.message = self.s.puzzle_find
    end
    self:render("full")
end

function PuzzleScreen:render(what)
    local s, session = self.s, self.session
    if not session then
        local text = self.review and s.puzzle_review_done or s.puzzle_empty
        self.screen:show({ status = text, bottom = { name = s.puzzles, detail = text }, buttons = { { id = "back", label = s.back } } }, what)
        return
    end
    local has_next = not self.daily and not self.single
    local buttons = { { id = "back", label = s.back } }
    if session.solved then
        if has_next then
            buttons[#buttons + 1] = { id = "next", label = s.puzzle_next_button }
        end
    else
        buttons[#buttons + 1] = { id = "show", label = s.puzzle_show }
    end
    local bottom = { name = session.my_color == "w" and s.plays_white or s.plays_black }
    if self.message == s.puzzle_wrong then
        bottom.note = { text = self.message }
    else
        bottom.detail = self.message
    end
    -- A puzzle solved shows a card with the next one, which a tap on Board takes away.
    local card
    if session.solved and has_next and not self.card_closed then
        card = {
            icon = "done",
            title = s.puzzle_solved,
            text = self.message ~= s.puzzle_solved and self.message or nil,
            detail = (self.streak or 0) >= 2 and string.format(s.puzzle_streak, self.streak) or nil,
            buttons = { { id = "next", label = s.puzzle_next, primary = true }, { id = "see_board", label = s.see_board } },
        }
    end
    self.screen:show({
        position = session.position,
        last_move = session.last_move,
        flipped = session.my_color == "b",
        selected = self.selected,
        targets = self.targets,
        top = { icon = "hint", name = string.format(s.puzzle_rating, session.puzzle.rating or 0) },
        bottom = bottom,
        status = self.message,
        card = card,
        buttons = buttons,
    }, what)
end

function PuzzleScreen:finish()
    local session, s = self.session, self.s
    local first_try = session.mistakes == 0 and not session.revealed
    self.message = first_try and s.puzzle_solved or s.puzzle_solved_after
    -- Puzzles solved at the first try one after the other, counted on the device; a mistake or a move shown starts it again. Only new puzzles count: the daily one, one of the history and the missed ones reviewed can be solved again.
    if not self.counted and not self.daily and not self.single and not self.review then
        self.counted = true
        local streak = first_try and (tonumber(self.app.settings:readSetting("puzzle_streak")) or 0) + 1 or 0
        self.app:save_setting("puzzle_streak", streak)
        self.streak = streak
    end
    if self.pack then
        if not self.recorded then
            self.recorded = true
            self.app:advance_pack(session.puzzle)
        end
    elseif not self.daily and not self.recorded then
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
        Sleep.schedule(self.screen, REPLY_DELAY, function()
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
        self:start(self:next())
    elseif button == "see_board" then
        self.card_closed = true
        self:render()
    end
end

function PuzzleScreen:closed()
    self.is_closed = true
    -- Leaving a puzzle unsolved does not count against it: it just goes back to the pile. One of the package stays
    -- where it is, so the same one comes next time, and one of the history has no pile.
    if self.session and not self.session.solved and not self.daily and not self.pack and not self.single then
        self.app:return_puzzle(self.session.puzzle)
    end
    self.app:flush_puzzles()
    self.app:refresh_list()
    if self.on_closed then
        self.on_closed()
    end
end

return PuzzleScreen
