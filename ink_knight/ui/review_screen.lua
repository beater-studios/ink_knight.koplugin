-- Goes through a finished game, move by move, with what Lichess knows about each position.
local UIManager = require("ui/uimanager")

local Analysis = require("ink_knight/analysis")
local Sleep = require("ink_knight/sleep")
local Api = require("ink_knight/api")
local BoardScreen = require("ink_knight/ui/board_screen")
local Chess = require("ink_knight/chess")
local MoveList = require("ink_knight/ui/move_list")

local ReviewScreen = {}
ReviewScreen.__index = ReviewScreen

-- game: { moves = { { uci, san, eval_text, judgment, best } }, intro, initial_fen, summary }, plus white, black and
-- result for the bars; best is the better move, in the usual notation, when the engine of the plugin found one, and
-- summary comes from Game.analysis_summary.
-- opts: flipped, game_id and bookmarked, for the favorites, and reader_color when the reader played the game.
function ReviewScreen.open(app, game, opts)
    opts = opts or {}
    local self = setmetatable({ app = app, s = app.strings, game = game, flipped = opts.flipped == true, index = 0, opts = opts }, ReviewScreen)
    local start = Chess.start_position(game.initial_fen)
    -- Numbered from the move number of the FEN, as the list of moves of the game is.
    self.first_number = tonumber(tostring(game.initial_fen or ""):match("%s(%d+)%s*$")) or 1
    self.positions = { [0] = start }
    self.last_moves = {}
    local position = start
    for i, move in ipairs(game.moves) do
        local next_position, played = Chess.apply_uci(position, move.uci)
        if not next_position then
            break
        end
        self.positions[i], self.last_moves[i] = next_position, played
        position = next_position
        self.available = i
    end
    self.available = self.available or 0
    self.index = math.min(self.index, self.available)
    self.screen = BoardScreen:new{
        state = { flipped = self.flipped },
        on_square = function(square) self:on_square(square) end,
        on_button = function(button) self:on_button(button) end,
        on_closed = function() if opts.on_closed then opts.on_closed() end end,
        broken_text = app.strings.unexpected_error,
    }
    UIManager:show(self.screen)
    self:render("full")
    return self
end

-- "18." or "18...": the move number of a half move, from the move number of the FEN and who moved first.
function ReviewScreen:move_label(index)
    local ply = index + (self.positions[0].turn == "b" and 1 or 0)
    return string.format("%d%s", self.first_number - 1 + math.ceil(ply / 2), ply % 2 == 1 and "." or "...")
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

function ReviewScreen:status_text()
    local s, game = self.s, self.game
    local move = game.moves[self.index]
    local parts = {}
    if self.index == 0 then
        parts[1] = game.intro or s.start_pos
    else
        parts[1] = self:move_label(self.index) .. " " .. (move.san or move.uci)
        -- Right after the move, since the line has room for one line only and the end is what gets cut.
        parts[#parts + 1] = self:phase_at(self.index)
        if move.eval_text then
            parts[#parts + 1] = move.eval_text
        end
        if move.judgment then
            parts[#parts + 1] = s.judgments[move.judgment] or move.judgment
        end
        if move.best then
            parts[#parts + 1] = string.format(s.review_best, move.best)
        end
    end
    if self.index == self.available and game.result_text then
        parts[#parts + 1] = game.result_text
    end
    return table.concat(parts, " · ")
end

function ReviewScreen:render(what)
    local s = self.s
    local top, bottom = self.game.black or "?", self.game.white or "?"
    if self.flipped then
        top, bottom = bottom, top
    end
    self.screen:show({
        flipped = self.flipped,
        position = self.positions[self.index],
        last_move = self.last_moves[self.index],
        top = { name = top },
        bottom = { name = bottom },
        status = self:status_text(),
        buttons = {
            { id = "back", label = s.back },
            { id = "first", label = "|<" },
            { id = "previous", label = "<" },
            { id = "next", label = ">" },
            { id = "last", label = ">|" },
            { id = "more", label = s.more },
        },
    }, what)
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
    end
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
    if opts.game_id then
        rows[#rows + 1] = {
            text = opts.bookmarked and s.bookmark_remove or s.bookmark_add,
            callback = function() self:toggle_bookmark() end,
        }
    end
    self.app:choose(s.more, rows, { close_on_tap = true })
end

function ReviewScreen:show_summary()
    local s, game, summary = self.s, self.game, self.game.summary
    local rows = {}
    for _, side in ipairs({ { "white", s.color_white, game.white }, { "black", s.color_black, game.black } }) do
        local data = summary[side[1]]
        rows[#rows + 1] = { kind = "section", text = string.format("%s · %s", side[2], side[3] or "?") }
        if data.accuracy then
            local phases = data.phases
            rows[#rows + 1] = {
                kind = "metric", text = s.review_accuracy_label, value = string.format("%d%%", data.accuracy),
                detail = phases and string.format(s.review_phase_accuracy, phases.opening, phases.middlegame, phases.endgame) or nil,
            }
        end
        local figures = {
            { value = tostring(data.inaccuracy), label = s.review_inaccuracies },
            { value = tostring(data.mistake), label = s.review_mistakes },
            { value = tostring(data.blunder), label = s.review_blunders },
        }
        if data.acpl then
            figures[#figures + 1] = { value = tostring(data.acpl), label = s.review_acpl_label }
        end
        rows[#rows + 1] = { kind = "figures", items = figures }
    end
    -- The phases go to their move, so the summary leads back into the game.
    local phase_rows = {}
    for _, phase in ipairs({ { summary.middle, s.review_middlegame }, { summary.ending, s.review_endgame } }) do
        if phase[1] and self:phase_at(phase[1]) then
            phase_rows[#phase_rows + 1] = { text = phase[2], value = string.format(s.review_move_value, self:move_label(phase[1])), callback = function()
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
    self.app:open_page{ title = s.review_summary, rows = rows, close_on_tap = true }
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

-- What Lichess knows about a position: the cloud evaluation, the most played moves and, with few pieces, the
-- tablebase. For a finished game in the review, and for a position set up in the editor. Below it, on request, the
-- games of masters and the reader's own games with color ("white" or "black").
function ReviewScreen.analyze(app, position, color)
    local s, net = app.strings, app.net
    local fen = Chess.to_fen(position)
    local answers, reached = {}, false
    local function take(name, status, body)
        reached = reached or status ~= nil
        answers[name] = status == 200 and app.decode(body) or nil
    end
    local function finish()
        if not reached then
            app:info(s.no_network)
            return
        end
        local rows = {}
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
        end
        for _, row in ipairs(games_rows(s, answers.explorer, s.analysis_no_games)) do
            rows[#rows + 1] = row
        end
        rows[#rows + 1] = { kind = "section", text = s.analysis_more_section }
        rows[#rows + 1] = { text = s.analysis_masters, callback = function() ReviewScreen.masters(app, position) end }
        local page
        if app.my_name and color then
            rows[#rows + 1] = { text = own_games_title(s, color), callback = function()
                ReviewScreen.own_games(app, position, color, page)
            end }
        end
        page = app:open_list(s.analysis_title, rows)
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
