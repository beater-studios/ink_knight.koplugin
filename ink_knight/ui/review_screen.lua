-- Goes through a finished game, move by move, with what Lichess knows about each position.
local UIManager = require("ui/uimanager")

local Analysis = require("ink_knight/analysis")
local Sleep = require("ink_knight/sleep")
local Api = require("ink_knight/api")
local BoardScreen = require("ink_knight/ui/board_screen")
local Broadcast = require("ink_knight/broadcast")
local EngineAnalysis = require("ink_knight/ui/engine_analysis")
local EnginePlayer = require("ink_knight/ui/engine_player")
local EvalChart = require("ink_knight/ui/eval_chart")
local Chess = require("ink_knight/chess")
local MoveList = require("ink_knight/ui/move_list")

local ReviewScreen = {}
ReviewScreen.__index = ReviewScreen

-- game: { moves = { { uci, san, eval_text, judgment, best, clock, white_cp } }, intro, initial_fen, summary }, plus
-- white, black and result for the bars; best is the better move, in the usual notation, when the engine of the plugin
-- found one, summary comes from Game.analysis_summary, clock the seconds left after the move, shown on the bars, and
-- white_cp the score after the move for white, for the chart of the summary.
-- opts: flipped, game_id and bookmarked, for the favorites, reader_color when the reader played the game, and
-- refresh(on_game) for a game still being played: called every REFRESH_SECONDS, it gives on_game the game again,
-- with the moves played since.
local REFRESH_SECONDS = 60

function ReviewScreen.open(app, game, opts)
    opts = opts or {}
    local self = setmetatable({ app = app, s = app.strings, game = game, flipped = opts.flipped == true, index = 0, opts = opts }, ReviewScreen)
    local start = Chess.start_position(game.initial_fen)
    -- Numbered from the move number of the FEN, as the list of moves of the game is.
    self.first_number = tonumber(tostring(game.initial_fen or ""):match("%s(%d+)%s*$")) or 1
    self.positions = { [0] = start }
    self.last_moves = {}
    self.available = 0
    self:extend()
    -- A game being played opens on its last move, which is where it is now.
    self.index = opts.refresh and self.available or 0
    self.screen = BoardScreen:new{
        state = { flipped = self.flipped },
        -- The review names squares, in the moves and the better ones, so they are always on its board.
        coordinates = true,
        band = true,
        read_marks = true,
        on_square = function(square) self:on_square(square) end,
        on_button = function(button) self:on_button(button) end,
        on_closed = function()
            self.closed = true
            if self.analysis then
                self.analysis:cancel()
                self.analysis = nil
            end
            if opts.on_closed then
                opts.on_closed()
            end
        end,
        broken_text = app.strings.unexpected_error,
    }
    UIManager:show(self.screen)
    self:render("full")
    if opts.refresh then
        self:schedule_refresh()
    end
    return self
end

-- Reads the moves of the game past the ones already on the board.
function ReviewScreen:extend()
    local position = self.positions[self.available]
    for i = self.available + 1, #self.game.moves do
        local next_position, played = Chess.apply_uci(position, self.game.moves[i].uci)
        if not next_position then
            break
        end
        self.positions[i], self.last_moves[i] = next_position, played
        position = next_position
        self.available = i
    end
end

-- Asked again until the game has a result: a finished game changes no more.
function ReviewScreen:schedule_refresh()
    Sleep.schedule(self.screen, REFRESH_SECONDS, function()
        self.opts.refresh(function(game)
            if game then
                self:update(game)
            end
            if not self.closed and not self.game.result_text then
                self:schedule_refresh()
            end
        end)
    end)
end

