-- A chapter of the practice lessons on the board, with its text in a banner on top (and the whole of it a tap away
-- when it does not fit). A chapter with a goal is played against the engine; in a guided one the reader finds the
-- author's moves, the opponent's come by themselves unless there is a comment to read first, and a wrong move is
-- taken back; the commented game is gone through move by move, or from comment to comment.
local UIManager = require("ui/uimanager")
local socket = require("socket")

local BoardScreen = require("ink_knight/ui/board_screen")
local Chess = require("ink_knight/chess")
local Engine = require("ink_knight/engine")
local Practice = require("ink_knight/practice")
local Sleep = require("ink_knight/sleep")

local PracticeScreen = {}
PracticeScreen.__index = PracticeScreen

-- As in the app: an opponent's move with nothing to read waits a second, or less when the chapter starts with it,
-- and a wrong move with nothing to read is taken back after a moment.
local OPPONENT_DELAY, FIRST_MOVE_DELAY, TAKE_BACK_DELAY = 1, 0.3, 0.8
local SLICE_SECONDS, SLICE_PAUSE = 0.04, 0.02

-- study: one of ink_knight/data/practice.lua. opts.on_study_done(study): when the reader goes on from its last
-- chapter.
function PracticeScreen.open(app, study, index, opts)
    local self = setmetatable({ app = app, s = app.strings, t = app:practice_texts(), study = study, opts = opts or {} }, PracticeScreen)
    self.later_callback = function() self:later() end
    self.screen = BoardScreen:new{
        state = {},
        banner_lines = 4,
        on_square = function(square) self:on_square(square) end,
        on_button = function(button) self:on_button(button) end,
        on_closed = function()
            self.is_closed = true
            if app.reload_pages then
                app:reload_pages()
            end
        end,
        broken_text = app.strings.unexpected_error,
    }
    UIManager:show(self.screen)
    self:start(index or 1, "full")
    return self
end

-- again: a retry, which does not show the introduction of a guided chapter again.
function PracticeScreen:start(index, what, again)
    Sleep.unschedule(self.screen, self.later_callback)
    self.search, self.thinking, self.hinting, self.pending = nil, false, false, nil
    self.index = index
    self.chapter = self.study.chapters[index]
    self.selected, self.targets, self.hint_move, self.show_solution, self.recorded = nil, nil, nil, false, false
    local chapter = self.chapter
    if chapter.kind == "goal" then
        self.state = Practice.start_goal(chapter)
        if not Practice.is_player_turn(self.state) then
            self:engine_reply()
        end
    else
        self.state = Practice.start_guided(chapter)
        if chapter.kind == "guided" then
            if self:text("d") and not again then
                -- What the chapter is about comes first, on a page; the opponent waits for it to close.
                local state = self.state
                self:render(what)
                self.app:open_page{
                    title = self:study_name(),
                    rows = {
                        { kind = "text", text = self:with_name(self:text("d")) },
                        { kind = "primary", text = self.s.practice_continue, callback = function() end },
                    },
                    close_on_tap = true,
                    on_closed = function()
                        if not self.is_closed and self.state == state then
                            self:after_guided_change()
                            self:render()
                        end
                    end,
                }
                return
            end
            self:after_guided_change()
        end
    end
    self:render(what)
end

function PracticeScreen:text(key)
    return self.t[self.chapter.id .. "." .. key]
end

-- The goal, as the reader is told it.
function PracticeScreen:goal_text()
    local s, chapter = self.s, self.chapter
    if chapter.goal == "mate_in" then
        return string.format(s.practice_goal_mate_in, chapter.moves)
    elseif chapter.goal == "eval_in" then
        return string.format(chapter.moves == 1 and s.practice_goal_eval_in_one or s.practice_goal_eval_in, self:advantage_text(), chapter.moves)
    elseif chapter.goal == "equal_in" then
        return string.format(chapter.moves == 1 and s.practice_goal_equal_in_one or s.practice_goal_equal_in, chapter.moves)
    elseif chapter.goal == "draw_in" then
        return string.format(chapter.moves == 1 and s.practice_goal_draw_in_one or s.practice_goal_draw_in, chapter.moves)
    end
    return s["practice_goal_" .. chapter.goal]
end

-- The advantage a chapter asks for, in pawns for the reader, as Lichess writes evaluations: "+3", "+2.5".
function PracticeScreen:advantage_text()
    local pawns = math.abs(self.chapter.cp or 0) / 100
    return pawns == math.floor(pawns) and string.format("+%d", pawns) or string.format("+%.1f", pawns)
end

