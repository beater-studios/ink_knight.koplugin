-- A game with no network, against the small engine or between two people taking turns on the same device. It is
-- saved after each move, each kind under its own key, so it can be continued later.
local UIManager = require("ui/uimanager")
local socket = require("socket")

local Awake = require("ink_knight/awake")
local BoardScreen = require("ink_knight/ui/board_screen")
local Chess = require("ink_knight/chess")
local ChessClock = require("ink_knight/chess_clock")
local Engine = require("ink_knight/engine")
local EngineAnalysis = require("ink_knight/ui/engine_analysis")
local Game = require("ink_knight/game")
local GameReview = require("ink_knight/game_review")
local MoveList = require("ink_knight/ui/move_list")
local Sleep = require("ink_knight/sleep")
local State = require("ink_knight/state")

local OfflineGame = {}
OfflineGame.__index = OfflineGame

-- How long the engine works before giving the screen its turn.
local SLICE_SECONDS = 0.04
local SLICE_PAUSE = 0.02

function OfflineGame.open(app, opts)
    local self = setmetatable({ app = app, s = app.strings }, OfflineGame)
    self.two_players = opts.two_players == true
    self.save_key = self.two_players and "two_player_game" or "offline_game"
    local saved = opts.resume and app:saved_game(self.save_key)
    if self.two_players then
        -- No side is the reader's: whoever is to move plays, and the board turns only when asked.
        self.flipped = saved and saved.flipped or false
        -- An optional clock, such as "5+3"; it starts with black's time after white's first move.
        self.clock_preset = saved and saved.clock_preset or opts.clock
        if saved and saved.clock then
            self.clock = ChessClock.restore(saved.clock)
            self.clock_paused = saved.clock_paused == true
        elseif self.clock_preset then
            self.clock = ChessClock.new(ChessClock.parse(self.clock_preset))
        end
    else
        self.level = saved and saved.level or opts.level or 1
        -- "random", "white" or "black": kept for the next game, so playing again keeps the choice.
        self.color_choice = saved and saved.color_choice or opts.color_choice or "random"
        local chosen = self.color_choice == "white" and "w" or self.color_choice == "black" and "b" or nil
        self.my_color = saved and saved.my_color or chosen or (math.random(2) == 1 and "w" or "b")
        self.flipped = self.my_color == "b"
    end
    -- A game from a position set up in the editor starts there; nil is the usual start.
    self.initial_fen = saved and saved.initial_fen or opts.initial_fen
    self.moves = saved and saved.moves or ""
    self.position, self.last_move = Chess.from_moves(self.initial_fen, self.moves)
    self.seen = {}
    self:count_positions()
    self.tick_callback = function() self:tick() end
    self.wake_callback = function() self:start_clock() end
    self.screen = BoardScreen:new{
        state = { flipped = self.flipped },
        on_square = function(square) self:on_square(square) end,
        on_button = function(button) self:on_button(button) end,
        on_suspend = function() self:stop_clock() end,
        on_resume = function() if self.clock then Sleep.schedule(self.screen, 0, self.wake_callback) end end,
        on_closed = function() self:closed() end,
        broken_text = app.strings.unexpected_error,
    }
    UIManager:show(self.screen)
    self:check_end()
    self:start_clock()
    self:render("full")
    self:maybe_think()
    return self
end

-- The clock of a game between two people runs while the screen is open and the device awake, unless someone paused
-- it, and keeps the device awake while it runs.
function OfflineGame:start_clock()
    local clock = self.clock
    if clock and not self.clock_paused and not self:is_over() and not self.is_closed then
        ChessClock.resume(clock, socket.gettime())
        if ChessClock.running(clock) then
            Awake.set(true, self)
            Sleep.schedule(self.screen, ChessClock.next_change(clock, socket.gettime()), self.tick_callback)
        end
    end
end

function OfflineGame:stop_clock()
    if self.clock then
        ChessClock.pause(self.clock, socket.gettime())
        Sleep.unschedule(self.screen, self.tick_callback)
        Awake.set(false, self)
    end
end