-- The game again, with the moves played since: a reader on the last move follows the new ones. A relay may also
-- correct moves it misread, so the board keeps only the moves that are still the same and reads the rest again.
function ReviewScreen:update(game)
    if self.closed then
        return
    end
    local following = self.index == self.available
    local before, had_result = self.available, self.game.result_text
    local same = 0
    while same < self.available and game.moves[same + 1] and game.moves[same + 1].uci == self.game.moves[same + 1].uci do
        same = same + 1
    end
    for i = same + 1, self.available do
        self.positions[i], self.last_moves[i] = nil, nil
    end
    self.available = same
    self.game = game
    self:extend()
    if following or self.index > self.available then
        self.index = self.available
    end
    if self.available ~= before or same < before or game.result_text ~= had_result then
        self:render()
    end
end

-- The seconds left of each side at the position shown, from the last move each one played, or nil.
function ReviewScreen:clocks()
    local white, black
    for i = self.index, 1, -1 do
        local move = self.game.moves[i]
        local mover = self.positions[i - 1].turn
        if mover == "w" and white == nil then
            white = move.clock or false
        elseif mover == "b" and black == nil then
            black = move.clock or false
        end
        if white ~= nil and black ~= nil then
            break
        end
    end
    return white or nil, black or nil
end
-- The move number of a half move, from the move number of the FEN and who moved first, and whether white played it.
function ReviewScreen:move_number(index)
    local ply = index + (self.positions[0].turn == "b" and 1 or 0)
    return self.first_number - 1 + math.ceil(ply / 2), ply % 2 == 1
end

-- "18." or "18...".
function ReviewScreen:move_label(index)
    local number, white = self:move_number(index)
    return string.format("%d%s", number, white and "." or "...")
end

-- The phase a half move starts, as the analysis of the site divides the game, when it is one the review has.
function ReviewScreen:phase_at(index)
    local summary = self.game.summary
    if not summary or index < 1 or index > self.available then
        return nil
    elseif summary.middle == index then
        return self.s.review_middlegame
    elseif summary.ending == index then
        return self.s.review_endgame
    end
end

-- The evaluation after a move in words, for white or black, or nil without one.
function ReviewScreen:evaluation_words(move)
    local s = self.s
    if move.white_mate then
        return string.format(move.white_mate > 0 and s.eval_white_mate or s.eval_black_mate, math.abs(move.white_mate))
    elseif move.white_score then
        local pawns = math.abs(move.white_score) / 100
        if pawns < 0.3 then
            return s.eval_equal
        end
        local value = string.format("%.1f", pawns):gsub("%.", s.decimal_separator)
        return string.format(move.white_score > 0 and s.eval_white or s.eval_black, value)
    end
end

-- The better move of a marked move, as a move of the position before it, or nil.
function ReviewScreen:better_move(index)
    local move = self.game.moves[index]
    if not move or not move.judgment or not move.best_uci or move.best_uci == move.uci or not self.positions[index - 1] then
        return nil
    end
    return Chess.parse_uci(self.positions[index - 1], move.best_uci)
end

-- Who analyzed the game, on every move, so no evaluation of the plugin's engine passes for one of Lichess.
function ReviewScreen:source_tag()
    local summary = self.game.summary
    if not summary then
        return nil
    end
    return summary.source == "plugin" and self.s.engine_tag or self.s.lichess_tag
end

-- "Move 5 · black": the number of a half move and who played it.
function ReviewScreen:move_title(index)
    local s = self.s
    local number = self:move_number(index)
    local color = self.positions[index - 1].turn == "w" and s.color_white or s.color_black
    return string.format(s.review_move_title, number, color:lower())
end

-- The clocks of a game with them, a broadcast, for the card of the move: each side with the time it had then. An analyzed game shows the analysis there instead, so its judgments and who made them are never hidden.
function ReviewScreen:panel_clocks()
    if self.game.summary then
        return nil
    end
    local white_clock, black_clock = self:clocks()
    if not white_clock and not black_clock then
        return nil
    end
    local s = self.s
    local turn = self.positions[self.index].turn
    return {
        { label = s.color_white:lower(), clock = white_clock and Broadcast.clock_text(white_clock) or "-", active = white_clock ~= nil and turn == "w" },
        { label = s.color_black:lower(), clock = black_clock and Broadcast.clock_text(black_clock) or "-", active = black_clock ~= nil and turn == "b" },
    }
