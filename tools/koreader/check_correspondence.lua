-- Goes through correspondence with no network on the real screens, with invented answers: the games kept from the
-- online list, a move made offline and taken back, the move sent when the online part opens again, a move dropped
-- because the game changed, a move that had reached Lichess with its answer lost, a move made with the online part
-- open, which goes out at once, and the games forgotten with the token.
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=... tools/koreader/run_headless.sh tools/koreader/check_correspondence.lua
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
local CorrespondenceScreen = require("ink_knight/ui/correspondence_screen")
local Home = require("ink_knight/ui/home")
local Net = require("ink_knight/net")

local failures = 0
local function check(condition, message)
    if not condition then
        failures = failures + 1
        print("FAILED: " .. message)
    end
end

local function write(path, text)
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
end

local ca_file = os.tmpname()
write(ca_file, "certificates")
local answers, asked = {}, {}
local real_new = Net.new
Net.new = function(opts)
    local next_pid = 0
    opts.ca_file = ca_file
    opts.done = function() return true end
    opts.kill = function() end
    opts.spawn = function(spec)
        local path = spec.url:gsub("^https://[^/]+", ""):gsub("%?.*$", "")
        if path ~= "/api/stream/event" then
            asked[#asked + 1] = path
        end
        local answer = answers[path] or answers.default
        write(spec.code_path, tostring(answer[1]))
        write(spec.out_path, answer[2] or "")
        next_pid = next_pid + 1
        return next_pid
    end
    return real_new(opts)
end

local queue = {}
UIManager.scheduleIn = function(_, _, callback)
    queue[#queue + 1] = callback
end
local home
local function stands_for(callback, window, fn)
    local state = window and window._sleep
    return state ~= nil and state.tasks[fn] == callback
end
local function run_all()
    for _ = 1, 40 do
        if home.net then
            home.net:tick()
        end
        while #queue > 0 do
            local callback = table.remove(queue, 1)
            if not stands_for(callback, home, home.minute_callback) and not stands_for(callback, home, home.tick_callback) then
                callback()
            end
        end
    end
end

local AFTER_E4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
local function playing(games)
    return { 200, '{"nbMyTurn":1,"nowPlaying":[' .. table.concat(games, ",") .. "]}" }
end
local function correspondence_game(fen, my_turn)
    return string.format('{"gameId":"corr0001","fullId":"corr0001wxyz","color":"black","fen":"%s","lastMove":"e2e4",'
        .. '"isMyTurn":%s,"secondsLeft":172800,"speed":"correspondence","variant":{"key":"standard","name":"Standard"},'
        .. '"opponent":{"id":"helena","username":"Helena","rating":1600},"hasMoved":true,"rated":false}', fen, tostring(my_turn))
end
local RAPID = '{"gameId":"rapid001","fullId":"rapid001wxyz","color":"white","fen":"' .. Chess.START_FEN .. '","lastMove":"",'
    .. '"isMyTurn":true,"secondsLeft":600,"speed":"rapid","variant":{"key":"standard","name":"Standard"},'
    .. '"opponent":{"id":"bruno","username":"Bruno","rating":1500},"hasMoved":false,"rated":false}'

answers = {
    ["/api/account"] = { 200, '{"id":"reader","username":"Reader"}' },
    ["/api/account/playing"] = playing({ correspondence_game(AFTER_E4, true), RAPID }),
    ["/api/board/game/corr0001/move/e7e5"] = { 200, '{"ok":true}' },
    default = { 200, "{}" },
}
home = Home:new{ version = "0" }
UIManager:show(home)
local notices = {}
local real_info = home.info
home.info = function(self, text, ...)
    notices[#notices + 1] = text
    return real_info(self, text, ...)
end
local s = home.strings
home.settings:delSetting("correspondence")
local token = "lip_" .. string.rep("0", 20)
assert(home.token_store:save(token))
home.token = token

local function row_of(page, text)
    for _, line in ipairs(page.lines) do
        if line.text == text then
            return line
        end
    end
end
local function close_boards()
    for _, widget in ipairs(UIManager._window_stack or {}) do
        if widget.widget and widget.widget.on_square then
            UIManager:close(widget.widget)
        end
    end
end

-- Online: the list keeps the correspondence game and leaves the rapid one out.
home:open_hub()
run_all()
local kept = home:correspondence()
check(kept.account == "reader" and #kept.games == 1 and kept.games[1].id == "corr0001", "the correspondence game should be kept")
UIManager:close(home.hub)
check(home.net == nil, "leaving the online part should stop the network")

-- Offline: the game is in the offline menu, a move waits and can be taken back.
asked = {}
home:offline_menu()
local menu = home.pages[#home.pages]
local row = row_of(menu, "Helena")
check(row and row.detail == s.your_turn, "the offline menu should list the game on the reader's turn")
local screen = CorrespondenceScreen.open(home, "corr0001")
screen:on_square(Chess.square_from_name("e7"))
screen:on_square(Chess.square_from_name("e5"))
local game = home:correspondence().games[1]
check(game.pending and game.pending.uci == "e7e5", "the move should wait on the device")
check(screen.screen.state.status == string.format(s.correspondence_status_saved, "e5"), "the bar should say the move is saved: "
    .. tostring(screen.screen.state.status))
check(notices[#notices] == s.correspondence_move_kept, "the reader should be told when the move goes out")
screen.screen:paintTo(Screen.bb, 0, 0)
Screen.bb:writePNG(out_dir .. "/correspondence_saved.png")
screen:on_square(Chess.square_from_name("d7"))
check(screen.selected == nil, "no second move while one waits")
screen:on_button("undo")
check(home:correspondence().games[1].pending == nil, "undo should take the move back")
screen:on_square(Chess.square_from_name("e7"))
screen:on_square(Chess.square_from_name("e5"))
UIManager:close(screen.screen)
check(row_of(menu, "Helena").detail == s.correspondence_move_saved, "the offline menu should show the move saved")
check(#asked == 0, "nothing should be asked without a connection")
UIManager:close(menu)

-- Online again: the move goes out, and the reader is told.
asked = {}
notices = {}
home:open_hub()
run_all()
local sent = false
for _, path in ipairs(asked) do
    sent = sent or path == "/api/board/game/corr0001/move/e7e5"
end
check(sent, "the saved move should be sent: " .. table.concat(asked, " "))
check(home:correspondence().games[1].pending == nil, "a sent move should no longer wait")
check(table.concat(notices, " "):find(s.correspondence_sent_one, 1, true), "the reader should be told the move was sent")
UIManager:close(home.hub)

-- A move made offline in a game that changed on Lichess meanwhile is not sent.
screen = CorrespondenceScreen.open(home, "corr0001")
screen:on_square(Chess.square_from_name("e7"))
screen:on_square(Chess.square_from_name("e5"))
UIManager:close(screen.screen)
answers["/api/account/playing"] = playing({ correspondence_game(Chess.START_FEN:gsub(" w ", " b "), true) })
asked = {}
notices = {}
home:open_hub()
run_all()
for _, path in ipairs(asked) do
    check(not path:find("/move/", 1, true), "a move for a changed game should not be sent: " .. path)
end
check(home:correspondence().games[1].pending == nil, "the move for a changed game should be dropped")
check(table.concat(notices, " "):find(string.format(s.correspondence_not_sent, "Helena"), 1, true), "the reader should be told the move was not sent")

-- A move whose answer was lost: Lichess already shows it played, so it counts as sent and nothing is asked again.
UIManager:close(home.hub)
answers["/api/account/playing"] = playing({ correspondence_game(AFTER_E4, true) })
home:open_hub()
run_all()
UIManager:close(home.hub)
screen = CorrespondenceScreen.open(home, "corr0001")
screen:on_square(Chess.square_from_name("e7"))
screen:on_square(Chess.square_from_name("e5"))
UIManager:close(screen.screen)
local AFTER_E5 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
answers["/api/account/playing"] = playing({ correspondence_game(AFTER_E5, false) })
asked = {}
notices = {}
home:open_hub()
run_all()
for _, path in ipairs(asked) do
    check(not path:find("/move/", 1, true), "a move already played should not be sent again: " .. path)
end
check(home:correspondence().games[1].pending == nil, "a move already played should no longer wait")
check(table.concat(notices, " "):find(s.correspondence_sent_one, 1, true), "a move already played should count as sent")

-- With the online part open, a move made on the kept board goes out at once.
answers["/api/account/playing"] = playing({ correspondence_game(AFTER_E4, true) })
home:reload_games()
run_all()
asked = {}
notices = {}
screen = CorrespondenceScreen.open(home, "corr0001")
screen:on_square(Chess.square_from_name("e7"))
screen:on_square(Chess.square_from_name("e5"))
run_all()
sent = false
for _, path in ipairs(asked) do
    sent = sent or path == "/api/board/game/corr0001/move/e7e5"
end
check(sent, "online, the move should go out at once: " .. table.concat(asked, " "))
check(not table.concat(notices, " "):find(s.correspondence_move_kept, 1, true), "online, the reader should not be told to wait")
check(table.concat(notices, " "):find(s.correspondence_sent_one, 1, true), "online, the reader should be told the move was sent")
check(screen.screen.state.status ~= string.format(s.correspondence_status_saved, "e5"), "the board should no longer say the move waits")
UIManager:close(screen.screen)

-- Disconnecting forgets the games of that account.
close_boards()
home:forget_token()
check(#home:correspondence().games == 0, "the kept games should go with the token")

os.remove(ca_file)
if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("correspondence: everything as expected")
os.exit(0)
