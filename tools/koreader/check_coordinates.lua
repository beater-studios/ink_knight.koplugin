-- Goes through the coordinate training on the real screens: the page from the offline menu, a run with the clock in
-- both modes, a right and a wrong answer, the end of the time with a new best on the page, a run with no limit
-- stopped by hand, the pause while the device sleeps, and the board drawn without coordinates.
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=... tools/koreader/run_headless.sh tools/koreader/check_coordinates.lua
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

-- Timers run only when asked, so the clock is moved by hand.
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

local home = Home:new{ version = "0" }
UIManager:show(home)
local s = home.strings
for _, key in ipairs({ "coordinate_records", "coordinates_mode", "coordinates_side", "coordinates_time", "coordinates_pieces" }) do
    home.settings:delSetting(key)
end
home.settings:saveSetting("board_coordinates", true)
home:apply_board_look()

local function row_of(page, text)
    for _, line in ipairs(page.lines) do
        if line.text == text then
            return line
        end
    end
end
local function training()
    for _, widget in ipairs(UIManager._window_stack or {}) do
        if widget.widget and widget.widget.on_square then
            return widget.widget
        end
    end
end
local function button_ids(screen)
    local ids = {}
    for _, button in ipairs(screen.state.buttons or {}) do
        ids[#ids + 1] = button.id
    end
    return table.concat(ids, " ")
end

-- The page, from the offline menu, with no best yet.
home:offline_menu()
local offline = home.pages[#home.pages]
row_of(offline, s.coordinates).callback()
local page = home.pages[#home.pages]
check(page.title == s.coordinates, "the offline menu should open the training page")
check(row_of(page, s.coord_sides.white).value == "0", "no best yet")
row_of(page, s.coord_start).callback()
local screen = training()
check(screen and screen.coordinates == false, "the training board should have no coordinates, whatever the option")
check(screen.state.status == s.coord_ready, "the board should wait for Start")

-- Finding squares, with the clock: the square shows in the box of the top bar.
screen.on_button("start")
local target = screen.state.top.clock
check(target and target:match("^[a-h][1-8]$"), "the square to find should show in the top bar: " .. tostring(target))
check(screen.state.bottom.clock == "0:30", "the clock should start at 0:30: " .. tostring(screen.state.bottom.clock))
local wrong = target == "a1" and "h8" or "a1"
screen.on_square(Chess.square_from_name(wrong))
check(screen.state.status == string.format(s.coord_wrong_find, wrong) and screen.state.top.clock == target, "a wrong square should keep the same one and say which it was")
screen.on_square(Chess.square_from_name(target))
check(screen.state.status == s.coord_right and screen.state.bottom.name == string.format(s.coord_score, 1), "a right square should score")
check(screen.state.top.clock ~= target, "a right square should move on")
screen:paintTo(Screen.bb, 0, 0)
Screen.bb:writePNG(out_dir .. "/coordinates_find.png")

-- Time is moved by hand: the training reads it from socket.gettime, here ahead of the real one by offset.
local socket = require("socket")
local real_gettime = socket.gettime
local offset = 0
socket.gettime = function() return real_gettime() + offset end
local function later(seconds, fn)
    offset = offset + seconds
    fn()
end

-- The device sleeps for a minute: the clock waits, and goes on from there after waking up.
screen:onSuspend()
later(60, function()
    run_queue()
    screen:onResume()
    run_queue()
end)
check(screen.state.status ~= string.format(s.coord_over_record, 1) and screen.state.status ~= string.format(s.coord_over, 1),
    "the run should not end while the device sleeps: " .. tostring(screen.state.status))

-- With the sleep screen waiting for a tap after Resume, the clock only starts again once it is gone.
screen:onSuspend()
Device.screen_saver_mode = true
screen:onResume()
later(60, run_queue)
Device.screen_saver_mode = false
screen:onOutOfScreenSaver()
run_queue()
check(screen.state.status ~= string.format(s.coord_over_record, 1) and screen.state.status ~= string.format(s.coord_over, 1),
    "the run should not end while the sleep screen waits: " .. tostring(screen.state.status))

-- An answer after the time is up ends the run instead of scoring.
local before = screen.state.bottom.name
offset = offset + 31
screen.on_square(Chess.square_from_name(screen.state.top.clock))
check(screen.state.bottom.name == before, "an answer after the time should not score")

-- The time had run out: the run ended, and the best shows on the page.
run_queue()
check(screen.state.status == string.format(s.coord_over_record, 1), "the end of the time should give a new best: " .. tostring(screen.state.status))
check(button_ids(screen) == "back start", "after the end, again or back: " .. button_ids(screen))
UIManager:close(screen)
check(row_of(page, s.coord_sides.white).value == "1" or row_of(page, s.coord_sides.black).value == "1", "the page should show the new best")

-- Naming squares: the square is marked and the names are the buttons.
home:save_setting("coordinates_mode", "name")
home:save_setting("coordinates_side", "black")
row_of(page, s.coord_start).callback()
screen = training()
screen.on_button("start")
check(screen.state.flipped == true, "the black side should be at the bottom")
check(screen.state.selected ~= nil and screen.state.top.clock == nil, "to name a square, it should be marked")
local right_name = Chess.square_name(screen.state.selected)
local right_id
for _, button in ipairs(screen.state.buttons) do
    if button.label == right_name then
        right_id = button.id
    end
end
check(right_id ~= nil, "the right name should be one of the buttons: " .. button_ids(screen))
screen.on_button(right_id)
check(screen.state.bottom.name == string.format(s.coord_score, 1), "the right name should score")
screen:paintTo(Screen.bb, 0, 0)
Screen.bb:writePNG(out_dir .. "/coordinates_name.png")
UIManager:close(screen)

-- A side drawn at random is the one shown before Start, so the board does not turn when the run begins.
home:save_setting("coordinates_side", "random")
for _ = 1, 10 do
    row_of(page, s.coord_start).callback()
    screen = training()
    local shown = screen.state.flipped
    screen.on_button("start")
    check(screen.state.flipped == shown, "the board should not turn on Start")
    UIManager:close(screen)
end

-- No limit: no clock, and Stop ends the run with no best kept.
home:save_setting("coordinates_mode", "find")
home:save_setting("coordinates_time", "none")
row_of(page, s.coord_start).callback()
screen = training()
screen.on_button("start")
check(screen.state.bottom.clock == nil, "no clock with no limit")
check(button_ids(screen) == "back stop", "with no limit, Stop: " .. button_ids(screen))
screen.on_square(Chess.square_from_name(screen.state.top.clock))
screen.on_button("stop")
check(screen.state.status == string.format(s.coord_over, 1), "Stop should end the run: " .. tostring(screen.state.status))
UIManager:close(screen)
UIManager:close(page)
UIManager:close(offline)

socket.gettime = real_gettime
home.settings:saveSetting("board_coordinates", false)
for _, key in ipairs({ "coordinate_records", "coordinates_mode", "coordinates_side", "coordinates_time", "coordinates_pieces" }) do
    home.settings:delSetting(key)
end
if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("coordinates: everything as expected")
os.exit(0)