function OfflineGame:tick()
    if not self.clock or self.is_closed or not ChessClock.running(self.clock) then
        return
    end
    if self:check_flag() then
        self:render()
        return
    end
    self:render("clock")
    Sleep.schedule(self.screen, ChessClock.next_change(self.clock, socket.gettime()), self.tick_callback)
end

-- A side out of time loses, unless the other side has nothing left to mate with.
function OfflineGame:check_flag()
    local side = self.clock and not self.ending and ChessClock.check(self.clock, socket.gettime())
    if not side then
        return false
    end
    self.ending, self.flagged = "time", side
    self.time_draw = not Chess.can_mate(self.position, ChessClock.other(side))
    self.selected, self.targets = nil, nil
    self:stop_clock()
    self:save()
    return true
end

function OfflineGame:clock_info(color)
    if not self.clock then
        return nil
    end
    return ChessClock.text(ChessClock.left(self.clock, color, socket.gettime()))
end

-- Three times the same position is a draw, so each one is counted from the start of the game.
function OfflineGame:count_positions()
    local position = Chess.parse_fen(self.initial_fen or Chess.START_FEN)
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
        self.app.settings:saveSetting(self.save_key, {
            version = State.GAME_VERSION, flipped = self.flipped, moves = self.moves,
            clock = self.clock and ChessClock.save(self.clock, socket.gettime()) or nil,
            clock_preset = self.clock_preset,
            clock_paused = self.clock_paused or nil,
            initial_fen = self.initial_fen,
        })
    else
        self.app.settings:saveSetting(self.save_key, { version = State.GAME_VERSION, level = self.level, my_color = self.my_color, color_choice = self.color_choice, moves = self.moves, initial_fen = self.initial_fen })
    end
    self.app.settings:flush()
end

function OfflineGame:check_end()
    if self.ending == "time" then
        return
    end
    local ending = Chess.ending(self.position)
    if not ending and (self.seen[Chess.position_key(self.position)] or 0) >= 3 then
        ending = "repetition"
    end
    self.ending = ending
end

-- "Chess960 no 518" for a game of Chess960, or nil. A standard game from the starting position is not one, though
-- its pieces stand as number 518. Worked out once, since the position a game starts from does not change.
function OfflineGame:chess960_label()
    if self.chess960_text == nil then
        local position = type(self.initial_fen) == "string" and Chess.parse_fen(self.initial_fen)
        local number = position and position.chess960 and Chess.chess960_number(self.initial_fen)
        self.chess960_text = number and string.format(self.s.chess960_number, number) or false
    end
    return self.chess960_text or nil
end

-- Before the first move, a game of Chess960 says which of the 960 positions it is.
function OfflineGame:start_label(text)
    local label = self.moves == "" and self:chess960_label()
    return label and string.format("%s · %s", label, text) or text
end