function PracticeScreen:banner_text()
    local s, chapter, state = self.s, self.chapter, self.state
    if chapter.kind == "goal" then
        return self:text("d") or self:goal_text()
    elseif chapter.kind == "lesson" then
        if state.ply == 0 then
            return self:text("d") or ""
        end
        return self:text("c" .. state.ply) or ""
    end
    local comment = Practice.comment(state, chapter, self.t)
    if comment then
        return comment
    end
    local feedback = Practice.feedback(state, chapter)
    if feedback == "play" then
        return s.practice_your_move
    elseif feedback == "bad" then
        return s.practice_wrong_move
    elseif feedback == "end" then
        return s.practice_lesson_done
    end
    return ""
end

function PracticeScreen:status_text()
    local s, chapter, state = self.s, self.chapter, self.state
    if chapter.kind == "goal" then
        if state.status == "solved" then
            return string.format(s.practice_solved, state.played)
        elseif state.status == "failed" then
            if state.reason == "slow" then
                return string.format(s.practice_failed_slow, chapter.moves)
            elseif state.reason == "mistake" then
                return state.better and string.format(s.practice_failed_mistake_better, state.better) or s.practice_failed_mistake
            elseif state.reason == "short" then
                return chapter.goal == "eval_in" and string.format(s.practice_failed_short, self:advantage_text()) or s.practice_failed_not_equal
            end
            return s["practice_failed_" .. state.reason]
        elseif state.notice == "other" then
            return s.practice_other_move
        elseif self.thinking then
            return s.status_thinking
        elseif self.hinting then
            return s.hint_thinking
        elseif self.hint_move then
            return string.format(s.hint_status, Chess.to_san(state.position, self.hint_move))
        elseif chapter.goal == "mate_in" or (Practice.SCRIPTED_GOALS[chapter.goal] and chapter.moves > 1) then
            return string.format(s.practice_moves_of, self:goal_text(), state.played + 1, chapter.moves)
        end
        return self:goal_text()
    elseif chapter.kind == "lesson" then
        if state.ply == 0 then
            return s.start_pos
        end
        -- Numbered as the game is, from the move number of the FEN and who moved first.
        local first = state.positions[0]
        local ply = state.ply + (first.turn == "b" and 1 or 0)
        local number = (tonumber(chapter.fen:match("%s(%d+)%s*$")) or 1) - 1 + math.ceil(ply / 2)
        return string.format("%d%s %s", number, ply % 2 == 1 and "." or "...", Chess.to_san(state.positions[state.ply - 1], state.last_moves[state.ply]))
    end
    local feedback = Practice.feedback(state, chapter)
    if feedback == "end" then
        return s.practice_complete
    elseif feedback == "bad" then
        return s.practice_wrong_status
    elseif feedback == "good" and state.ply > 0 and state.positions[state.ply - 1].turn == chapter.color then
        return s.practice_good_move
    elseif feedback == "play" and self.show_solution then
        local move = Practice.solution(state, chapter)
        return string.format(s.practice_solution_status, Chess.to_san(state.positions[state.ply], move))
    end
    return feedback == "play" and s.practice_your_turn or ""
end

