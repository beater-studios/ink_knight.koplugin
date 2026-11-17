-- The position editor on the board: a piece chosen from the palette under it goes where the reader taps, the same piece again takes it away, and Done checks the position and offers to play from it, against the engine or between two people,
-- or to ask Lichess about it when the online part is open. The position is kept for the next time.
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")

local BoardScreen = require("ink_knight/ui/board_screen")
local Chess = require("ink_knight/chess")
local Editor = require("ink_knight/editor")

local EditorScreen = {}
EditorScreen.__index = EditorScreen

function EditorScreen.open(app)
    local self = setmetatable({ app = app, s = app.strings, tool = "Q", flipped = false }, EditorScreen)
    self.position = Editor.new(app.settings:readSetting("editor_fen"))
    self.screen = BoardScreen:new{
        state = {},
        coordinates = true,
        palette = true,
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

function EditorScreen:render(what)
    if self.is_closed then
        return
    end
    local s = self.s
    local turn = self.position.turn == "w" and s.editor_white_to_move or s.editor_black_to_move
    self.screen:show({
        flipped = self.flipped,
        position = self.position,
        header = { title = s.editor, subtitle = turn },
        palette = { selected = self.tool or "erase", erase_label = s.editor_erase },
        status = self.message or "",
        buttons = {
            { id = "back", label = s.back },
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
        app:info(self.message)
        return
    end
    self:save()
    local fen = Editor.fen(self.position)
    local OfflineGame = require("ink_knight/ui/offline_game")
    local items = app:level_tiles(function(opts)
        UIManager:close(self.screen)
        app:close_pages()
        opts.initial_fen = fen
        OfflineGame.open(app, opts)
    end)
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
    -- Online, what Lichess knows; offline, the evaluation of the plugin's Stockfish, where it runs.
    if app.net or require("ink_knight/ui/engine_analysis").available(app) then
        rows[#rows + 1] = { text = s.analysis, callback = function()
            local position = Chess.parse_fen(fen)
            require("ink_knight/ui/review_screen").analyze(app, position, position.turn == "b" and "black" or "white")
        end }
    end
    app:open_list(s.editor_play_title, rows)
end

function EditorScreen:on_button(button)
    if button == "back" then
        UIManager:close(self.screen)
    elseif button:match("^tool:") then
        local tool = button:sub(6)
        self.tool = tool ~= "erase" and tool or nil
        self:changed()
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