end

-- The card under the board: what move it is, the move and its judgment, the better move with its arrow, the evaluation in words. The judgment is in its tag, so the move has no sign of its own.
function ReviewScreen:panel()
    local s, game = self.s, self.game
    if self.index == 0 then
        return { title = s.review_before_first, source = self:source_tag(), move = s.start_pos, detail = game.intro, clocks = self:panel_clocks() }
    end
    local move = game.moves[self.index]
    local panel = { title = self:move_title(self.index), source = self:source_tag(), move = move.san or move.uci, clocks = self:panel_clocks() }
    local phase = self:phase_at(self.index)
    if move.judgment then
        panel.tag, panel.tag_solid = s.judgments[move.judgment] or move.judgment, true
    elseif phase then
        panel.tag, phase = phase, nil
    end
    local better = self:better_move(self.index)
    local better_san = move.best or (better and Chess.to_san(self.positions[self.index - 1], better))
    panel.evaluation = self:evaluation_words(move)
    local result = self.index == self.available and game.result_text or nil
    if better_san then
        panel.detail = string.format(better and s.review_better_arrow or s.review_better, better_san)
        -- On the last move the result says more than the evaluation it ended with.
        panel.evaluation = result or panel.evaluation
    elseif result then
        panel.detail = result
    elseif phase then
        panel.detail = phase
    end
    return panel
end

-- The bar of the evaluation after the move shown, as Lichess draws its own: white's share from its chances to win, and the number of pawns, or the mate, at its foot. Nothing without an evaluation.
function ReviewScreen:evaluation_bar()
    local move = self.index > 0 and self.game.moves[self.index] or nil
    if not move then
        return nil
    end
    if move.white_mate then
        return { white = move.white_mate > 0 and 1 or 0, text = "#" .. math.abs(move.white_mate) }
    elseif move.white_score then
        local chances = 2 / (1 + math.exp(-0.00368208 * move.white_score)) - 1
        local text = string.format("%.1f", math.abs(move.white_score) / 100):gsub("%.", self.s.decimal_separator)
        return { white = 0.5 + 0.5 * chances, text = text }
    end
end

