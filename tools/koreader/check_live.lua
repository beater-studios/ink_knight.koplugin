-- Goes through the screens against the real Lichess, with no window, and saves a picture of each one.
-- It reads everything it can, and with PLAY_AI=1 it also plays a casual game against level 1 and resigns it.
-- Usage: INK_KNIGHT_TOKEN=lip_... OUTPUT_DIR=/tmp/out KOREADER_DIR=... tools/koreader/run_headless.sh tools/koreader/check_live.lua
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))
local out_dir = assert(os.getenv("OUTPUT_DIR"))
local token = assert(os.getenv("INK_KNIGHT_TOKEN"), "set INK_KNIGHT_TOKEN")
require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
G_reader_settings:saveSetting("language", os.getenv("UI_LANGUAGE") or "pt")
package.path = plugin_dir .. "/?.lua;" .. package.path
os.execute('mkdir -p "' .. DataStorage:getDataDir() .. '/cache" "' .. DataStorage:getSettingsDir() .. '"')
local Device = require("device")
local Screen = Device.screen
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
UIManager:init()
local util = require("ffi/util")

local file = assert(io.open(DataStorage:getSettingsDir() .. "/ink_knight_token", "wb"))
file:write(token)
file:close()

local problems = 0
local function problem(text)
    problems = problems + 1
    print("PROBLEM: " .. text)
