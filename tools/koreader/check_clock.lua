-- Goes through the clocks on the real screens: a game between two people with a clock (it starts after white's
-- first move, the increment, pausing, the game kept and continued with its time, and the flag), and the chess clock
-- for a physical board (the first tap, turns, pausing, the device sleeping, leaving and restarting, and the flag).
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=... tools/koreader/run_headless.sh tools/koreader/check_clock.lua
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
local function run_queue()
    local pending = queue
    queue = {}
    for _, callback in ipairs(pending) do
        callback()
    end
end

-- The clocks read the time from socket.gettime, here ahead of the real one by offset.
local socket = require("socket")
local real_gettime = socket.gettime
local offset = 0
socket.gettime = function() return real_gettime() + offset end

require("ink_knight/awake").install("ink_knight")
local home = Home:new{ version = "0" }
UIManager:show(home)
local s = home.strings
home.settings:delSetting("two_player_game")
home.settings:delSetting("clock_preset")

local function row_of(page, text)
    for _, line in ipairs(page.lines) do
        if line.text == text then
            return line
        end
    end
end
local function top_window()
    local stack = UIManager._window_stack
    return stack[#stack] and stack[#stack].widget
end
local function board()
    for _, widget in ipairs(UIManager._window_stack or {}) do
        if widget.widget and widget.widget.on_square then
            return widget.widget
        end
    end
end
local function ids(state)
    local list = {}
    for _, button in ipairs(state.buttons or {}) do
        list[#list + 1] = button.id
    end
    return table.concat(list, " ")
end
local function play(screen, from, to)
    screen.on_square(Chess.square_from_name(from))
    screen.on_square(Chess.square_from_name(to))
end

-- A game between two people with 5+3, from the offline menu.
home:offline_menu()
local offline = home.pages[#home.pages]
row_of(offline, s.two_players).callback()
local choice = home.pages[#home.pages]
check(row_of(choice, s.clock_none) and row_of(choice, s.clock_none).value == "✓", "with no choice yet, no clock is marked")
row_of(choice, "5+3").callback()
local screen = board()
check(screen and screen.state.bottom.clock == "5:00" and screen.state.top.clock == "5:00", "both clocks should show 5:00")
check(not screen.state.bottom.active and not screen.state.top.active, "no clock runs before the first move")
offset = offset + 30
play(screen, "e2", "e4")
check(screen.state.bottom.clock == "5:00", "white's first move costs no time: " .. tostring(screen.state.bottom.clock))
check(screen.state.top.active, "black's clock should run after white's first move")
offset = offset + 10
run_queue()
check(screen.state.top.clock == "4:50", "black's clock should run down: " .. tostring(screen.state.top.clock))
play(screen, "e7", "e5")
check(screen.state.top.clock == "4:53", "black should get the increment: " .. tostring(screen.state.top.clock))
check(screen.state.bottom.active, "white's clock should run after black's move")
screen:paintTo(Screen.bb, 0, 0)
Screen.bb:writePNG(out_dir .. "/two_players_clock.png")

-- Undo takes the increment of the move back, and the clock goes to the side to move again.
screen.on_button("undo")
check(screen.state.top.clock == "4:50" and screen.state.top.active, "undo should give black its turn without the increment: " .. tostring(screen.state.top.clock))
play(screen, "e7", "e5")

-- Pausing stops the time and the moves.
check(ids(screen.state):find("clock_pause", 1, true), "a running clock can be paused: " .. ids(screen.state))
screen.on_button("clock_pause")
offset = offset + 100
run_queue()
check(screen.state.bottom.clock == "5:00" and screen.state.status == s.clock_paused, "a paused clock should not run")
play(screen, "g1", "f3")
check(screen.state.position.board[Chess.square_from_name("g1")] ~= nil, "no move while the clock is paused")
-- A pause is kept with the game: continuing it later does not start the clock.
offset = offset + 3
UIManager:close(screen)
local OfflineGame = require("ink_knight/ui/offline_game")
screen = OfflineGame.open(home, { resume = true, two_players = true }).screen
offset = offset + 50
run_queue()
check(screen.state.status == s.clock_paused and screen.state.bottom.clock == "5:00", "a paused game should stay paused when continued")
screen.on_button("clock_resume")

-- Closing keeps the game with its time, and continuing brings the clock back.
offset = offset + 5
UIManager:close(screen)
local saved = home.settings:readSetting("two_player_game")
check(saved and saved.clock and saved.clock.w and math.abs(saved.clock.w - 295) < 1, "the time should be kept: " .. tostring(saved and saved.clock and saved.clock.w))
offset = offset + 1000
screen = OfflineGame.open(home, { resume = true, two_players = true }).screen
check(screen.state.bottom.clock == "4:55" and screen.state.bottom.active, "the clock should come back with its time and run: " .. tostring(screen.state.bottom.clock))

-- White runs out of time: black wins.
offset = offset + 400
run_queue()
check(screen.state.status == s.local_flag_w, "white should lose on time: " .. tostring(screen.state.status))
check(not ids(screen.state):find("undo", 1, true), "no undo after a flag")
check(home.settings:readSetting("two_player_game") == nil, "a game over is not kept")
UIManager:close(screen)

-- Undo back to the start while paused: the clock is new and the board answers again.
row_of(offline, s.two_players).callback()
row_of(home.pages[#home.pages], "5+3").callback()
screen = board()
play(screen, "e2", "e4")
screen.on_button("clock_pause")
screen.on_button("undo")
play(screen, "d2", "d4")
check(screen.state.position.board[Chess.square_from_name("d4")] ~= nil, "after undoing to the start, the board should answer")
check(screen.state.bottom.clock == "5:00" and screen.state.top.active, "the clock should start again after the first move")

-- Undo after a mate gives the clock back to the side to move.
screen.on_button("undo")
for _, move in ipairs({ { "f2", "f3" }, { "e7", "e5" }, { "g2", "g4" }, { "d8", "h4" } }) do
    play(screen, move[1], move[2])
end
check(screen.state.status == s.local_mate_b, "black should mate: " .. tostring(screen.state.status))
screen.on_button("undo")
check(screen.state.top.active, "after undoing the mate, black's clock should run")
UIManager:close(screen)
home.settings:delSetting("two_player_game")
UIManager:close(offline)

-- The chess clock for a physical board, 3+2.
home:offline_menu()
offline = home.pages[#home.pages]
row_of(offline, s.chess_clock).callback()
choice = home.pages[#home.pages]
check(row_of(choice, s.clock_none) == nil, "the chess clock always has a time")
row_of(choice, "3+2").callback()
local clock = top_window()
check(clock and clock.name == "ink_knight_clock", "the chess clock should open")
local Geom = require("ui/geometry")
local function tap(rect)
    clock:onTap(nil, { pos = Geom:new{ x = rect.x + math.floor(rect.w / 2), y = rect.y + math.floor(rect.h / 2) } })
end
local top, bottom = clock.halves.b, clock.halves.w
check(clock.clock.active == nil, "no clock runs before the first tap")
tap(bottom)
check(clock.clock.active == "b", "the first tap starts the other side's clock")
tap(bottom)
check(clock.clock.active == "b", "tapping the half that is not thinking does nothing")
offset = offset + 20
tap(top)
check(clock.clock.active == "w" and clock.clock.moves.b == 1, "tapping the half thinking passes the turn")
check(math.abs(clock.clock.left.b - 162) < 1, "the side that moved should get the increment: " .. clock.clock.left.b)
clock:paintTo(Screen.bb, 0, 0)
Screen.bb:writePNG(out_dir .. "/chess_clock.png")

-- The device sleeps: the clock pauses and waits for Continue.
clock:onSuspend()
check(clock.paused, "the clock should pause when the device sleeps")
offset = offset + 600
check(math.abs(require("ink_knight/chess_clock").left(clock.clock, "w", socket.gettime()) - 180) < 1, "no time should go while asleep")
clock:onResume()
run_queue()
check(clock.paused, "after waking up the clock still waits")
clock:on_button("resume")
check(not clock.paused, "Continue should start it again")

-- Leaving while it runs asks first, and staying lets it run again.
clock:onBack()
local question = home.pages[#home.pages]
check(question and question.lines[1] and question.lines[1].text == s.clock_leave_question, "leaving should ask first")
check(clock.paused, "the clock waits while asking")
question.lines[3].callback()
UIManager:close(question)
check(not clock.paused, "staying should let it run")

-- White runs out of time.
offset = offset + 200
run_queue()
check(clock.clock.flagged == "w", "white should be out of time")
tap(bottom)
check(clock.clock.flagged == "w" and clock.clock.moves.w == 0, "no turn after the flag")

-- Restarting after the flag needs no question.
clock:on_button("restart")
check(clock.clock.active == nil and clock.clock.left.w == 180, "restart should reset the clock")
UIManager:close(clock)
UIManager:close(offline)

socket.gettime = real_gettime
home.settings:delSetting("two_player_game")
home.settings:delSetting("clock_preset")
if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("clocks: everything as expected")
os.exit(0)
