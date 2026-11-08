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
local MoveList = require("ink_knight/ui/move_list")

-- A Ruy Lopez long enough to fill the list of moves.
local LONG_GAME = "e2e4 e7e5 g1f3 b8c6 f1b5 a7a6 b5a4 g8f6 e1g1 f8e7 f1e1 b7b5 a4b3 d7d6 c2c3 e8g8 h2h3 c6b8 d2d4 b8d7 "
    .. "b1d2 c8b7 b3c2 f8e8 d2f1 e7f8 f1g3 g7g6"

local function save(widget, path)
    widget:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(path)
end

for _, language in ipairs({ "en", "pt" }) do
    local s = I18n[language]
    local folder = language == "en" and out_dir or (out_dir .. "/" .. language)
    os.execute('mkdir -p "' .. folder .. '"')
    local position, last = Chess.from_moves(nil, "e2e4 e7e5 g1f3 b8c6 f1b5 a7a6 b5a4 g8f6 e1g1 f8e7")
    -- The game in progress shows one of the board styles, the others keep the plain board.
    BoardScreen.style, BoardScreen.piece_set, BoardScreen.coordinates = "newspaper", "merida", true
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
    UIManager:close(game)
    BoardScreen.style, BoardScreen.piece_set, BoardScreen.coordinates = "plain", "classic", false
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
    }
    -- One game, so the whole hub fits one sheet with the challenge buttons above it.
    list.challenges = { chal1 = { id = "chal1", challenger = { id = "nuno", name = "Nuno Prado" } } }
    list.sent = {
        sent1 = { id = "sent1", challenger = { id = "me" }, destUser = { id = "ines", name = "Inês Moura" } },
        sent2 = { id = "sent2", challenger = { id = "me" }, destUser = { id = "caio", name = "Caio Ramos" } },
    }
    save(Page:new{ title = s.games_title, subtitle = list.my_name, rows = list:hub_rows() }, folder .. "/games.png")
    list.challenges, list.sent = {}, {}
    list:reload(true)
    save(list, folder .. "/start.png")

    -- Choosing a board style, with a sample before each name.
    local holder = Page:new{ title = "", rows = {} }
    list:board_look_rows(holder)[1].callback()
    local styles = list.pages[#list.pages]
    save(styles, folder .. "/styles.png")
    UIManager:close(styles)

    -- The list of moves of a game under review, with the move shown marked.
    local sans = Chess.san_list(nil, LONG_GAME)
    save(Page:new{ title = s.move_list_title, rows = MoveList.rows(sans, 1, "w", { current = 15, on_pick = function() end }) }, folder .. "/moves.png")

    -- A hint against the offline engine: the piece and its square, and the move named below the board.
    local hint_position = Chess.from_moves(nil, "e2e4 e7e5 g1f3 b8c6")
    local bishop = Chess.square_from_name("f1")
    local hint = BoardScreen:new{ state = {
        position = hint_position, last_move = select(2, Chess.from_moves(nil, "e2e4 e7e5 g1f3 b8c6")),
        selected = bishop,
        targets = { [Chess.square_from_name("b5")] = Chess.targets_from(hint_position, bishop)[Chess.square_from_name("b5")] },
        top = { name = string.format(s.offline_level, 2) },
        bottom = { name = s.you },
        status = string.format(s.hint_status, "Bb5"),
        buttons = { { id = "back", label = s.back }, { id = "undo", label = s.undo }, { id = "hint", label = s.hint }, { id = "moves", label = s.moves }, { id = "resign", label = s.resign } },
    } }
    save(hint, folder .. "/hint.png")
    UIManager:close(hint)

    -- Two people on the same device.
    local two_position, two_last = Chess.from_moves(nil, "d2d4 d7d5 c2c4 e7e6 b1c3 g8f6 c1g5 f8e7")
    local two = BoardScreen:new{ state = {
        position = two_position, last_move = two_last,
        top = { name = s.color_black }, bottom = { name = s.color_white },
        status = s.local_turn_w,
        buttons = { { id = "back", label = s.back }, { id = "undo", label = s.undo }, { id = "moves", label = s.moves }, { id = "flip", label = s.flip_board }, { id = "resign", label = s.resign } },
    } }
    save(two, folder .. "/two_players.png")
    UIManager:close(two)
end
os.exit(0)
