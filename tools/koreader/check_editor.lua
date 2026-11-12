-- Goes through the position editor on the real screens: the palette, pieces put and taken away, a position that
-- cannot be played and why, a game against the engine from the position (undo included, and continued later), a
-- game between two people with black to move, a FEN pasted in, and the position kept for the next time.
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=... tools/koreader/run_headless.sh tools/koreader/check_editor.lua
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))
local out_dir = assert(os.getenv("OUTPUT_DIR"))
require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path
local Device = require("device")
local Screen = Device.screen
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
UIManager:init()
local Chess = require("ink_knight/chess")
local Home = require("ink_knight/ui/home")

local failures = 0
local function check(condition, message)
    if not condition then
        failures = failures + 1
        print("FAILED: " .. message)
    end
end

local queue = {}
UIManager.scheduleIn = function(_, _, callback)
    queue[#queue + 1] = callback
end
local function run_queue(rounds)
    for _ = 1, rounds or 1 do
        local pending = queue
        queue = {}
        for _, callback in ipairs(pending) do
            callback()
        end
    end
end

local home = Home:new{ version = "0" }
UIManager:show(home)
local s = home.strings
for _, key in ipairs({ "editor_fen", "offline_game", "two_player_game" }) do
    home.settings:delSetting(key)
end

local function row_of(page, text)
    for _, line in ipairs(page.lines) do
        if line.text == text then
            return line
        end
    end
end
local function tile_of(page, text)
    for _, line in ipairs(page.lines) do
        for _, item in ipairs(line.items or {}) do
            if item.text == text or item.text == text:gsub("^%l", string.upper) then
                return item
            end
        end
    end
end
local function board()
    for _, widget in ipairs(UIManager._window_stack or {}) do
        if widget.widget and widget.widget.on_square then
            return widget.widget
        end
    end
end
local function sq(name) return Chess.square_from_name(name) end
local function pieces(position)
    local count = 0
    for _ in pairs(position.board) do
        count = count + 1
    end
    return count
end

-- The editor from the offline menu, on the starting position.
home:offline_menu()
local offline = home.pages[#home.pages]
row_of(offline, s.editor).callback()
local screen = board()
check(screen and screen.state.position.board[sq("e1")] == "K", "the editor should open on the starting position")
check(screen.coordinates == true, "the editor shows the coordinates")

-- Empty board, then a white king from the palette.
screen.on_button("options")
row_of(home.pages[#home.pages], s.editor_clear).callback()
check(next(screen.state.position.board) == nil, "the board should be empty")
screen.on_button("piece")
local palette = home.pages[#home.pages]
tile_of(palette, s.editor_pieces.K).callback()
UIManager:close(palette)
check(screen.state.top.name == string.format(s.editor_placing, s.editor_pieces.K), "the tool should be the white king")
screen.on_square(sq("e1"))
screen.on_button("done")
check(screen.state.status == s.editor_problems.kings, "one king only cannot be played: " .. tostring(screen.state.status))
screen.on_button("piece")
palette = home.pages[#home.pages]
tile_of(palette, s.editor_pieces.k).callback()
UIManager:close(palette)
screen.on_square(sq("e8"))
screen.on_button("piece")
palette = home.pages[#home.pages]
tile_of(palette, s.editor_pieces.R).callback()
UIManager:close(palette)
screen.on_square(sq("h1"))
screen.on_square(sq("a2"))
screen.on_square(sq("a2"))
check(screen.state.position.board[sq("a2")] == nil, "the same piece again should take it away")
check(screen.state.status == "", "a change clears the message")
screen:paintTo(Screen.bb, 0, 0)
Screen.bb:writePNG(out_dir .. "/editor.png")

-- Castling: the king and the rook are in place, so the option is there.
screen.on_button("options")
local options = home.pages[#home.pages]
local castle = row_of(options, s.editor_castling_names.K)
check(castle ~= nil and castle.on == false, "white can castle king side, off at first")
castle.callback()
check(screen.state.position.castling == "K", "the right should be on: " .. tostring(screen.state.position.castling))
UIManager:close(options)

-- Done: no analysis offline, and a game against the engine from here.
screen.on_button("done")
local play_page = home.pages[#home.pages]
check(row_of(play_page, s.analysis) == nil, "no analysis without the online part")
local level1
for _, line in ipairs(play_page.lines) do
    for _, item in ipairs(line.items or {}) do
        if item.text == "1" then
            level1 = item
        end
    end
end
level1.callback()
tile_of(home.pages[#home.pages], s.color_white).callback()
screen = board()
check(screen and screen.state.position.board[sq("h1")] == "R" and screen.state.position.board[sq("e8")] == "k", "the game should start from the position")
screen.on_square(sq("e1"))
screen.on_square(sq("g1"))
check(screen.state.position.board[sq("f1")] == "R", "castling should work from the position")
run_queue(80)
local saved = home.settings:readSetting("offline_game")
check(saved and saved.initial_fen == "4k3/8/8/8/8/8/8/4K2R w K - 0 1", "the game should be kept with its position: " .. tostring(saved and saved.initial_fen))
screen.on_button("undo")
check(pieces(screen.state.position) == 3 and screen.state.position.board[sq("e1")] == "K" and screen.state.position.board[sq("h1")] == "R",
    "undo should go back to the position set up, not the start of a game")
UIManager:close(screen)

-- Continued later from the offline menu.
local OfflineGame = require("ink_knight/ui/offline_game")
screen = OfflineGame.open(home, { resume = true }).screen
check(pieces(screen.state.position) == 3, "the game should come back from its position")
UIManager:close(screen)

-- A FEN pasted in, with black to move, for a game between two people.
local Editor = require("ink_knight/editor")
home.settings:saveSetting("editor_fen", "4k3/8/8/8/8/8/4P3/4K3 b - - 0 1")
local editor = require("ink_knight/ui/editor_screen").open(home)
screen = editor.screen
check(screen.state.bottom.name == s.editor_black_to_move, "the kept position should come back, black to move")
screen.on_button("done")
play_page = home.pages[#home.pages]
row_of(play_page, s.two_players).callback()
row_of(home.pages[#home.pages], s.clock_none).callback()
screen = board()
screen.on_square(sq("e8"))
screen.on_square(sq("d7"))
check(screen.state.position.board[sq("d7")] == "k", "black should move first")
screen.on_button("undo")
check(screen.state.position.board[sq("e8")] == "k" and pieces(screen.state.position) == 3, "undo should take back black's move, back to the position")
UIManager:close(screen)
check(Editor.read_fen("x") == nil, "a broken FEN is refused")

UIManager:close(offline)
for _, key in ipairs({ "editor_fen", "offline_game", "two_player_game" }) do
    home.settings:delSetting(key)
end
if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("editor: everything as expected")
os.exit(0)
