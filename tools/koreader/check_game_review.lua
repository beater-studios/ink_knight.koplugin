-- Goes through the analysis of a game played without internet, on the real screens: a game between two people where
-- black allows a mate, the analysis started from the finished game, canceled, started again, the review opened with
-- the blunder marked and the better move named, a second tap that opens the same review at once, and in a game
-- against the engine only the reader's moves looked at. With INK_KNIGHT_STOCKFISH naming a Stockfish, the same game
-- analyzed by it, and a game without the analysis of the site analyzed by the plugin's engine, which says so.
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
-- The small engine gives counts in a notice, not the figures of a summary: More does not offer one.
review.on_button("more")
local more = home.pages[#home.pages]
local offers_summary = false
for _, line in ipairs(more and more.lines or {}) do
    if line.text == s.review_summary then offers_summary = true end
end
check(not offers_summary, "More should not offer a summary the small engine did not make")
if more then UIManager:close(more) end
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

-- With a Stockfish: the same game analyzed by it, every move judged as Lichess judges them, and a summary with figures.
if os.getenv("INK_KNIGHT_STOCKFISH") then
    local util = require("ffi/util")
    local ReviewScreen = require("ink_knight/ui/review_screen")
    home.plugin_dir = plugin_dir
    local function wait(done, seconds)
        local deadline = os.time() + (seconds or 60)
        while not done() and os.time() < deadline do
            run_queue(1)
            util.usleep(50000)
        end
        check(done(), "the analysis should finish")
    end
    local deep = OfflineGame.open(home, { two_players = true })
    for _, move in ipairs({ { "e2", "e4" }, { "e7", "e5" }, { "d1", "h5" }, { "b8", "c6" }, { "f1", "c4" }, { "g8", "f6" }, { "h5", "f7" } }) do
        play(deep, move[1], move[2])
    end
    deep.screen.on_button("analyze")
    check(deep.analysis and deep.analysis.runner, "with a Stockfish, it should analyze")
    check(deep.screen.state.status == string.format(s.engine_progress, 1, 8), "the progress counts positions from 1: " .. tostring(deep.screen.state.status))
    wait(function() return deep.review_game ~= nil end)
    local judged = deep.review_game and deep.review_game.moves[6]
    check(judged and judged.judgment == "Blunder" and judged.best ~= nil, "Stockfish should call Nf6 a blunder and name a better move: " .. tostring(judged and judged.judgment))
    check(deep.review_game and deep.review_game.summary and deep.review_game.summary.black.blunder >= 1, "the summary should count black's blunder")
    local deep_review = top_board()
    deep_review.on_button("more")
    local deep_more = home.pages[#home.pages]
    check(deep_more and deep_more.lines[1].text == s.review_summary, "a summary with figures comes first in More")
    UIManager:close(deep_more)
    UIManager:close(deep_review)
    UIManager:close(deep.screen)
    -- A game of Lichess the site did not analyze: the plugin's engine analyzes it, and the review says so.
    local online = ReviewScreen.open(home, { moves = {
        { uci = "e2e4", san = "e4" }, { uci = "e7e5", san = "e5" }, { uci = "d1h5", san = "Qh5" }, { uci = "b8c6", san = "Nc6" },
        { uci = "f1c4", san = "Bc4" }, { uci = "g8f6", san = "Nf6" }, { uci = "h5f7", san = "Qxf7#" } }, white = "A", black = "B" })
    online:more_menu()
    local online_more = home.pages[#home.pages]
    local offer
    for _, line in ipairs(online_more.lines) do
        if line.text == s.analyze_plugin then offer = line end
    end
    check(offer and offer.detail == s.analyze_plugin_detail, "a game without analysis offers the plugin's engine, saying what it is")
    UIManager:close(online_more)
    online:analyze_here()
    check(online.screen.state.status:find(s.engine_progress:match("^[^%%]+"), 1, true), "the progress should name the plugin's engine: " .. tostring(online.screen.state.status))
    wait(function() return online.analysis == nil end)
    check(online.game.summary and online.game.summary.source == "plugin" and online.game.intro == s.review_plugin_analysis, "the analysis should be the plugin's, and say so")
    local summary_page = home.pages[#home.pages]
    check(summary_page and summary_page.lines[1].text == s.review_plugin_analysis, "the summary should say whose analysis it is")
    summary_page:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/plugin_analysis_summary.png")
    UIManager:close(summary_page)
    UIManager:close(online.screen)
    -- Closing a screen in the middle of an analysis ends its Stockfish.
    local function engines_running()
        local list = io.popen("pgrep -x " .. os.getenv("INK_KNIGHT_STOCKFISH"):match("[^/]+$") .. " | wc -l")
        local count = tonumber(list:read("*a"))
        list:close()
        return count or 0
    end
    local left = OfflineGame.open(home, { two_players = true })
    for _, move in ipairs({ { "e2", "e4" }, { "e7", "e5" }, { "g1", "f3" }, { "b8", "c6" } }) do
        play(left, move[1], move[2])
    end
    left.resigned, left.resigned_color = true, "w"
    left:render()
    left.screen.on_button("analyze")
    check(engines_running() == 1, "one Stockfish while it analyzes: " .. engines_running())
    UIManager:close(left.screen)
    util.usleep(300000)
    check(engines_running() == 0, "no Stockfish left after the screen closed: " .. engines_running())
    -- A Stockfish that dies in the middle: the analysis ends with a notice instead of waiting forever.
    local dying = ReviewScreen.open(home, { moves = { { uci = "e2e4", san = "e4" }, { uci = "e7e5", san = "e5" } }, white = "A", black = "B" })
    dying:analyze_here()
    -- Killed by its own pid once it has one: the shell starts it a moment after the screen asks.
    local engine_pid
    wait(function()
        local file = io.open(home:engine_dir() .. "/stockfish.pid", "rb")
        engine_pid = file and tonumber(file:read("*a"))
        if file then
            file:close()
        end
        return engine_pid ~= nil
    end, 5)
    check(engine_pid, "the engine should write its pid")
    os.execute(string.format("kill -9 %d", engine_pid or 0))
    wait(function() return dying.analysis == nil end, 30)
    check(dying.game.summary == nil, "a dead engine should leave no summary")
    check(notices[#notices] == s.engine_stopped, "a dead engine should end the analysis with a notice: " .. tostring(notices[#notices]))
    UIManager:close(dying.screen)
end

home.settings:delSetting("two_player_game")
home.settings:delSetting("offline_game")
if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("game review: everything as expected")
os.exit(0)
