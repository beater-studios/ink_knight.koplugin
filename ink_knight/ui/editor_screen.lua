-- The position editor on the board: a piece chosen from a palette goes where the reader taps, the same piece again
-- takes it away, and Done checks the position and offers to play from it, against the engine or between two people,
-- or to ask Lichess about it when the online part is open. The position is kept for the next time.
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")

local BoardScreen = require("ink_knight/ui/board_screen")
local Chess = require("ink_knight/chess")
local Editor = require("ink_knight/editor")

local EditorScreen = {}
EditorScreen.__index = EditorScreen

-- The chess symbols of FreeSerif, for the palette.
local GLYPHS = {
    K = "\226\153\148", Q = "\226\153\149", R = "\226\153\150", B = "\226\153\151", N = "\226\153\152", P = "\226\153\153",
    k = "\226\153\154", q = "\226\153\155", r = "\226\153\156", b = "\226\153\157", n = "\226\153\158", p = "\226\153\159",
}

function EditorScreen.open(app)
    local self = setmetatable({ app = app, s = app.strings, tool = "Q", flipped = false }, EditorScreen)
    self.position = Editor.new(app.settings:readSetting("editor_fen"))
    self.screen = BoardScreen:new{
        state = {},
        coordinates = true,
        on_square = function(square) self:on_square(square) end,
        on_button = function(button) self:on_button(button) end,
        on_closed = function() self:closed() end,
        broken_text = app.strings.unexpected_error,
    }
    UIManager:show(self.screen)
    self:render("full")
    return self
end

function EditorScreen:save()
    self.app.settings:saveSetting("editor_fen", Editor.fen(self.position))
    self.app.settings:flush()
end

function EditorScreen:closed()
    self.is_closed = true
    self:save()
end

function EditorScreen:tool_text()
    local s = self.s
    if self.tool == nil then
        return s.editor_erasing
    end
    return string.format(s.editor_placing, s.editor_pieces[self.tool])
end

function EditorScreen:render(what)
    if self.is_closed then
        return
    end
    local s = self.s
    self.screen:show({
        flipped = self.flipped,
        position = self.position,
        top = { name = self:tool_text() },
        bottom = { name = self.position.turn == "w" and s.editor_white_to_move or s.editor_black_to_move },
        status = self.message or "",
        buttons = {
            { id = "back", label = s.back },
            { id = "piece", label = s.editor_piece },
            { id = "turn", label = s.editor_turn },
            { id = "options", label = s.options_section },
            { id = "done", label = s.editor_done },
        },
    }, what)
end

function EditorScreen:changed()
    self.message = nil
    self:render()
end

function EditorScreen:on_square(square)
    Editor.place(self.position, square, self.tool)
    self:changed()
end

function EditorScreen:choose_piece()
    local s = self.s
    local items = {}
    for _, piece in ipairs(Editor.PIECES) do
        -- The names are written to follow "Placing:", so a tile starts them with a capital.
        items[#items + 1] = { icon = GLYPHS[piece], text = (s.editor_pieces[piece]:gsub("^%l", string.upper)), callback = function()
            self.tool = piece
            self:changed()
        end }
    end
    items[#items + 1] = { text = s.editor_erase, callback = function()
        self.tool = nil
        self:changed()
    end }
    self.app:choose(s.editor_piece, { { kind = "tiles", columns = 3, items = items } }, { close_on_tap = true })
end

function EditorScreen:options()
    local s = self.s
    local app = self.app
    app:open_page{ title = s.options_section, build = function(page)
        local rows = {}
        local possible = Editor.possible_castling(self.position)
        if possible ~= "" then
            rows[#rows + 1] = { kind = "section", text = s.editor_castling }
            for letter in possible:gmatch(".") do
                local on = self.position.castling:find(letter, 1, true) ~= nil
                rows[#rows + 1] = { kind = "toggle", text = s.editor_castling_names[letter], on = on, on_text = s.yes, off_text = s.no, callback = function()
                    Editor.toggle_castling(self.position, letter)
                    self:changed()
                    page:reload()
                end }
            end
            rows[#rows + 1] = { kind = "section", text = s.board_section }
        end
        rows[#rows + 1] = { text = s.editor_start, callback = function()
            self.position = Editor.new(Chess.START_FEN)
            self:changed()
            UIManager:close(page)
        end }
        rows[#rows + 1] = { text = s.editor_clear, callback = function()
            Editor.clear(self.position)
            self:changed()
            UIManager:close(page)
        end }
        rows[#rows + 1] = { text = s.flip_board, callback = function()
            self.flipped = not self.flipped
            self:changed()
            UIManager:close(page)
        end }
        rows[#rows + 1] = { text = s.editor_paste_fen, callback = function()
            UIManager:close(page)
            self:ask_fen()
        end }
        rows[#rows + 1] = { kind = "text", text = Editor.fen(self.position) }
        return rows
    end }
end

function EditorScreen:ask_fen()
    local s = self.s
    local dialog
    dialog = InputDialog:new{
        title = s.editor_paste_fen,
        input = Editor.fen(self.position),
        buttons = { {
            { text = s.cancel, id = "close", callback = function() UIManager:close(dialog) end },
            { text = s.editor_done, is_enter_default = true, callback = function()
                local position = Editor.read_fen(dialog:getInputText())
                UIManager:close(dialog)
                if position then
                    self.position = position
                    self:changed()
                else
                    self.app:info(s.editor_fen_bad)
                end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- What can be done with a position that can be played.
function EditorScreen:done()
    local s, app = self.s, self.app
    local problem = Editor.problem(self.position)
    if problem then
        self.message = s.editor_problems[problem]
        self:render()
        return
    end
    self:save()
    local fen = Editor.fen(self.position)
    local OfflineGame = require("ink_knight/ui/offline_game")
    local items = {}
    for level = 1, 4 do
        items[#items + 1] = { text = tostring(level), detail = s.level_short, callback = function()
            app:ask_color(function(color)
                UIManager:close(self.screen)
                app:close_pages()
                OfflineGame.open(app, { level = level, color_choice = color, initial_fen = fen })
            end)
        end }
    end
    local rows = {
        { kind = "section", text = s.editor_vs_engine },
        { kind = "tiles", columns = 4, items = items },
        { text = s.two_players, detail = s.two_players_detail, callback = function()
            app:choose_clock(s.two_players, true, function(preset)
                UIManager:close(self.screen)
                app:close_pages()
                OfflineGame.open(app, { two_players = true, clock = preset, initial_fen = fen })
            end)
        end },
    }
    if app.net then
        rows[#rows + 1] = { text = s.analysis, callback = function()
            require("ink_knight/ui/review_screen").analyze(app, Chess.parse_fen(fen))
        end }
    end
    app:open_list(s.editor_play_title, rows)
end

function EditorScreen:on_button(button)
    if button == "back" then
        UIManager:close(self.screen)
    elseif button == "piece" then
        self:choose_piece()
    elseif button == "turn" then
        Editor.set_turn(self.position, self.position.turn == "w" and "b" or "w")
        self:changed()
    elseif button == "options" then
        self:options()
    elseif button == "done" then
        self:done()
    end
end

return EditorScreen
