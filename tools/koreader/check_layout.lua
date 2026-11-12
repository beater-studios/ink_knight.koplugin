-- The layout of Ink Knight in one screen size, run by tools/koreader/check_all_sizes.sh in four: every page and the
-- board fit the screen in the three languages, the texts of a fixed width fit at their size, the About page shows
-- the version of _meta.lua, a game without internet continues in a new screen, the e-ink updates come in the order
-- they should, and the Back key goes back. The network is invented, and the token page never listens.
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=<desktop KOReader> tools/koreader/run_headless.sh tools/koreader/check_layout.lua
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))
local out_dir = assert(os.getenv("OUTPUT_DIR"))
require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path
local Device = require("device")
local Screen = Device.screen
Device.hasBattery = function() return true end
Device.getPowerDevice = function() return { getCapacity = function() return 87 end } end
require("document/canvascontext"):init(Device)
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
UIManager:init()
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")

local BoardScreen = require("ink_knight/ui/board_screen")
local Chess = require("ink_knight/chess")
local Home = require("ink_knight/ui/home")
local LiveGame = require("ink_knight/ui/live_game")
local Net = require("ink_knight/net")
local OfflineGame = require("ink_knight/ui/offline_game")
local Page = require("ink_knight/ui/page")
local SavedState = require("ink_knight/saved_state")
local StatusStrip = require("ink_knight/ui/status_strip")

require("ink_knight/awake").install("ink_knight")
require("ink_knight/lan").install("ink_knight")
require("ink_knight/ui/token_screen").local_ip = "203.0.113.7"
local meta = dofile(plugin_dir .. "/_meta.lua")
local size = string.format("%dx%d", Screen:getWidth(), Screen:getHeight())

local problems = 0
local function problem(text)
    problems = problems + 1
    print("PROBLEM " .. size .. ": " .. text)
end

-- The invented Lichess, with names as long as the ones Lichess allows (20 letters).
local LONG_NAME = "Alessandra_Vasconcel"
local GAME = string.format('{"gameId":"layoutgm","fullId":"layoutgmxxxx","color":"white","isMyTurn":true,"secondsLeft":259200,'
    .. '"opponent":{"id":"%s","username":"%s","rating":2999},"speed":"correspondence"}', LONG_NAME:lower(), LONG_NAME)
local ANSWERS = {
    ["/api/account"] = string.format('{"id":"%s","username":"%s","perfs":{"rapid":{"rating":1500}}}', LONG_NAME:lower(), LONG_NAME),
    ["/api/account/playing"] = '{"nowPlaying":[' .. string.rep(GAME .. ",", 5) .. GAME .. ']}',
}
local real_new = Net.new
Net.new = function(opts)
    opts.ca_file = plugin_dir .. "/LICENSE"
    opts.spawn = function(spec)
        local path = spec.url:gsub("^https://[^/]+", ""):gsub("%?.*$", "")
        local out = io.open(spec.out_path, "wb")
        out:write(ANSWERS[path] or "{}")
        out:close()
        local code = io.open(spec.code_path, "wb")
        code:write("200")
        code:close()
        return 1
    end
    opts.done = function() return true end
    opts.kill = function() end
    return real_new(opts)
end

-- Texts drawn in a fixed width: measured at their size without the cut, they must fit.
local where = "?"
local function wrap_paint_text(class)
    local paint_text = class.paint_text
    class.paint_text = function(self, bb, text, name, font_size, x, y, w, ...)
        if text and text ~= "" then
            local Font = require("ui/font")
            local widget = TextWidget:new{ text = text, face = Font:getFace(name, font_size * self.scale * 1000 / Screen:scaleBySize(1000)) }
            local natural = widget:getSize().w
            widget:free()
            if natural > w then
                problem(string.format("%s: \"%s\" needs %d px and has %d", where, text, natural, w))
            end
        end
        return paint_text(self, bb, text, name, font_size, x, y, w, ...)
    end
end
wrap_paint_text(Page)
wrap_paint_text(BoardScreen)

local function shot(name)
    UIManager:forceRePaint()
    Screen.bb:writePNG(out_dir .. "/" .. name .. ".png")
end

-- Every sheet of a page fits between its header and the status strip, and each one is drawn.
local function check_page(page, name)
    where = name
    local room = Screen:getHeight() - StatusStrip.height() - page:content_top()
    for index, sheet in ipairs(page.sheets) do
        local used = 0
        for _, line in ipairs(sheet) do
            used = used + page.heights_of[line]
        end
        local limit = #page.sheets > 1 and room - page:px(58) or room
        if used > limit then
            problem(string.format("%s, sheet %d: %d px of rows in %d", name, index, used, limit))
        end
        page.sheet = index
        UIManager:setDirty(page, "ui")
        shot(name:gsub("[^%w]+", "_") .. "_" .. index)
    end
    page.sheet = 1
