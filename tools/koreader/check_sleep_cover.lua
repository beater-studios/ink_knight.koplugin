-- The cover of the sleep screen while Ink Knight is open: the offline game on the screen, the game of Lichess waiting for the reader's turn when no game is open, and the fixed image with neither; through the screensaver of KOReader, as the device does when it sleeps.
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=... tools/koreader/run_headless.sh tools/koreader/check_sleep_cover.lua
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))
local out_dir = assert(os.getenv("OUTPUT_DIR"))
require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
G_reader_settings:saveSetting("screensaver_type", "cover")
G_reader_settings:saveSetting("language", "en")
package.path = plugin_dir .. "/?.lua;" .. package.path
local Device = require("device")
local Screen = Device.screen
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
UIManager:init()
require("apps/filemanager/filemanager").instance = {}
local Screensaver = require("ui/screensaver")

local failures = 0
local function check(condition, message)
    if not condition then
        failures = failures + 1
        print("FAILED: " .. message)
    end
end

-- As main.lua installs it.
require("ink_knight/screensaver").install(plugin_dir, "ink_knight", function()
    return require("ink_knight/ui/sleep_cover").draw()
end)
local Home = require("ink_knight/ui/home")
local OfflineGame = require("ink_knight/ui/offline_game")
local SleepCover = require("ink_knight/ui/sleep_cover")

-- What KOReader would show, as the device goes to sleep: the drawn cover, or the file of the fixed one.
local function sleep_cover(name)
    Screensaver.image, Screensaver.image_file = nil, nil
    Screensaver:setup()
    local image, file = Screensaver.image, Screensaver.image_file
    if image then
        image:writePNG(out_dir .. "/" .. name .. ".png")
    end
    return image, file
end

local home = Home:new{ version = "0", plugin_dir = plugin_dir }
UIManager:show(home)
local s = home.strings
check(SleepCover.app == home, "the first page should give the cover the plugin")

-- No game: the fixed image.
local image, file = sleep_cover("sleep_none")
check(image == nil and file and file:find("assets/screensaver.png", 1, true), "with no game the fixed image should stay: " .. tostring(file))

-- A game of Lichess waiting for the reader's turn, with no game open.
home.games = { { gameId = "abcd1234", fen = "rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2", color = "black", isMyTurn = true,
    speed = "correspondence", perf = "correspondence", opponent = { username = "Rival" }, secondsLeft = 86400 } }
local info = SleepCover.game(home)
check(info and info.title == string.format(s.sleep_your_turn, "Rival") and info.flipped == true, "the game waiting should be the one shown, from black's side: " .. tostring(info and info.title))
image = sleep_cover("sleep_waiting")
check(image ~= nil and image:getWidth() == Screen:getWidth(), "the waiting game should be drawn as the cover")

-- An offline game open: it comes before the one waiting.
local game = OfflineGame.open(home, { level = 1, color_choice = "white" })
info = SleepCover.game(home)
check(info and info.position == game.position and info.title:find(game:level_name(), 1, true), "the open game should be the one shown: " .. tostring(info and info.title))
image = sleep_cover("sleep_open")
check(image ~= nil, "the open game should be drawn as the cover")
UIManager:close(game.screen)
info = SleepCover.game(home)
check(info and info.title == string.format(s.sleep_your_turn, "Rival"), "closing the game should leave the cover to the waiting one")

-- A drawing that fails leaves the fixed image.
local real_draw = SleepCover.draw
SleepCover.draw = function() error("broken") end
image, file = sleep_cover("sleep_broken")
check(image == nil and file and file:find("assets/screensaver.png", 1, true), "a cover that fails to draw should leave the fixed image")
SleepCover.draw = real_draw

UIManager:close(home)
check(SleepCover.app == nil, "closing the plugin should forget it")
print(failures == 0 and "sleep cover: everything as expected" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
