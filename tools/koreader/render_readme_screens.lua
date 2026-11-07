-- Renders the README images with invented players, with no network and no account.
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))
local out_dir = assert(os.getenv("OUTPUT_DIR"))
require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path
local Device = require("device")
local Screen = Device.screen
-- The same time and battery on every picture, whatever the machine.
Device.hasBattery = function() return true end
Device.getPowerDevice = function() return { getCapacity = function() return 87 end } end
local real_time = os.time
os.time = function(date) return real_time(date or { year = 2026, month = 11, day = 6, hour = 14, min = 32 }) end
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
UIManager:init()
local BoardScreen = require("ink_knight/ui/board_screen")
local Home = require("ink_knight/ui/home")
local Page = require("ink_knight/ui/page")
local Chess = require("ink_knight/chess")
local I18n = require("ink_knight/i18n")

local function save(widget, path)
    widget:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(path)
end

for _, language in ipairs({ "en", "pt" }) do
    local s = I18n[language]
    local folder = language == "en" and out_dir or (out_dir .. "/" .. language)
    os.execute('mkdir -p "' .. folder .. '"')
    local position, last = Chess.from_moves(nil, "e2e4 e7e5 g1f3 b8c6 f1b5 a7a6 b5a4 g8f6 e1g1 f8e7")
    local game = BoardScreen:new{ state = {
        position = position, last_move = last,
        selected = Chess.square_from_name("f1"),
        targets = Chess.targets_from(position, Chess.square_from_name("f1")),
        top = { name = "Helena Vargas (1612)", clock = "8:42" },
        bottom = { name = "Otávio Brandão (1584)", clock = "9:15", active = true },
        status = s.status_your_turn,
        buttons = { { id = "back", label = s.back }, { id = "draw", label = s.offer_draw }, { id = "resign", label = s.resign } },
    } }
    save(game, folder .. "/game.png")
    local puzzle_position, puzzle_last = Chess.from_moves(nil, "e2e4 e7e5 f1c4 b8c6 d1h5 g8f6")
    local puzzle = BoardScreen:new{ state = {
        position = puzzle_position, last_move = puzzle_last,
        top = { name = string.format(s.puzzle_rating, 1240) },
        bottom = { name = s.plays_white },
        status = s.puzzle_find,
        buttons = { { id = "back", label = s.back }, { id = "show", label = s.puzzle_show } },
    } }
    save(puzzle, folder .. "/puzzle.png")
    local list = Home:new{ version = "0" }
    list.strings = s
    list.token, list.my_id, list.my_name, list.updated_at = "invented", "me", "invented_player", "14:30"
    list.games = {
        { gameId = "a", isMyTurn = true, secondsLeft = 180000, opponent = { username = "Helena Vargas" } },
        { gameId = "b", isMyTurn = true, secondsLeft = 32400, opponent = { username = "Rui Tavares" } },
        { gameId = "c", isMyTurn = false, secondsLeft = 259200, opponent = { username = "Marta Lins" } },
    }
    save(Page:new{ title = s.games_title, subtitle = list.my_name, rows = list:hub_rows() }, folder .. "/games.png")
    list:reload(true)
    save(list, folder .. "/start.png")
end
os.exit(0)