function OfflineGame:status_text()
    local s = self.s
    if self.analysis and self.analysis.stockfish then
        return string.format(s.engine_progress, self.analysis.done or 1, self.analysis.total or 1)
    elseif self.analysis then
        return string.format(s.analysis_progress, math.max(1, self.analysis.index), #self.analysis.list)
    end
    local turn = self.position.turn
    if self.resigned then
        return self.two_players and s["local_resigned_" .. self.resigned_color] or s.ending_loss_resign
    end
    if self.ending == "time" then
        return s[(self.time_draw and "local_flag_draw_" or "local_flag_") .. self.flagged]
    end
    if self.clock_paused then
        return s.clock_paused
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
    if self.resigned or self.ending == "time" then
        return nil
    end
    if self.two_players then
        return self.moves ~= "" and (self.moves:match("^(.*)%s+%S+$") or "") or nil
    end
    return Chess.take_back(self.moves, self.my_color, Chess.parse_fen(self.initial_fen or Chess.START_FEN).turn)
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
    if self.analysis then
        buttons[#buttons + 1] = { id = "analysis_cancel", label = s.cancel }
        self:show_state(buttons, what)
        return
    end
    if self:can_undo() then
        buttons[#buttons + 1] = { id = "undo", label = s.undo }
    end
    if self:can_hint() then
        buttons[#buttons + 1] = { id = "hint", label = s.hint }
    end
    if self.moves ~= "" then
        buttons[#buttons + 1] = { id = "moves", label = s.moves }
    end
    if self.two_players then
        buttons[#buttons + 1] = { id = "flip", label = s.flip_board }
    end
    if self.clock and self.clock.active and not self:is_over() then
        buttons[#buttons + 1] = self.clock_paused and { id = "clock_resume", label = s.clock_resume } or { id = "clock_pause", label = s.clock_pause }
    end
    if self:is_over() then
        if self.moves ~= "" then
            buttons[#buttons + 1] = { id = "analyze", label = s.analyze_game }
        end
        buttons[#buttons + 1] = { id = "again", label = s.new_game_again }
    else
        buttons[#buttons + 1] = { id = "resign", label = s.resign }
    end
    self:show_state(buttons, what)
end

function OfflineGame:show_state(buttons, what)
    local s = self.s
    local top, bottom = { name = string.format(s.offline_level, self.level or 1) }, { name = s.you }
    if self.two_players then
        local running = self.clock and ChessClock.running(self.clock)
        top = { name = s.color_black, clock = self:clock_info("b"), active = running and self.position.turn == "b" }
        bottom = { name = s.color_white, clock = self:clock_info("w"), active = running and self.position.turn == "w" }
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
        status = self:start_label(self:status_text()),
        buttons = buttons,
    }, what)
end

function OfflineGame:is_over()
    return self.ending ~= nil or self.resigned == true
end

-- The engine goes through the moves of the game, one search each, and the review opens with what it found: the
-- Stockfish of the device when there is one, every move judged as Lichess judges them; otherwise the small engine,
-- only the clear mistakes and, against the engine, only the reader's moves. Done once per game: a second tap opens the
-- same review.
function OfflineGame:analyze()
    if self.review_game then
        self:open_review()
        return
    end
    if EngineAnalysis.available(self.app) and self:analyze_with_stockfish() then
        return
    end
    local only = not self.two_players and self.my_color or nil
    local list = GameReview.moves(self.initial_fen, self.moves, only)
    if #list == 0 then
        self.app:info(self.s.analysis_nothing)
        return
    end
    self.analysis = { list = list, index = 0, results = {}, skipped = 0 }
    self.selected, self.targets = nil, nil
    self:analyze_next()
end

function OfflineGame:analyze_next()
    local analysis = self.analysis
    if not analysis or self.is_closed then
        return
    end
    analysis.index = analysis.index + 1
    local item = analysis.list[analysis.index]
    if not item then
        self:finish_analysis()
        return
    end
    self:render()
    self:run_engine(item.position, { limits = GameReview.LIMITS, report = true, exact = item.uci }, function(result)
        if self.analysis ~= analysis then
            return
        end
        if result and result.score then
            analysis.results[item.index] = {
                mover = item.mover, position = item.position, best = result.best, score = result.score,
                played = result.played, judgment = GameReview.judge(result.score, result.played),
            }
        elseif not item.retried then
            -- No depth finished, as after a sleep in the middle, when the time ran out while it was paused:
            -- once more.
            item.retried = true
            analysis.index = analysis.index - 1
        else
            analysis.skipped = analysis.skipped + 1
        end
        self:analyze_next()
    end)
end

function OfflineGame:analyze_with_stockfish()
    local moves = {}
    for uci in self.moves:gmatch("%S+") do
        moves[#moves + 1] = uci
    end
    if #moves == 0 then
        return false
    end
    -- Marked before it starts, since the first position is announced while it does.
    local analysis = { stockfish = true }
    self.analysis = analysis
    self.selected, self.targets = nil, nil
    analysis.runner = EngineAnalysis.start{
        app = self.app,
        window = self.screen,
        initial_fen = self.initial_fen,
        moves = moves,
        on_progress = function(done, total)
            if self.analysis == analysis then
                analysis.done, analysis.total = done, total
                self:render()
            end
        end,
        on_done = function(result)
            if self.analysis ~= analysis then
                return
            end
            if not result then
                self.analysis = nil
                self:render()
                self.app:info(self.s.engine_stopped)
                return
            end
            self:finish_stockfish_analysis(result, moves)
        end,
    }
    if not analysis.runner then
        self.analysis = nil
        return false
    end
    return true
end

function OfflineGame:finish_stockfish_analysis(result, ucis)
    local s = self.s
    self.analysis = nil
    self.san_cache = self.san_cache or {}
    local sans = Chess.san_list(self.initial_fen, self.moves, self.san_cache)
    local moves = {}
    for index, uci in ipairs(ucis) do
        local entry = result.moves[index] or {}
        moves[index] = { uci = uci, san = sans[index], eval_text = entry.eval_text, judgment = entry.judgment, best = entry.best, white_cp = entry.white_cp }
    end
    local function line(name, data)
        return string.format(s.review_side_full, name, data.blunder, data.mistake, data.inaccuracy)
    end
    local summary = result.summary
    local notice
    if self.two_players then
        notice = line(s.color_white, summary.white) .. "\n" .. line(s.color_black, summary.black)
    else
        notice = line(s.you, self.my_color == "w" and summary.white or summary.black)
    end
    self:set_review_game(moves, notice, summary)
end

-- The review of the analyzed game: its moves, the notice of what was found (also its start, against the engine) and,
-- when the analysis made one, the summary with figures.
function OfflineGame:set_review_game(moves, notice, summary)
    local s = self.s
    local you, engine = s.you, string.format(s.offline_level, self.level or 1)
    self.review_game = {
        moves = moves, intro = not self.two_players and notice or nil, notice = notice, summary = summary,
        initial_fen = self.initial_fen, result_text = self:status_text(),
        white = self.two_players and s.color_white or (self.my_color == "w" and you or engine),
        black = self.two_players and s.color_black or (self.my_color == "b" and you or engine),
    }
    self:render()
    self:open_review()
end

function OfflineGame:cancel_analysis()
    if self.analysis and self.analysis.runner then
        self.analysis.runner:cancel()
    end
    self.analysis = nil
    self:stop_search()
    self:render()
end

function OfflineGame:finish_analysis()
    local s, analysis = self.s, self.analysis
    self.analysis = nil
    self.san_cache = self.san_cache or {}
    local sans = Chess.san_list(self.initial_fen, self.moves, self.san_cache)
    local moves, index = {}, 0
    for uci in self.moves:gmatch("%S+") do
        index = index + 1
        local result = analysis.results[index]
        local entry = { uci = uci, san = sans[index] }
        if result then
            entry.eval_text = GameReview.eval_text(result.played, result.mover)
            entry.judgment = result.judgment
            if result.judgment and result.best and Chess.move_to_uci(result.best) ~= uci then
                entry.best = Chess.to_san(result.position, result.best)
            end
        end
        moves[index] = entry
    end
    local counts = GameReview.count(analysis.results)
    local function line(name, side)
        local count = counts[side]
        if count.Blunder + count.Mistake == 0 then
            return string.format(s.review_side_none, name)
        end
        return string.format(s.review_side, name, count.Blunder, count.Mistake)
    end
    -- One line fits the start of the review; the two sides of a game between two people come in a notice too.
    local summary
    if self.two_players then
        summary = line(s.color_white, "w") .. "\n" .. line(s.color_black, "b")
    else
        summary = line(s.you, self.my_color)
    end
    if analysis.skipped > 0 then
        summary = summary .. "\n" .. string.format(s.analysis_skipped, analysis.skipped)
    end
    -- The text goes in a notice; the summary of the review is for the figures of an analysis that has them.
    self:set_review_game(moves, summary, nil)
end

function OfflineGame:open_review()
    require("ink_knight/ui/review_screen").open(self.app, self.review_game, { flipped = self.flipped })
    self.app:info(self.review_game.notice, 6)
end

function OfflineGame:apply(move)
    self.review_game = nil
    if self.clock then
        local now = socket.gettime()
        if self.clock.active then
            ChessClock.press(self.clock, now)
        else
            ChessClock.start(self.clock, ChessClock.other(self.position.turn), now)
        end
    end
    self.position = Chess.play(self.position, move)
    self.last_move = move
    local uci = Chess.move_to_uci(move)
    self.moves = self.moves == "" and uci or (self.moves .. " " .. uci)
    local key = Chess.position_key(self.position)
    self.seen[key] = (self.seen[key] or 0) + 1
    self:check_end()
    if self:is_over() then
        self:stop_clock()
    elseif self.clock then
        self:start_clock()
    end
    self:save()
end

-- Runs a search a slice at a time, so the screen keeps answering. Whoever replaces or clears self.search cancels
-- it, and then on_done is not called. A game that ended meanwhile gets on_done(nil).
function OfflineGame:run_search(opts, on_done)
    self:run_engine(self.position, opts, on_done, function() return not self:is_over() end)
end

-- The engine on any position, a slice at a time. still_wanted, when given, is asked between slices: false ends the
-- search with on_done(nil).
function OfflineGame:run_engine(position, opts, on_done, still_wanted)
    -- os.time() only counts whole seconds, which would cut up to a second from each level's time to think.
    opts.now = socket.gettime
    local search = Engine.search(position, opts)
    self.search = search
    local function work()
        if self.is_closed or self.search ~= search then
            return
        end
        if still_wanted and not still_wanted() then
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
        Sleep.schedule(self.screen, SLICE_PAUSE, work)
    end
    Sleep.schedule(self.screen, SLICE_PAUSE, work)
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
            local target = Chess.target_square(position, move)
            self.targets = { [target] = Chess.targets_from(position, move.from)[target] }
            self.hint_text = string.format(self.s.hint_status, Chess.to_san(position, move))
        end
        self:render()
    end)
end

-- Back to the reader's last move: the computer's answer to it goes too, and so does a search under way.
function OfflineGame:undo()
    self.review_game = nil
    local moves = self:moves_after_undo()
    if not moves then
        return
    end
    self:stop_search()
    self.moves = moves
    self.position, self.last_move = Chess.from_moves(self.initial_fen, moves)
    self:count_positions()
    self:check_end()
    -- The time already spent stays, without the increment of the move taken back, and the side to move again is
    -- the one whose clock runs. Back at the start, the clock is as new.
    if self.clock then
        self:stop_clock()
        if moves == "" then
            self.clock = ChessClock.new(self.clock.initial, self.clock.increment)
            self.clock_paused = false
        elseif self.clock.active then
            ChessClock.take_back(self.clock, self.position.turn)
        end
        self:start_clock()
    end
    self.selected, self.targets, self.hint_text = nil, nil, nil
    self:save()
    self:render()
end

function OfflineGame:on_square(square)
    -- Between two people, whoever is to move plays.
    local mover = self.two_players and self.position.turn or self.my_color
    if self:check_flag() then
        self:render()
        return
    end
    if self:is_over() or self.thinking or self.hinting or self.clock_paused or self.position.turn ~= mover then
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
    self.app:choose_game_promotion(moves, function(move)
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
                self:stop_clock()
                self.selected, self.targets, self.hint_text = nil, nil, nil
                self:save()
                self:render()
            end,
        }
    elseif button == "clock_pause" then
        self.clock_paused = true
        self.selected, self.targets = nil, nil
        self:stop_clock()
        self:save()
        self:render()
    elseif button == "clock_resume" then
        self.clock_paused = false
        self:start_clock()
        self:render()
    elseif button == "analyze" then
        self:analyze()
    elseif button == "analysis_cancel" then
        self:cancel_analysis()
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
        local sans, first_number, first_turn = Chess.san_list(self.initial_fen, self.moves, self.san_cache)
        MoveList.show(self.app, sans, first_number, first_turn, { initial_fen = self.initial_fen, moves = self.moves, opening = self:chess960_label() })
    elseif button == "again" then
        UIManager:close(self.screen)
        if self.two_players then
            OfflineGame.open(self.app, { two_players = true, clock = self.clock_preset, initial_fen = self.initial_fen })
        else
            OfflineGame.open(self.app, { level = self.level, color_choice = self.color_choice, initial_fen = self.initial_fen })
        end
    end
end

function OfflineGame:closed()
    -- An analysis under way ends with the screen, and so does its Stockfish; nothing is drawn on a closing screen.
    if self.analysis and self.analysis.runner then
        self.analysis.runner:cancel()
    end
    self.analysis = nil
    if self.clock and not self:is_over() then
        self:stop_clock()
        self:save()
    else
        Awake.set(false, self)
    end
    self.is_closed = true
    self.app:refresh_list()
end

return OfflineGame
