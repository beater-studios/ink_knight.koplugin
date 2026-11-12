-- Goes through the analysis of a game played without internet, on the real screens: a game between two people where
-- black allows a mate, the analysis started from the finished game, canceled, started again, the review opened with
-- the blunder marked and the better move named, a second tap that opens the same review at once, and in a game
-- against the engine only the reader's moves looked at.
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=... tools/koreader/run_headless.sh tools/koreader/check_game_review.lua
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
local OfflineGame = require("ink_knight/ui/offline_game")

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
local function run_queue(limit)
    for _ = 1, limit or 100000 do
        if #queue == 0 then
            return
        end
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
local notices = {}
local real_info = home.info
home.info = function(self, text, ...)
    notices[#notices + 1] = text
    return real_info(self, text, ...)
end
home.settings:delSetting("two_player_game")
home.settings:delSetting("offline_game")

local function play(game, from, to)
    game:on_square(Chess.square_from_name(from))
    game:on_square(Chess.square_from_name(to))
end
local function ids(screen)
    local list = {}
    for _, button in ipairs(screen.state.buttons or {}) do
        list[#list + 1] = button.id
    end
    return table.concat(list, " ")
end
local function top_board()
    local stack = UIManager._window_stack
    for index = #stack, 1, -1 do
        local widget = stack[index].widget
        if widget.on_square then
            return widget
        end
    end
end

-- 1.e4 e5 2.Qh5 Nc6 3.Bc4 Nf6?? 4.Qxf7#
local game = OfflineGame.open(home, { two_players = true })
for _, move in ipairs({ { "e2", "e4" }, { "e7", "e5" }, { "d1", "h5" }, { "b8", "c6" }, { "f1", "c4" }, { "g8", "f6" }, { "h5", "f7" } }) do
    play(game, move[1], move[2])
end
check(game:is_over() and game.ending == "mate", "the game should end in mate")
check(ids(game.screen):find("analyze", 1, true), "a finished game offers the analysis: " .. ids(game.screen))

-- Started and canceled: back to the finished game.
game.screen.on_button("analyze")
check(game.screen.state.status == string.format(s.analysis_progress, 1, 7), "the progress should show the seven moves: " .. tostring(game.screen.state.status))
check(ids(game.screen) == "back analysis_cancel", "while analyzing, back or cancel: " .. ids(game.screen))
game.screen.on_button("analysis_cancel")
run_queue()
check(game.analysis == nil and game.screen.state.status == s.local_mate_w, "cancel should go back to the finished game")

-- Started again and finished: the review opens with the blunder of black.
game.screen.on_button("analyze")
run_queue()
local review = top_board()
check(review and review ~= game.screen, "the review should open")
local reviewed = game.review_game
local knight = reviewed.moves[6]
check(knight.judgment == "Blunder", "Nf6 should be a blunder: " .. tostring(knight.judgment))
check(knight.best ~= nil and knight.best ~= "Nf6", "a better move should be named: " .. tostring(knight.best))
check(reviewed.moves[1].judgment == nil, "1.e4 is fine")
check(notices[#notices] and notices[#notices]:find(s.color_black, 1, true), "the notice should sum up both sides: " .. tostring(notices[#notices]))
review:paintTo(Screen.bb, 0, 0)
Screen.bb:writePNG(out_dir .. "/game_review_start.png")
-- On the blunder, the review says it and names the better move.
for _ = 1, 6 do
    review.on_button("next")
end
check(review.state.status:find(s.judgments.Blunder, 1, true) and review.state.status:find(knight.best, 1, true),
    "the review should mark the blunder and name the better move: " .. tostring(review.state.status))
review:paintTo(Screen.bb, 0, 0)
Screen.bb:writePNG(out_dir .. "/game_review_blunder.png")
UIManager:close(review)

-- A second tap opens the same review at once, without searching again.
game.screen.on_button("analyze")
check(game.analysis == nil and game.search == nil and top_board() ~= game.screen, "the second tap should open the review without searching again")
UIManager:close(top_board())
UIManager:close(game.screen)

-- Against the engine, only the reader's moves are looked at.
local versus = OfflineGame.open(home, { level = 1, color_choice = "white" })
play(versus, "e2", "e4")
run_queue(400)
play(versus, "d2", "d4")
run_queue(400)
versus.resigned, versus.resigned_color = true, "w"
versus:render()
versus.screen.on_button("analyze")
check(versus.analysis and #versus.analysis.list == 2, "only the reader's two moves: " .. tostring(versus.analysis and #versus.analysis.list))
versus.screen.on_button("analysis_cancel")
UIManager:close(versus.screen)

-- As black, resigning before a move of one's own: nothing to look at, and a notice says so.
local early = OfflineGame.open(home, { level = 1, color_choice = "black" })
run_queue(400)
early.resigned, early.resigned_color = true, "b"
early:render()
early.screen.on_button("analyze")
check(early.analysis == nil and notices[#notices] == s.analysis_nothing, "nothing to analyze should say so: " .. tostring(notices[#notices]))
UIManager:close(early.screen)

home.settings:delSetting("two_player_game")
home.settings:delSetting("offline_game")
if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("game review: everything as expected")
os.exit(0)
