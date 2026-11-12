-- Goes through a finished game, move by move, with what Lichess knows about each position.
local UIManager = require("ui/uimanager")

local Analysis = require("ink_knight/analysis")
local Api = require("ink_knight/api")
local BoardScreen = require("ink_knight/ui/board_screen")
local Chess = require("ink_knight/chess")
local MoveList = require("ink_knight/ui/move_list")

local ReviewScreen = {}
ReviewScreen.__index = ReviewScreen

-- game: { moves = { { uci, san, eval_text, judgment } }, intro }, plus white, black and result for the bars.
-- opts: flipped, game_id and bookmarked, for the favorites.
function ReviewScreen.open(app, game, opts)
    opts = opts or {}
    local self = setmetatable({ app = app, s = app.strings, game = game, flipped = opts.flipped == true, index = 0, opts = opts }, ReviewScreen)
    local start = Chess.parse_fen(Chess.START_FEN)
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

function ReviewScreen:status_text()
    local s, game = self.s, self.game
    local move = game.moves[self.index]
    local parts = {}
    if self.index == 0 then
        parts[1] = game.intro or s.start_pos
    else
        parts[1] = string.format("%d%s %s", math.ceil(self.index / 2), self.index % 2 == 1 and "." or "...", move.san or move.uci)
        if move.eval_text then
            parts[#parts + 1] = move.eval_text
        end
        if move.judgment then
            parts[#parts + 1] = s.judgments[move.judgment] or move.judgment
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
    local rows = {
        { text = s.analysis, callback = function() self:show_analysis() end },
        { text = s.moves, callback = function() self:show_moves() end },
    }
    if opts.game_id then
        rows[#rows + 1] = {
            text = opts.bookmarked and s.bookmark_remove or s.bookmark_add,
            callback = function() self:toggle_bookmark() end,
        }
    end
    self.app:choose(s.more, rows, { close_on_tap = true })
end

-- The moves already read for the board, with the one shown marked. A tap on a move goes to it. The notation comes
-- with the game from Lichess, and is only written here for a move that lacks it.
function ReviewScreen:show_moves()
    local sans, ucis = {}, {}
    for index = 1, self.available do
        sans[index] = self.game.moves[index].san or Chess.to_san(self.positions[index - 1], self.last_moves[index])
        ucis[index] = self.game.moves[index].uci
    end
    MoveList.show(self.app, sans, 1, "w", {
        current = self.index,
        on_pick = function(index) self:go(index) end,
        -- The name Lichess gave the game, so the list and the start of the review agree.
        opening = self.game.intro,
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
function ReviewScreen:show_analysis()
    ReviewScreen.analyze(self.app, self.positions[self.index])
end

-- What Lichess knows about a position: the cloud evaluation, the most played moves and, with few pieces, the
-- tablebase. For a finished game in the review, and for a position set up in the editor.
function ReviewScreen.analyze(app, position)
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
        app:open_list(s.analysis_title, { { kind = "text", text = Analysis.text(s, position, answers) } })
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

-- A tap on the board moves too: the left side goes back and the right side goes forward.
function ReviewScreen:on_square(square)
    local file = (square - 1) % 8
    if self.flipped then
        file = 7 - file
    end
    self:go(self.index + (file < 3 and -1 or 1))
end

return ReviewScreen