end

local function top_page()
    local stack = UIManager._window_stack
    return stack[#stack].widget
end

local function close_all()
    local stack = UIManager._window_stack
    while #stack > 0 do
        UIManager:close(stack[#stack].widget)
    end
end

-- The buttons of the board wrap their text: it must still fit the height of the button.
local function check_board(board, name)
    where = name
    shot(name:gsub("[^%w]+", "_"))
    local bottom = board.buttons_rect.y + board.buttons_rect.h
    if bottom > Screen:getHeight() - StatusStrip.height() then
        problem(name .. ": the buttons go past the status strip")
    end
    local Font = require("ui/font")
    for _, rect in ipairs(board:button_rects()) do
        local box = TextBoxWidget:new{ text = rect.label, face = Font:getFace("noto/NotoSans-Bold.ttf", 17 * board.scale * 1000 / Screen:scaleBySize(1000)), width = rect.w - board:px(8) }
        local h = box:getSize().h
        box:free()
        if h > rect.h then
            problem(string.format("%s: the button \"%s\" needs %d px of height and has %d", name, rect.label, h, rect.h))
        end
    end
end

local settings_path = DataStorage:getSettingsDir() .. "/ink_knight.lua"
local function new_home(language)
    G_reader_settings:saveSetting("language", language)
    local home = Home:new{ plugin_dir = plugin_dir, version = meta.version }
    UIManager:show(home)
    UIManager:forceRePaint()
    return home
end

local function connect(home)
    where = "online, connecting"
    local token = "lip_" .. string.rep("0", 20)
    home.token_store = { load = function() return token, true end, save = function() return true, true end, clear = function() end }
    home.token = token
    home:open_hub()
    for _ = 1, 10 do
        home.net:tick()
    end
    UIManager:forceRePaint()
end

-- Every screen in every language.
for _, language in ipairs({ "en", "pt", "es" }) do
    close_all()
    SavedState.remove_file(settings_path)
    local home = new_home(language)
    check_page(home, language .. " first page")
    for _, open in ipairs({ "offline_menu", "pack_menu", "show_about", "connect_menu" }) do
        home[open](home)
        check_page(top_page(), language .. " " .. open)
        UIManager:close(top_page())
    end
    -- Correspondence kept offline, with the longest names, one game with a move waiting.
    local Correspondence = require("ink_knight/correspondence")
    local kept = {}
    for index, fen in ipairs({ "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1", Chess.START_FEN }) do
        kept[index] = Correspondence.from_playing({ gameId = "corr000" .. index, color = "black", fen = fen, speed = "correspondence",
            secondsLeft = 1209600, opponent = { username = LONG_NAME } }, os.time() - 90000)
    end
    Correspondence.play(kept[1], Chess.parse_uci(Chess.parse_fen(kept[1].fen), "e7e5"))
    home:save_correspondence({ account = LONG_NAME:lower(), name = LONG_NAME, games = kept })
    home:offline_menu()
    check_page(top_page(), language .. " offline menu with correspondence")
    local corr = require("ink_knight/ui/correspondence_screen").open(home, "corr0001")
    check_board(corr.screen, language .. " correspondence offline")
    UIManager:close(corr.screen)
    UIManager:close(top_page())
    home.settings:delSetting("correspondence")
    connect(home)
    check_page(home.hub, language .. " online")
    for _, open in ipairs({ "new_game_menu", "seek_menu", "seek_days_menu", "computer_menu", "puzzles_menu", "settings_menu", "all_games_menu" }) do
        home[open](home)
        check_page(top_page(), language .. " " .. open)
        UIManager:close(top_page())
    end

    -- The board with the longest bar of buttons a live game has, and a name as long as Lichess allows.
    local live = LiveGame.open(home, "layoutgm")
    live.game:on_event({ type = "gameFull", speed = "rapid", clock = { initial = 600000, increment = 0 },
        white = { id = LONG_NAME:lower(), name = LONG_NAME, rating = 2999 }, black = { id = "other", name = LONG_NAME, rating = 2999 },
        state = { moves = "e2e4 e7e5 g1f3", wtime = 3599000, btime = 3599000, status = "started" } }, os.time())
    live:render()
    check_board(live.screen, language .. " live game")
    -- The name of the opening only after the game, as Lichess does for its players.
    live:on_button("moves")
    if top_page().lines[1].kind == "text" then
        problem(language .. " live game: the list of moves names the opening during the game")
    end
    UIManager:close(top_page())
    live.game:on_event({ type = "gameState", moves = "e2e4 e7e5 g1f3", wtime = 3599000, btime = 3599000,
        status = "resign", winner = "white" }, os.time())
    live:on_button("moves")
    if top_page().lines[1].text ~= "King's Knight Opening" then
        problem(language .. " live game: the list of moves should name the opening after the game, got "
            .. tostring(top_page().lines[1].text))
    end
    check_page(top_page(), language .. " moves of a finished game")
    UIManager:close(top_page())
    UIManager:close(live.screen)
    local offline = OfflineGame.open(home, { level = 4, color_choice = "black" })
    check_board(offline.screen, language .. " offline game")
    UIManager:close(offline.screen)
    UIManager:close(home)
end

-- The About page shows the version of _meta.lua.
close_all()
SavedState.remove_file(settings_path)
local home = new_home("en")
home:show_about()
local found = false
for _, line in ipairs(top_page().lines) do
    found = found or (line.detail or ""):find(meta.version, 1, true) ~= nil
end
if not found then
    problem("the About page does not show the version " .. meta.version)
end
UIManager:close(top_page())

-- A game without internet continues in a new screen, with the same moves.
local game = OfflineGame.open(home, { two_players = true })
for _, move in ipairs({ { "e2", "e4" }, { "c7", "c5" } }) do
    game:on_square(Chess.square_from_name(move[1]))
    game:on_square(Chess.square_from_name(move[2]))
end
local moves = game.moves
UIManager:close(game.screen)
UIManager:close(home)
local reopened = new_home("en")
local resumed = reopened:saved_game("two_player_game") and OfflineGame.open(reopened, { resume = true, two_players = true })
if not resumed or resumed.moves ~= moves or moves ~= "e2e4 c7c5" then
    problem("the game between two people did not continue: " .. tostring(resumed and resumed.moves))
end
if resumed then
    UIManager:close(resumed.screen)
end

-- The e-ink updates: the plugin opens with a flash, the pages count together and flash after eight updates
-- without one, the board opens with a flash and a move only touches its squares, and closing the plugin flashes.
close_all()
local real_set_dirty = UIManager.setDirty
local log = {}
UIManager.setDirty = function(_, _, refresh)
    if type(refresh) == "function" then
        refresh = (refresh())
    end
    log[#log + 1] = refresh
end
local first = new_home("en")
for _ = 1, 4 do
    first:offline_menu()
    UIManager:close(top_page())
end
first:offline_menu()
local pages = table.concat(log, ",")
if pages ~= "full,ui,ui,ui,ui,ui,ui,ui,ui,full" then
    problem("updates of the pages: " .. pages)
end
UIManager:close(top_page())
log = {}
local board_game = OfflineGame.open(first, { two_players = true })
board_game:on_square(Chess.square_from_name("e2"))
board_game:on_square(Chess.square_from_name("e4"))
-- Showing the board and drawing its first state both ask for a flash, which KOReader joins into one.
local board = table.concat(log, ",")
local after_opening = board:gsub("^full,", ""):gsub("^full,", "")
if not board:match("^full,") or not after_opening:match("^ui") or after_opening:find("full", 1, true) then
    problem("updates of the board: " .. board)
end
UIManager:close(board_game.screen)
log = {}
UIManager:close(first)
if log[#log] ~= "full" then
    problem("closing the plugin should flash, got " .. table.concat(log, ","))
end
UIManager.setDirty = real_set_dirty

-- The Back key goes back one step: a page closes, a live game with a clock asks first, and KOReader's Close before
-- powering off leaves every window as it is.
close_all()
local back_home = new_home("en")
back_home:offline_menu()
local page = top_page()
page:handleEvent(Event:new("Back"))
if UIManager:isWidgetShown(page) then
    problem("Back did not close a page")
end
back_home:show_about()
page = top_page()
page:handleEvent(Event:new("Close", { keep_screensaver = true }))
if not UIManager:isWidgetShown(page) then
    problem("Close before powering off closed a page")
end
UIManager:close(page)
connect(back_home)
local clock_game = LiveGame.open(back_home, "layoutgm")
clock_game.game:on_event({ type = "gameFull", speed = "rapid", clock = { initial = 600000, increment = 0 },
    white = { id = LONG_NAME:lower(), name = LONG_NAME }, black = { id = "other", name = "Other" },
    state = { moves = "e2e4 e7e5", wtime = 590000, btime = 595000, status = "started" } }, os.time())
clock_game.screen:handleEvent(Event:new("Back"))
if not UIManager:isWidgetShown(clock_game.screen) or top_page() == clock_game.screen then
    problem("Back in a game with a clock should ask before leaving")
end
UIManager:close(top_page())
UIManager:close(clock_game.screen)
local hub = back_home.hub
hub:handleEvent(Event:new("Back"))
if UIManager:isWidgetShown(hub) then
    problem("Back did not leave the online part")
end
back_home:handleEvent(Event:new("Back"))
if UIManager:isWidgetShown(back_home) then
    problem("Back on the first page did not close the plugin")
end
close_all()

print(string.format("layout %s: %s", size, problems == 0 and "ok" or (problems .. " problem(s)")))
os.exit(problems == 0 and 0 or 1)