end
local function top_widget()
    local stack = UIManager._window_stack
    return stack[#stack].widget
end
local function shot(name)
    local widget = top_widget()
    widget:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/" .. name .. ".png")
end

local Home = require("ink_knight/ui/home")
local home = Home:new{ version = "test", plugin_dir = plugin_dir }
UIManager:show(home)
shot("start")
home:open_hub()

-- Pumps the network until a condition holds, and fails after a while.
local function pump(condition, seconds, label)
    local deadline = os.time() + (seconds or 25)
    while os.time() < deadline do
        if home.net then
            home.net:tick()
        end
        UIManager:_checkTasks()
        if condition() then
            return true
        end
        util.usleep(100000)
    end
    problem("timed out: " .. label)
    return false
end
local function list_opened(before)
    return #UIManager._window_stack > before
end
local function close_top()
    UIManager:close(top_widget())
end
-- Everything on a page that does something, whether a row or a tile.
local function items_of(widget)
    local items = {}
    for _, line in ipairs(widget.lines or {}) do
        if line.kind == "tile_line" then
            for _, item in ipairs(line.items) do items[#items + 1] = item end
        else
            items[#items + 1] = line
        end
    end
    return items
end

if not pump(function() return home.my_id ~= nil end, 25, "account") then
    print("account problem: " .. tostring(home.account_problem))
    os.exit(1)
end
print("account loaded")
pump(function() return home.updated_at ~= nil end, 25, "games")
shot("home")

local Players = require("ink_knight/ui/players")
local depth = #UIManager._window_stack
local function opened(label)
    return pump(function() return list_opened(depth) end, 25, label)
end

Players.show(home, home.my_id)
if opened("profile") then
    print("profile rows: " .. #items_of(top_widget()))
    if #items_of(top_widget()) == 0 then problem("profile is empty") end
    shot("profile")
    close_top()
end

Players.show_perf(home, home.my_id, home.my_name or "?", "rapid", home.strings.perf_names.rapid)
if opened("rating chart") then
    shot("rating_chart")
    close_top()
end

Players.search(home, "lichess", function() end)
if opened("player search") then
    print("players found: " .. #items_of(top_widget()))
    close_top()
end

home:show_puzzle_stats()
if opened("puzzle results") then
    print("puzzle results rows: " .. #items_of(top_widget()))
    shot("puzzle_stats")
    close_top()
end

home:show_past_games(home.my_id)
if opened("past games") then
    local widget = top_widget()
    print("past games: " .. #items_of(widget))
    shot("past_games")
    local rows = items_of(widget)
    if rows[1] and rows[1].callback then
        rows[1].callback()
        local review_depth = #UIManager._window_stack
        local review = top_widget()
        review.on_button("next")
        shot("past_game_review")
        review.on_button("more")
        items_of(top_widget())[1].callback()
        UIManager:_checkTasks()
        pump(function()
            return #UIManager._window_stack > review_depth and top_widget().title == home.strings.analysis_title
        end, 30, "analysis")
        print("analysis opened: " .. tostring(top_widget().title == home.strings.analysis_title))
        shot("analysis")
        home:close_pages()
        UIManager:close(review.on_button and top_widget() or review)
    end
    home:close_pages()
    UIManager:_checkTasks()
end

home:show_favorites()
if opened("favorites") then
    print("favorites opened")
    close_top()
end

pump(function() return #home:puzzle_pile() > 0 end, 25, "puzzle batch")
print("puzzles saved: " .. #home:puzzle_pile())
home:open_daily_puzzle()
if pump(function() return list_opened(depth) end, 25, "daily puzzle") then
    shot("puzzle_daily")
    close_top()
end
local PuzzleScreen = require("ink_knight/ui/puzzle_screen")
local puzzle = PuzzleScreen.open(home, {})
shot("puzzle")
local Chess = require("ink_knight/chess")
if puzzle.session then
    -- A wrong move first, then the solution from the Show button, which reports a miss to Lichess when flushed.
    print("puzzle prepared, solution length " .. #puzzle.session.puzzle.solution)
end
-- The results are not sent in this check: unsolved puzzles go back to the pile.
UIManager:close(puzzle.screen)
print("puzzles after leaving: " .. #home:puzzle_pile())

local OfflineGame = require("ink_knight/ui/offline_game")
local offline = OfflineGame.open(home, { level = 1, my_color = "w" })
shot("offline_start")
offline:on_square(Chess.square_from_name("e2"))
shot("offline_selected")
offline:on_square(Chess.square_from_name("e4"))
if pump(function() return not offline.thinking end, 15, "offline engine") then
    print("offline moves: " .. offline.moves)
    shot("offline_reply")
end
UIManager:close(offline.screen)
home.settings:delSetting("offline_game")

if os.getenv("PLAY_AI") == "1" then
    local before = {}
    for id in pairs(home.open_games) do before[id] = true end
    local Api = require("ink_knight/api")
    local game_id
    home.net:request(Api.challenge_ai(1, 15, 10), function(status, body)
        local data = home.decode(body)
        print("ai game status " .. tostring(status))
        if data and data.id then
            game_id = data.id
            home:open_game(game_id)
        end
    end)
    if pump(function() return game_id ~= nil end, 25, "ai game") then
        local screen = top_widget()
        local live
        -- The controller is reached through the callbacks of the screen, so moves go in by square, as a tap would.
        if pump(function() return screen.state.position ~= nil and screen.state.bottom ~= nil and screen.state.status ~= home.strings.loading end, 25, "game stream") then
            shot("live_start")
            local flipped = screen.state.flipped
            print("playing as " .. (flipped and "black" or "white"))
            local function my_turn()
                local position = screen.state.position
                return position.turn == (flipped and "b" or "w")
            end
            for turn = 1, 3 do
                pump(my_turn, 40, "my turn " .. turn)
                local moves = Chess.legal_moves(screen.state.position)
                local move = moves[1]
                for _, candidate in ipairs(moves) do
                    if screen.state.position.board[candidate.from]:lower() == "p" then
                        move = candidate
                        break
                    end
                end
                screen.on_square(move.from)
                shot("live_selected")
                if not screen.state.targets or not screen.state.targets[move.to] then
                    problem("the target was not offered")
                end
                local count_before = screen.state.position
                screen.on_square(move.to)
                if screen.state.position == count_before then
                    problem("the move was not shown right away")
                end
                pump(function() return not my_turn() end, 10, "move accepted")
                pump(my_turn, 40, "reply " .. turn)
                shot("live_turn_" .. turn)
            end
            local labels = {}
            for _, button in ipairs(screen.state.buttons) do labels[#labels + 1] = button.id end
            print("buttons: " .. table.concat(labels, " "))
            -- These moves are bad on purpose, so the game may already be lost by now.
            local function lost()
                local status = screen.state.status
                return status == home.strings.ending_loss_mate or status == home.strings.ending_loss_resign
            end
            local over = lost()
            if not over then
                local done = false
                home.net:request(Api.resign(game_id), function(status)
                    print("resign status " .. tostring(status))
                    done = status == 200
                end)
                pump(function() return done end, 25, "resign")
            end
            pump(lost, 20, "finished")
            shot("live_finished")
            print("status: " .. tostring(screen.state.status))
        end
        UIManager:close(screen)
        pump(function() return next(home.open_games) == nil end, 5, "game closed")
    end
    local settled = os.time() + 3
    pump(function() return os.time() >= settled end, 5, "last refresh")
    shot("home_after")
end

UIManager:close(home)
-- The token must never reach the disk outside the file that keeps it.
do
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes("/tmp/ink_knight", "mode") == "directory" then
        for name in lfs.dir("/tmp/ink_knight") do
            local file = io.open("/tmp/ink_knight/" .. name, "rb")
            local data = file and name ~= "." and name ~= ".." and file:read("*a") or ""
            if file then file:close() end
            if data and data:find(token, 1, true) then
                problem("the token reached a temporary file: " .. name)
            end
        end
    end
end
print("problems: " .. problems)
os.exit(problems == 0 and 0 or 1)