function PracticeScreen:buttons(banner)
    local s, chapter, state = self.s, self.chapter, self.state
    local buttons = { { id = "back", label = s.back } }
    if not self.screen:banner_fits(banner) or (chapter.kind == "guided" and self:text("d")) then
        buttons[#buttons + 1] = { id = "read", label = s.practice_read }
    end
    if chapter.kind == "goal" then
        if state.status == "playing" then
            buttons[#buttons + 1] = { id = "hint", label = s.hint }
        end
        buttons[#buttons + 1] = { id = "retry", label = s.practice_retry }
    elseif chapter.kind == "lesson" then
        buttons[#buttons + 1] = { id = "previous", label = "<" }
        buttons[#buttons + 1] = { id = "forward", label = ">" }
        buttons[#buttons + 1] = { id = "comment", label = ">>" }
    else
        local feedback = Practice.feedback(state, chapter)
        if feedback == "play" then
            if Practice.hint(state, chapter, self.t) then
                buttons[#buttons + 1] = { id = "hint", label = s.hint }
            end
            buttons[#buttons + 1] = { id = "solution", label = s.practice_solution }
        elseif (feedback == "good" or feedback == "bad") and not self.pending then
            buttons[#buttons + 1] = { id = "continue", label = s.practice_continue }
        elseif feedback == "end" then
            buttons[#buttons + 1] = { id = "retry", label = s.practice_retry }
        end
    end
    buttons[#buttons + 1] = { id = "next", label = s.practice_next }
    return buttons
end

function PracticeScreen:render(what)
    if self.is_closed then
        return
    end
    local chapter, state = self.chapter, self.state
    local position, last_move, shapes, check_square
    if chapter.kind == "goal" then
        position, last_move = state.position, state.last_move
        -- The author's drawing stays until the first move.
        shapes = (state.played == 0 and not last_move) and Practice.shapes(chapter.shapes) or {}
        if self.hint_move then
            shapes[#shapes + 1] = { brush = "green", from = self.hint_move.from, to = self.hint_move.to }
        end
    else
        position, last_move = Practice.guided_position(state)
        shapes = chapter.kind == "guided" and Practice.guided_shapes(state, chapter) or Practice.shapes(chapter.shapes and chapter.shapes[state.ply])
        local solution = self.show_solution and Practice.solution(state, chapter)
        if solution then
            shapes[#shapes + 1] = { brush = "green", from = solution.from, to = solution.to }
        end
    end
    if Chess.in_check(position) then
        check_square = Chess.king_square(position, position.turn)
    end
    local banner = self:banner_text()
    self.screen:show({
        banner = banner,
        flipped = chapter.color == "b",
        position = position,
        last_move = last_move,
        selected = self.selected,
        targets = self.targets,
        shapes = shapes,
        check_square = check_square,
        bottom = { name = self:bar_name(), clock = string.format("%d/%d", self.index, #self.study.chapters) },
        status = self:status_text(),
        buttons = self:buttons(banner),
    }, what)
end

function PracticeScreen:study_name()
    return self.app:learn_texts()[self.study.name] or ""
end

-- A text on a page, after the name of the chapter, which may be too long for the title.
function PracticeScreen:with_name(text)
    return (self:text("n") or "") .. "\n\n" .. text
end

-- What Read shows: the text of the banner whole, after what a guided chapter is about.
function PracticeScreen:read_text()
    local banner = self:banner_text()
    local description = self.chapter.kind == "guided" and self:text("d")
    if description and description ~= banner then
        return description .. "\n\n" .. banner
    end
    return banner
end

-- The name of the chapter below the board, or of the study when the chapter's is too long for it, measured once
-- for each chapter.
function PracticeScreen:bar_name()
    local name = self:text("n") or ""
    if self.bar_name_of ~= self.chapter then
        self.bar_name_of = self.chapter
        self.bar_name_text = self.screen:bar_name_fits(name) and name or self:study_name()
    end
    return self.bar_name_text
end

-- The engine, in slices, so the screen never freezes; a search for a chapter left behind is dropped.
function PracticeScreen:run_engine(limits, on_done)
    local search = Engine.search(self.state.position, { limits = limits, report = true, now = socket.gettime })
    self.search = search
    local function work()
        if self.is_closed or self.search ~= search then
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
        Sleep.schedule(self.screen, SLICE_PAUSE, work)
    end
    Sleep.schedule(self.screen, SLICE_PAUSE, work)
end

function PracticeScreen:finish_goal()
    local state = self.state
    if state.status == "solved" and not self.recorded then
        self.recorded = true
        self.app:practice_record(self.chapter.id, state.played)
    end
end

-- The opponent's answer without the engine comes after a moment, so the reader sees their own move first.
local SCRIPTED_REPLY_SECONDS = 0.6

function PracticeScreen:engine_reply()
    self.thinking = true
    -- Without a scripted answer (data built without the chapter's tree), the engine answers instead of nobody.
    local scripted = Practice.SCRIPTED_GOALS[self.chapter.goal] and Practice.scripted_reply(self.state, self.chapter)
    if scripted then
        local state = self.state
        Sleep.schedule(self.screen, SCRIPTED_REPLY_SECONDS, function()
            if self.is_closed or self.state ~= state then
                return
            end
            self.thinking = false
            Practice.play(state, self.chapter, scripted)
            self:finish_goal()
            self:render()
        end)
        return
    end
    self:run_engine(Practice.ENGINE, function(result)
        self.thinking = false
        local state = self.state
        local move = result and result.best or Chess.legal_moves(state.position)[1]
        Practice.play(state, self.chapter, move)
        self:finish_goal()
        self:render()
    end)
end

function PracticeScreen:play_goal(move)
    local state, chapter = self.state, self.chapter
    self.selected, self.targets, self.hint_move = nil, nil, nil
    local next_step = Practice.play(state, chapter, move)
    if next_step == "judge" then
        self.thinking = true
        self:run_engine(Practice.ENGINE, function(result)
            self.thinking = false
            Practice.judge_promotion(state, chapter, result and result.score)
            self:finish_goal()
            self:render()
        end)
    elseif next_step == "reply" then
        self:engine_reply()
    end
    self:finish_goal()
    self:render()
end

function PracticeScreen:hint()
    if self.chapter.kind ~= "goal" then
        local text = Practice.hint(self.state, self.chapter, self.t)
        if text then
            self.app:info(text, 8)
        end
        return
    end
    if not Practice.is_player_turn(self.state) or self.thinking or self.hinting then
        return
    end
    local best = Practice.SCRIPTED_GOALS[self.chapter.goal] and Practice.best_move(self.state, self.chapter)
    if best then
        self.selected, self.targets, self.state.notice = nil, nil, nil
        self.hint_move = best
        self:render()
        return
    end
    self.hinting = true
    self.selected, self.targets, self.hint_move = nil, nil, nil
    self:render()
    local state = self.state
    self:run_engine(Engine.HINT, function(result)
        self.hinting = false
        if state == self.state and result and result.best then
            self.hint_move = result.best
        end
        self:render()
    end)
end

-- What a guided chapter does by itself after a change: its end is recorded, and an opponent's move or the taking
-- back of a wrong move with nothing to read come after a pause.
function PracticeScreen:after_guided_change()
    local state, chapter = self.state, self.chapter
    self.show_solution = false
    local feedback = Practice.feedback(state, chapter)
    self.pending = nil
    if feedback == "end" then
        if not self.recorded then
            self.recorded = true
            self.app:practice_record(chapter.id, Practice.guided_moves(state, chapter))
        end
    elseif (feedback == "good" or feedback == "bad") and not Practice.comment(state, chapter, self.t) then
        self.pending = feedback
        local delay = feedback == "bad" and TAKE_BACK_DELAY or (state.ply == 0 and FIRST_MOVE_DELAY or OPPONENT_DELAY)
        Sleep.schedule(self.screen, delay, self.later_callback)
    end
end

function PracticeScreen:later()
    if self.is_closed or not self.pending then
        return
    end
    self.pending = nil
    Practice.guided_next(self.state, self.chapter)
    self:after_guided_change()
    self:render()
end

function PracticeScreen:play_guided(move)
    self.selected, self.targets = nil, nil
    Practice.guided_move(self.state, self.chapter, move)
    self:after_guided_change()
    self:render()
end

function PracticeScreen:on_square(square)
    local chapter, state = self.chapter, self.state
    local position, mover
    if chapter.kind == "goal" then
        if not Practice.is_player_turn(state) or self.thinking or self.hinting then
            return
        end
        position, mover = state.position, chapter.color
    elseif chapter.kind == "guided" and Practice.feedback(state, chapter) == "play" then
        position, mover = state.positions[state.ply], chapter.color
    else
        return
    end
    local play = chapter.kind == "goal" and function(move) self:play_goal(move) end or function(move) self:play_guided(move) end
    if self.targets and self.targets[square] then
        local moves = self.targets[square]
        self.selected, self.targets = nil, nil
        if #moves == 1 then
            play(moves[1])
        else
            self.app:choose_promotion(moves, play)
        end
        return
    end
    local piece = position.board[square]
    if piece and (piece == piece:upper()) == (mover == "w") then
        self.selected = square
        self.targets = Chess.targets_from(position, square)
    else
        self.selected, self.targets = nil, nil
    end
    self:render()
end

function PracticeScreen:go_lesson(ply)
    local state, chapter = self.state, self.chapter
    state.ply = math.max(0, math.min(#chapter.line, ply))
    if state.ply == #chapter.line and not self.recorded then
        self.recorded = true
        self.app:practice_record(chapter.id, 0)
    end
    self:render()
end

function PracticeScreen:on_button(button)
    local chapter = self.chapter
    if button == "back" then
        UIManager:close(self.screen)
    elseif button == "read" then
        self.app:open_page{ title = self:study_name(), rows = { { kind = "text", text = self:with_name(self:read_text()) } }, close_on_tap = true }
    elseif button == "hint" then
        self:hint()
    elseif button == "solution" then
        self.show_solution = not self.show_solution
        self:render()
    elseif button == "continue" then
        Sleep.unschedule(self.screen, self.later_callback)
        self.pending = nil
        Practice.guided_next(self.state, chapter)
        self:after_guided_change()
        self:render()
    elseif button == "retry" then
        self:start(self.index, nil, true)
    elseif button == "previous" then
        self:go_lesson(self.state.ply - 1)
    elseif button == "forward" then
        self:go_lesson(self.state.ply + 1)
    elseif button == "comment" then
        -- To the next move with a comment, or the end.
        local ply = self.state.ply + 1
        while ply < #chapter.line and not self:text("c" .. ply) do
            ply = ply + 1
        end
        self:go_lesson(ply)
    elseif button == "next" then
        if self.index < #self.study.chapters then
            self:start(self.index + 1)
        else
            UIManager:close(self.screen)
            if self.opts.on_study_done then
                self.opts.on_study_done(self.study)
            end
        end
    end
end

return PracticeScreen