-- The panel in one line, for what reads the status of a board; the review draws the panel itself.
function ReviewScreen:status_text(panel)
    if self.analysis then
        return string.format(self.s.engine_progress, self.progress_done or 1, self.progress_total or 1)
    end
    panel = panel or self:panel()
    local parts = {}
    for _, key in ipairs({ "move", "tag", "detail", "evaluation" }) do
        parts[#parts + 1] = panel[key]
    end
    return table.concat(parts, " · ")
end

function ReviewScreen:render(what)
    local s, game = self.s, self.game
    local live = self.opts.refresh ~= nil and not game.result_text
    local panel = self:panel()
    self.screen:show({
        flipped = self.flipped,
        position = self.positions[self.index],
        last_move = self.last_moves[self.index],
        band = { white = game.white or "?", black = game.black or "?", result = game.score, live = live and s.broadcast_live or nil },
        eval = self:evaluation_bar(),
        status = self:status_text(panel),
        panel = panel,
        shapes = self:better_shapes(),
        progress = self.analysis and { title = s.engine_analyzing, done = self.progress_done or 1, total = self.progress_total or 1, detail = string.format(s.engine_progress_detail, self.progress_done or 1, self.progress_total or 1) } or nil,
        buttons = {
            { id = "back", label = s.back },
            { id = "first", label = s.first },
            { id = "previous", label = s.previous },
            { id = "next", label = s.next },
            { id = "last", label = s.last },
            self.analysis and { id = "stop", label = s.stop } or { id = "more", label = s.more },
        },
    }, what)
end

function ReviewScreen:better_shapes()
    local better = self.index > 0 and self:better_move(self.index)
    if better then
        return { { from = better.from, to = better.to, brush = "yellow" } }
    end
end

function ReviewScreen:go(index)
    index = math.max(0, math.min(self.available, index))
    if index ~= self.index then
        self.index = index
        self:render()
    end
end

function ReviewScreen:on_button(button)
    if button == "back" then
        UIManager:close(self.screen)
    elseif button == "first" then
        self:go(0)
    elseif button == "previous" then
        self:go(self.index - 1)
    elseif button == "next" then
        self:go(self.index + 1)
    elseif button == "last" then
        self:go(self.available)
    elseif button == "more" then
        self:more_menu()
    elseif button == "stop" and self.analysis then
        self.analysis:cancel()
        self.analysis = nil
        self:render()
    end
end

-- The choice of analyzing every game of Lichess of the reader at its end, where the reader reviews: once on, the
-- question of open_at_end no longer shows, so here is where it goes off again.
function ReviewScreen:analyze_always_row(page)
    local s, app = self.s, self.app
    if not self.opts.reader_color or not self.opts.game_id or not EngineAnalysis.available(app) then
        return nil
    end
    return { kind = "toggle", text = s.analyze_always, on = app:option("analyze_always"), on_text = s.yes, off_text = s.no, callback = function()
        app:save_setting("analyze_always", not app:option("analyze_always"))
        page:reload()
    end }
end

function ReviewScreen:more_menu()
    local s, opts = self.s, self.opts
    local rows = { { text = s.moves, callback = function() self:show_moves() end } }
    if self.game.summary then
        table.insert(rows, 1, { text = s.review_summary, callback = function() self:show_summary() end })
    end
    -- What Lichess knows needs the online part, which a game played offline is reviewed without.
    if self.app.net then
        table.insert(rows, 1, { text = s.analysis, callback = function() self:show_analysis() end })
    end
    -- A game the site did not analyze can be analyzed here, by the plugin's own Stockfish, and says so. Not one still
    -- being played: its next refresh would replace what the analysis wrote.
    if not self.game.summary and not opts.refresh and self.available > 0 and EngineAnalysis.available(self.app) then
        rows[#rows + 1] = { text = s.analyze_plugin, detail = s.analyze_plugin_detail, callback = function() self:analyze_here() end }
    end
    if opts.game_id then
        rows[#rows + 1] = {
            text = opts.bookmarked and s.bookmark_remove or s.bookmark_add,
            callback = function() self:toggle_bookmark() end,
        }
    end
    self.app:open_page{ title = s.more, close_on_tap = true, build = function(page)
        local list = { unpack(rows) }
        list[#list + 1] = self:analyze_always_row(page)
        return list
    end }
end

-- Right after the reader's game, from its board: the summary when Lichess analyzed the game; otherwise the plugin's
-- engine, at once when the reader asked for it always, or offered first.
function ReviewScreen:open_at_end()
    if self.game.summary then
        self:show_summary()
    elseif self.available > 0 and EngineAnalysis.available(self.app) then
        if self.app:option("analyze_always") then
            self:analyze_here()
        else
            self:offer_analysis()
        end
    end
end

-- How long the plugin's engine takes for this game, about.
function ReviewScreen:analysis_time_text()
    return EngineAnalysis.time_text(self.s, EngineAnalysis.seconds_for(self.app, self.available))
end

function ReviewScreen:offer_analysis()
    local s = self.s
    self.app:open_page{ title = s.review_game, build = function(page)
        local rows = {
            { kind = "hero", icon = "\226\153\158", text = s.review_no_analysis, detail = s.review_no_analysis_detail },
            { kind = "primary", text = s.analyze_plugin, callback = function()
                UIManager:close(page)
                self:analyze_here()
            end },
            { kind = "text", text = string.format(s.analyze_plugin_explain, self:analysis_time_text()) },
            { kind = "secondary", text = s.review_without_analysis, callback = function() UIManager:close(page) end },
        }
        -- Either can be missing, so they are added one at a time.
        rows[#rows + 1] = self.app:analysis_level_row(page)
        rows[#rows + 1] = self:analyze_always_row(page)
        return rows
    end }
end

-- The first move the reader played that the analysis called a mistake or a blunder, or nil.
function ReviewScreen:first_mistake_of_reader()
    local color = self.opts.reader_color == "black" and "b" or "w"
    for i = 1, self.available do
        local judgment = self.game.moves[i].judgment
        if self.positions[i - 1].turn == color and (judgment == "Mistake" or judgment == "Blunder") then
            return i
        end
    end
end

function ReviewScreen:analyze_here()
    local moves = {}
    for i = 1, self.available do
        moves[i] = self.game.moves[i].uci
    end
    self.analysis = EngineAnalysis.start{
        app = self.app,
        window = self.screen,
        initial_fen = self.game.initial_fen,
        moves = moves,
        on_progress = function(done, total)
            self.progress_done, self.progress_total = done, total
            self:render()
        end,
        on_done = function(result)
            self.analysis = nil
            if self.closed then
                return
            end
            if not result then
                self:render()
                self.app:info(self.s.engine_stopped)
                return
            end
            for i, entry in ipairs(result.moves) do
                local move = self.game.moves[i]
                if move then
                    move.eval_text, move.judgment, move.best, move.white_cp = entry.eval_text, entry.judgment, entry.best, entry.white_cp
                    move.best_uci, move.white_score, move.white_mate = entry.best_uci, entry.white_score, entry.white_mate
                end
            end
            self.game.summary = result.summary
            self.game.intro = self.s.review_plugin_analysis
            self:render()
            self:show_summary()
        end,
    }
    if not self.analysis then
        self.app:info(self.s.engine_unavailable)
        return
    end
    -- The first position was announced before the review knew it was analyzing.
    self:render()
end

function ReviewScreen:show_summary()
    local s, game, summary = self.s, self.game, self.game.summary
    local reader = self.opts.reader_color
    self.app:open_page{ title = s.review_summary, close_on_tap = true, build = function(page)
        -- Whose analysis it is comes first, the plugin's or the site's.
        local rows = { { kind = "text", text = summary.source == "plugin" and s.review_plugin_analysis or s.review_lichess_analysis } }
        rows[#rows + 1] = EvalChart.row(game.moves, self.available, s.review_chart_legend, page.scale, function(index)
            self:go(index)
        end)
        for _, side in ipairs({ { "white", s.color_white, game.white }, { "black", s.color_black, game.black } }) do
            local data = summary[side[1]]
            local name = side[3] or "?"
            if reader == side[1] then
                name = string.format(s.review_you, name)
            end
            rows[#rows + 1] = { kind = "section", text = string.format("%s · %s", side[2], name) }
            local figures = {}
            if data.accuracy then
                figures[1] = { value = string.format("%d%%", data.accuracy), label = s.review_accuracy_label }
            end
            figures[#figures + 1] = { value = tostring(data.inaccuracy), label = s.review_inaccuracies }
            figures[#figures + 1] = { value = tostring(data.mistake), label = s.review_mistakes }
            figures[#figures + 1] = { value = tostring(data.blunder), label = s.review_blunders }
            if data.acpl then
                figures[#figures + 1] = { value = tostring(data.acpl), label = s.review_acpl_label }
            end
            rows[#rows + 1] = { kind = "figures", items = figures }
        end
        -- Only the reader's own mistakes, so the button always does the same; with none, it says so.
        if reader then
            local first = self:first_mistake_of_reader()
            rows[#rows + 1] = { kind = "buttons", items = {
                first and { text = s.my_first_mistake, primary = true, callback = function() self:go(first) end }
                    or { text = s.no_mistake_of_mine, disabled = true },
                { text = s.see_game, callback = function() end },
            } }
        end
        -- The phases go to their move, so the summary leads back into the game, with the accuracy of each side in
        -- them when the site gives it.
        local phase_rows = {}
        local white_phases, black_phases = summary.white.phases, summary.black.phases
        local function percent(phases, key)
            return phases and string.format("%d%%", phases[key]) or "?"
        end
        local function detail(key)
            return (white_phases or black_phases) and string.format(s.review_phase_detail, percent(white_phases, key), percent(black_phases, key)) or nil
        end
        if white_phases or black_phases then
            phase_rows[1] = { text = s.review_opening, detail = detail("opening"), value = string.format(s.review_move_value, self:move_label(1)), callback = function()
                self:go(1)
            end }
        end
        for _, phase in ipairs({ { summary.middle, s.review_middlegame, "middlegame" }, { summary.ending, s.review_endgame, "endgame" } }) do
            if phase[1] and self:phase_at(phase[1]) then
                phase_rows[#phase_rows + 1] = { text = phase[2], detail = detail(phase[3]), value = string.format(s.review_move_value, self:move_label(phase[1])), callback = function()
                    self:go(phase[1])
                end }
            end
        end
        if #phase_rows > 0 then
            rows[#rows + 1] = { kind = "section", text = s.review_phases }
            for _, row in ipairs(phase_rows) do
                rows[#rows + 1] = row
            end
        end
        return rows
    end }
end

-- The moves already read for the board, with the one shown marked. A tap on a move goes to it. The notation comes
-- with the game from Lichess, and is only written here for a move that lacks it.
function ReviewScreen:show_moves()
    local sans, ucis = {}, {}
    for index = 1, self.available do
        sans[index] = self.game.moves[index].san or Chess.to_san(self.positions[index - 1], self.last_moves[index])
        ucis[index] = self.game.moves[index].uci
    end
    local marks = {}
    for index = 1, self.available do
        marks[index] = self:phase_at(index)
    end
    MoveList.show(self.app, sans, self.first_number, self.positions[0].turn, {
        current = self.index,
        marks = marks,
        on_pick = function(index) self:go(index) end,
        -- The name Lichess gave the game, so the list and the start of the review agree.
        opening = self.game.opening,
        initial_fen = self.game.initial_fen,
        moves = table.concat(ucis, " "),
    })
end

function ReviewScreen:toggle_bookmark()
    local s, opts = self.s, self.opts
    local add = not opts.bookmarked
    self.app:with_feature("favorites", function()
        self.app.net:request(Api.bookmark(opts.game_id, add), function(status)
            self.app:report_or(status, function()
                opts.bookmarked = add
                self.app:info(add and s.bookmark_added or s.bookmark_removed)
            end)
        end)
    end)
end

-- One question at a time, as Lichess asks. Only a game already finished gets here, never one under way.
-- The reader's own games are asked with the color they played, or in a game of someone else with the side to move.
function ReviewScreen:show_analysis()
    local position = self.positions[self.index]
    ReviewScreen.analyze(self.app, position, self.opts.reader_color or (position.turn == "b" and "black" or "white"))
end

local function own_games_title(s, color)
    return color == "black" and s.analysis_own_black or s.analysis_own_white
end

-- The most played moves of an explorer, each with a bar of how its games ended.
local function games_rows(s, data, empty_text)
    local games = Analysis.games(data)
    if not games then
        return { { kind = "text", text = empty_text, center = true } }
    end
    -- The name of an opening can be long, so it goes on lines that wrap, with what the bars show.
    local rows = {
        { kind = "section", text = s.analysis_moves_section },
        { kind = "text", text = games.opening and (games.opening .. "\n" .. s.analysis_legend) or s.analysis_legend, center = true },
    }
    for _, move in ipairs(games.moves) do
        rows[#rows + 1] = { kind = "split", text = move.san, white = move.white, draws = move.draws, black = move.black, value = Api.format_count(move.total) }
    end
    return rows
end

-- How long the plugin's Stockfish looks at a position on the analysis page: depth 12 to 14 on the Kindle.
ReviewScreen.ENGINE_MILLISECONDS = 2500
-- From this depth on, a mate is shown without its depth: Stockfish reaches 245 once it has proven one.
ReviewScreen.DEEPEST_SHOWN = 100

-- What Lichess knows about a position: the cloud evaluation, the most played moves and, with few pieces, the
-- tablebase. For a finished game in the review, and for a position set up in the editor. Below it, on request, the
-- games of masters and the reader's own games with color ("white" or "black").
-- The plugin's Stockfish comes only on request, with a button: online, only where the cloud has no evaluation, since the cloud of Lichess is far stronger and the reader asked for Lichess; offline (no app.net, from the editor), the page has only that evaluation.
function ReviewScreen.analyze(app, position, color)
    local s, net = app.strings, app.net
    local offline = not net
    local fen = Chess.to_fen(position)
    local answers, reached = {}, false
    local engine = {}
    local page
    local function take(name, status, body)
        reached = reached or status ~= nil
        answers[name] = status == 200 and app.decode(body) or nil
    end
    local function redraw()
        if page then
            page:reload()
        end
    end
    -- Whether the button is offered: a position with a move, where the plugin's Stockfish runs. Asked once per page.
    local offered
    local function engine_offered()
        if offered == nil then
            offered = #Chess.legal_moves(position) > 0 and EngineAnalysis.available(app)
        end
        return offered
    end
    local function start_engine()
        if engine.thinking or engine.eval then
            return
        end
        -- One that failed is dropped, so trying again starts another Stockfish.
        if engine.engine_player and not engine.engine_player:usable() then
            engine.engine_player:close()
            engine.engine_player = nil
        end
        local player = EnginePlayer.of(engine, app, page)
        if not player then
            engine.engine_player, engine.failed = nil, true
            redraw()
            return
        end
        engine.thinking, engine.failed = true, false
        redraw()
        player:best_move({ fen = fen, milliseconds = ReviewScreen.ENGINE_MILLISECONDS }, function(_, result)
            engine.thinking = false
            engine.eval = Analysis.engine_eval(position, result)
            engine.failed = engine.eval == nil
            redraw()
        end)
    end
    -- The evaluation of the plugin's Stockfish: its button, the search under way, what it found, or that it failed with the button to try again.
    local function add_engine(rows)
        local eval = engine.eval
        if eval then
            -- A mate it has proven ends the search at the deepest depth Stockfish has (245), which would read as a fault, so then only whose it is.
            local deepest = eval.mate and eval.depth >= ReviewScreen.DEEPEST_SHOWN
            rows[#rows + 1] = { kind = "metric", text = deepest and s.analysis_engine or string.format(s.analysis_engine_depth, eval.depth), detail = eval.line ~= "" and string.format(s.analysis_line, eval.line) or nil, value = eval.score }
        elseif engine.thinking then
            rows[#rows + 1] = { kind = "text", text = s.analysis_engine_thinking, center = true }
        else
            if engine.failed then
                rows[#rows + 1] = { kind = "text", text = s.analysis_engine_failed, center = true }
            end
            if engine_offered() then
                rows[#rows + 1] = { kind = "secondary", text = s.analyze_plugin, keep_open = true, callback = start_engine }
            end
        end
    end
    local function build()
        local rows = {}
        if offline then
            rows[#rows + 1] = { kind = "section", text = s.analysis_eval_section }
            add_engine(rows)
            return rows
        end
        local ending = Analysis.ending(s, position, answers.tablebase)
        if ending then
            rows[#rows + 1] = { kind = "section", text = s.analysis_end_section }
            rows[#rows + 1] = { kind = "text", text = ending }
        end
        rows[#rows + 1] = { kind = "section", text = s.analysis_eval_section }
        local eval = Analysis.eval(position, answers.cloud)
        if eval then
            rows[#rows + 1] = { kind = "metric", text = string.format(s.analysis_depth, eval.depth), detail = eval.line ~= "" and string.format(s.analysis_line, eval.line) or nil, value = eval.score }
        else
            rows[#rows + 1] = { kind = "text", text = s.analysis_no_eval, center = true }
            -- With the result of perfect play above, a short search could only contradict it.
            if not ending then
                add_engine(rows)
            end
        end
        for _, row in ipairs(games_rows(s, answers.explorer, s.analysis_no_games)) do
            rows[#rows + 1] = row
        end
        rows[#rows + 1] = { kind = "section", text = s.analysis_more_section }
        rows[#rows + 1] = { text = s.analysis_masters, callback = function() ReviewScreen.masters(app, position) end }
        if app.my_name and color then
            rows[#rows + 1] = { text = own_games_title(s, color), callback = function()
                ReviewScreen.own_games(app, position, color, page)
            end }
        end
        return rows
    end
    local function open()
        page = app:open_page{ title = s.analysis_title, build = build, on_closed = function()
            if engine.engine_player then
                engine.engine_player:close()
            end
        end }
    end
    if offline then
        open()
        return
    end
    local function finish()
        if not reached then
            app:info(s.no_network)
            return
        end
        open()
    end
    app:info(s.analysis_loading, 2)
    net:request(Api.cloud_eval(fen), function(status, body)
        take("cloud", status, body)
        net:request(Api.explorer(fen), function(explorer_status, explorer_body)
            take("explorer", explorer_status, explorer_body)
            if Analysis.piece_count(position) > Analysis.TABLEBASE_PIECES then
                finish()
                return
            end
            net:request(Api.tablebase(fen), function(tablebase_status, tablebase_body)
                take("tablebase", tablebase_status, tablebase_body)
                finish()
            end)
        end)
    end)
end

function ReviewScreen.masters(app, position)
    local s = app.strings
    if not app.net then
        app:info(s.no_network)
        return
    end
    app:info(s.analysis_loading, 2)
    app.net:request(Api.explorer_masters(Chess.to_fen(position)), function(status, body)
        app:report_or(status, function()
            app:open_list(s.analysis_masters, games_rows(s, app.decode(body), s.analysis_masters_none))
        end)
    end)
end

-- How long the reader's games are waited for: Lichess indexes them on the first request, which can take minutes for
-- a busy account, so what has come by then is shown.
ReviewScreen.OWN_GAMES_WAIT = 20

local function is_open(app, page)
    for _, other in ipairs(app.pages or {}) do
        if other == page then
            return true
        end
    end
    return false
end

-- One at a time, and only shown while the analysis it came from is still open.
function ReviewScreen.own_games(app, position, color, page)
    local s = app.strings
    local net = app.net
    if not net then
        app:info(s.no_network)
        return
    end
    if app.own_games_stream then
        app:info(s.analysis_loading, 2)
        return
    end
    local latest, stream
    local function finish(status, ended)
        if app.own_games_stream ~= stream then
            return
        end
        app.own_games_stream = nil
        if not ended and app.net == net then
            -- What reached the file since the last tick counts too.
            net:read_stream(stream)
            net:close_stream(stream)
        end
        if page and not is_open(app, page) then
            return
        end
        if ended and status ~= 200 then
            app:info(app:error_text(status))
            return
        elseif type(latest) == "table" and latest.error then
            app:info(s.unexpected_error)
            return
        end
        local rows
        if latest then
            rows = games_rows(s, latest, s.analysis_own_none)
            if not ended then
                rows[#rows + 1] = { kind = "text", text = s.analysis_own_partial }
            end
        else
            rows = { { kind = "text", text = ended and s.analysis_own_none or s.analysis_own_waiting } }
        end
        app:open_list(own_games_title(s, color), rows)
    end
    app:info(s.analysis_loading, 2)
    stream = net:stream(Api.explorer_player(Chess.to_fen(position), app.my_name, color), function(line)
        latest = app.decode(line) or latest
    end, function(status)
        finish(status, true)
    end)
    app.own_games_stream = stream
    Sleep.schedule(app, ReviewScreen.OWN_GAMES_WAIT, function()
        finish(nil, false)
    end)
end

-- A tap on the board moves too: the left side goes back and the right side goes forward.
function ReviewScreen:on_square(square)
    local file = (square - 1) % 8
    if self.flipped then
        file = 7 - file
    end
    self:go(self.index + (file < 3 and -1 or 1))
end

return ReviewScreen
