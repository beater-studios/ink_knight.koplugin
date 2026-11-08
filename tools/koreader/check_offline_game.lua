-- Plays games against the offline engine on the real screens: choosing a color, taking back and asking for a hint.
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=... tools/koreader/run_headless.sh tools/koreader/check_offline_game.lua
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
local I18n = require("ink_knight/i18n")
local OfflineGame = require("ink_knight/ui/offline_game")

local s = I18n.en
local failures = 0
local function check(condition, message)
    if not condition then
        failures = failures + 1
        print("FAILED: " .. message)
    end
end

-- The engine works through scheduled slices. Here they run in order, as fast as they can.
local queue = {}
UIManager.scheduleIn = function(_, _, callback)
    queue[#queue + 1] = callback
end
-- The clock of the status strip schedules itself every minute, so it is left out.
local home
local function run_scheduled()
    local guard = 0
    while #queue > 0 do
        guard = guard + 1
        assert(guard < 100000, "the scheduled work never ended")
        local callback = table.remove(queue, 1)
        if callback ~= home.minute_callback then
            callback()
        end
    end
end

local function buttons(game)
    local ids = {}
    for _, button in ipairs(game.screen.state.buttons) do
        ids[#ids + 1] = button.id
    end
    return table.concat(ids, " ")
end

local function play(game, from, to)
    game:on_square(Chess.square_from_name(from))
    game:on_square(Chess.square_from_name(to))
end

local function count(moves)
    local total = 0
    for _ in moves:gmatch("%S+") do
        total = total + 1
    end
    return total
end

home = Home:new{ version = "0" }
UIManager:show(home)
home.settings:delSetting("offline_game")

-- White, chosen: nothing to take back at the start, then a move and the answer go back together.
do
    local game = OfflineGame.open(home, { level = 1, color_choice = "white" })
    check(game.my_color == "w", "choosing white should give white")
    check(buttons(game) == "back hint resign", "at the start: " .. buttons(game))
    play(game, "e2", "e4")
    check(game.thinking, "the engine should think after the move")
    run_scheduled()
    check(count(game.moves) == 2, "the engine should answer, moves: " .. game.moves)
    check(buttons(game) == "back undo hint resign", "after a move: " .. buttons(game))
    game:on_button("undo")
    check(game.moves == "", "undo should take back the move and the answer, moves: " .. game.moves)
    check(game.position.turn == "w", "it should be white's turn again")
    check(home.settings:readSetting("offline_game").moves == "", "the game should be saved after undo")

    -- Undo while the engine thinks: its move must not land afterwards.
    play(game, "d2", "d4")
    check(game.thinking, "the engine should be thinking")
    game:on_button("undo")
    check(not game.thinking, "undo should stop the engine")
    run_scheduled()
    check(game.moves == "", "the stopped search should not play, moves: " .. game.moves)

    -- A hint marks a move, and a tap on its square plays it.
    game:on_button("hint")
    check(game.hinting, "the hint should be searching")
    check(game.screen.state.status == s.hint_thinking, "the status should say a hint is coming")
    run_scheduled()
    check(game.selected and game.targets, "the hint should mark a piece and a square")
    check(game.hint_text and game.hint_text:find("Suggestion: ", 1, true), "the status should name the move: " .. tostring(game.hint_text))
    game.screen:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/offline_hint.png")
    local target
    for square in pairs(game.targets) do
        target = square
    end
    game:on_square(target)
    check(count(game.moves) == 1, "tapping the hinted square should play it, moves: " .. game.moves)
    check(game.hint_text == nil, "the suggestion should go once the move is played")
    run_scheduled()

    UIManager:close(game.screen)
end

-- Black, chosen: the engine starts, and undo never takes back its first move.
do
    local game = OfflineGame.open(home, { level = 1, color_choice = "black" })
    check(game.my_color == "b", "choosing black should give black")
    run_scheduled()
    check(count(game.moves) == 1, "the engine should open, moves: " .. game.moves)
    check(not buttons(game):find("undo", 1, true), "nothing of black to take back yet: " .. buttons(game))
    local legal = Chess.legal_moves(game.position)[1]
    play(game, Chess.square_name(legal.from), Chess.square_name(legal.to))
    run_scheduled()
    check(count(game.moves) == 3, "after black's move and the answer, moves: " .. game.moves)
    local first = game.moves:match("^%S+")
    game:on_button("undo")
    check(game.moves == first, "undo should keep the engine's first move, moves: " .. game.moves)
    check(game.color_choice == "black", "the choice should be kept")
    -- Playing again keeps the color chosen: the new game is black again, and the engine opens it.
    home.settings:delSetting("offline_game")
    game.resigned = true
    game:on_button("again")
    run_scheduled()
    local again = home.settings:readSetting("offline_game")
    check(again and again.my_color == "b" and again.color_choice == "black", "playing again should keep black")
    UIManager:close(UIManager:getTopmostVisibleWidget())
end

-- Saved games keep the choice, and a game lost by mate can be taken back.
do
    home.settings:saveSetting("offline_game", { level = 2, my_color = "w", color_choice = "white", moves = "f2f3 e7e5 g2g4 d8h4" })
    local game = OfflineGame.open(home, { resume = true })
    check(game.color_choice == "white", "a saved game should keep the choice")
    check(game.ending == "mate", "the saved game should be over by mate")
    check(buttons(game) == "back undo again", "after mate: " .. buttons(game))
    game:on_button("undo")
    check(game.moves == "f2f3 e7e5", "undo after mate should go back to white's last move, moves: " .. game.moves)
    check(game.ending == nil, "the game should go on after undo")
    UIManager:close(game.screen)
end

home.settings:delSetting("offline_game")
UIManager:close(home)
if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("offline game: everything as expected")
os.exit(0)
