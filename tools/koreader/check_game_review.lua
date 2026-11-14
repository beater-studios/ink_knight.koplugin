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
-- As main.lua does: a game of Lichess keeps the device awake.
require("ink_knight/awake").install("ink_knight")
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
-- The panel: the move with its sign, the judgment in a solid tag, the better move with its arrow, the score in words.
local panel = review.state.panel
check(panel and panel.move == "3... Nf6??" and panel.tag == s.judgments.Blunder and panel.tag_solid, "the panel shows the move with its sign and judgment: " .. tostring(panel and panel.move))
check(panel and panel.detail == string.format(s.review_better_arrow, knight.best), "the panel names the better move on its arrow: " .. tostring(panel and panel.detail))
check(panel and panel.evaluation == string.format(s.eval_white_mate, 1), "the panel says the score in words: " .. tostring(panel and panel.evaluation))
local arrow = review.state.shapes and review.state.shapes[1]
check(arrow and arrow.from == Chess.square_from_name("g7") and arrow.to == Chess.square_from_name("g6"), "the arrow shows the better move")
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

-- The end of a game of Lichess, with a fake connection: the card over the board when it ends with the board open,
-- the review it opens, and the summary of Lichess with the reader's side, the chart and the reader's first mistake.
local LiveGame = require("ink_knight/ui/live_game")
local ReviewScreen = require("ink_knight/ui/review_screen")
local rapidjson = require("rapidjson")
local MATE_MOVES = "e2e4 e7e5 d1h5 b8c6 f1c4 g8f6 h5f7"
local function export_of(with_analysis)
    local players = { white = { user = { id = "me", name = "Me" } }, black = { user = { id = "rival", name = "Rival" } } }
    local game = { id = "abcd1234", variant = "standard", status = "mate", winner = "white", moves = "e4 e5 Qh5 Nc6 Bc4 Nf6 Qxf7#", players = players }
    if with_analysis then
        players.white.analysis = { inaccuracy = 0, mistake = 0, blunder = 0, acpl = 12, accuracy = 96 }
        players.black.analysis = { inaccuracy = 0, mistake = 1, blunder = 1, acpl = 230, accuracy = 55,
            phases = nil }
        game.analysis = { { eval = 20 }, { eval = 25 }, { eval = 10 }, { eval = 90, judgment = { name = "Mistake" } }, { eval = 80 },
            { mate = 1, judgment = { name = "Blunder" } } }
    end
    return game
end
local export_body
local stream_line
local real_net, real_closed = home.net, home.game_closed
home.my_id = "me"
home.game_closed = function() end
local fake_net = {
    stream = function(_, _, on_line) stream_line = on_line; return {} end,
    close_stream = function() end,
    request = function(_, request, callback)
        check(request.path:find("/game/export/", 1, true), "the review asks Lichess for the game: " .. tostring(request.path))
        callback(200, export_body)
    end,
}
home.net = fake_net
local function feed(event)
    stream_line(rapidjson.encode(event))
end
local ended = LiveGame.open(home, "abcd1234")
feed({ type = "gameFull", speed = "rapid", rated = true, clock = { initial = 600000, increment = 0 },
    white = { id = "me", name = "Me" }, black = { id = "rival", name = "Rival" },
    state = { moves = "e2e4 e7e5 d1h5 b8c6 f1c4 g8f6", status = "started", wtime = 500000, btime = 500000 } })
check(ended.screen.state.card == nil, "a game under way has no card")
-- A change of the whole screen goes with a flash, which waits for the update before it on the Kindle; one without
-- a flash, right after another, lost the bar of buttons there.
UIManager:forceRePaint()
local refreshes = {}
local real_refresh = UIManager._refresh
UIManager._refresh = function(manager, mode, region, ...)
    refreshes[#refreshes + 1] = tostring(mode)
    return real_refresh(manager, mode, region, ...)
end
feed({ type = "gameState", moves = MATE_MOVES, status = "mate", winner = "white", wtime = 490000, btime = 480000 })
UIManager:forceRePaint()
UIManager._refresh = real_refresh
check(table.concat(refreshes, " "):find("full", 1, true), "the card comes with a full refresh: " .. table.concat(refreshes, " "))
local card = ended.screen.state.card
check(card and card.title == "1-0" and card.text == s.ending_win_mate, "a game that ends with its board open gets the card: " .. tostring(card and card.text))
check(card and card.buttons[1].id == "review" and card.buttons[1].primary, "the review comes first on the card")
check(card and card.detail == string.format(s.game_card_moves, 4), "the card counts the moves: " .. tostring(card and card.detail))
check(ids(ended.screen) == "back rematch review more", "the bar of a finished game: " .. ids(ended.screen))
ended.screen:paintTo(Screen.bb, 0, 0)
Screen.bb:writePNG(out_dir .. "/end_card.png")
-- A tap beside the card's buttons does nothing; one on "See the board" closes it.
local layout = ended.screen:card_layout()
ended.screen:onTap(nil, { pos = { x = layout.x + 4, y = layout.y + 4 } })
check(ended.screen.state.card ~= nil, "a tap beside the buttons leaves the card")
local see = layout.buttons[#layout.buttons]
ended.screen:onTap(nil, { pos = { x = see.x + 2, y = see.y + 2 } })
check(ended.screen.state.card == nil, "See the board closes the card")
-- The review of a game Lichess analyzed opens on its summary.
export_body = rapidjson.encode(export_of(true))
local pages_before = #home.pages
ended.screen.on_button("review")
local lichess_summary = home.pages[#home.pages]
check(#home.pages == pages_before + 1 and lichess_summary.title == s.review_summary, "a game Lichess analyzed opens on its summary")
if lichess_summary then
    local texts, chart, buttons = {}, nil, nil
    for _, line in ipairs(lichess_summary.lines) do
        texts[#texts + 1] = tostring(line.text)
        if line.kind == "drawing" then chart = line end
        if line.kind == "buttons" then buttons = line end
    end
    check(texts[1] == s.review_lichess_analysis, "the summary says the analysis is Lichess's")
    check(table.concat(texts, "|"):find(string.format(s.review_you, "Me"), 1, true), "the reader's side is marked")
    check(chart and chart.points == 7, "the chart has a point per move")
    check(buttons and buttons.items[1].disabled and buttons.items[1].text == s.no_mistake_of_mine, "white made no mistake, and the button says so")
    lichess_summary:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/end_summary_lichess.png")
    local review = top_board()
    -- A tap on the chart goes to the nearest move, even a little to the right of its point.
    local chart_hit
    for _, hit in ipairs(lichess_summary.hits) do
        if hit.h == lichess_summary:px(150) then chart_hit = hit end
    end
    check(chart_hit, "the chart answers taps")
    if chart_hit then
        lichess_summary:onTap(nil, { pos = { x = chart_hit.x + math.floor(chart_hit.w * 6 / 7 + chart_hit.w / 21), y = chart_hit.y + 10 } })
    end
    check(review.state.status:find("Nf6", 1, true), "the chart goes to the move tapped: " .. tostring(review.state.status))
    check(review.state.top.tag == nil, "Lichess's analysis needs no tag")
    check(review.coordinates == true, "the review always shows the coordinates")
    UIManager:close(review)
end
-- A game from a position is read from it.
local from_position = home:open_review_of({ id = "abcd1236", variant = "fromPosition", initialFen = "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1",
    moves = "e4 Kd7 Kd2", status = "draw", players = export_of(false).players }, {})
check(from_position.available == 3, "a game from a position is read from it: " .. from_position.available)
UIManager:close(from_position.screen)
-- On the last move, a better move and the result both show: the result in place of the evaluation.
local ending = ReviewScreen.open(home, { moves = { { uci = "e2e4", san = "e4" }, { uci = "f7f6", san = "f6", judgment = "Mistake", best_uci = "e7e5", white_score = 80 } },
    white = "A", black = "B", result_text = s.white_wins })
ending:go(2)
local ending_panel = ending.screen.state.panel
check(ending_panel.detail == string.format(s.review_better_arrow, "e5") and ending_panel.evaluation == s.white_wins, "the last move keeps the result beside the better move: " .. tostring(ending_panel.evaluation))
UIManager:close(ending.screen)
-- Seen from black, the button goes to the reader's first mistake.
home.my_id = "rival"
export_body = rapidjson.encode(export_of(true))
home:review_finished_game("abcd1234", true)
local black_summary = home.pages[#home.pages]
local black_review = top_board()
for _, line in ipairs(black_summary and black_summary.lines or {}) do
    if line.kind == "buttons" then
        check(line.items[1].text == s.my_first_mistake and not line.items[1].disabled, "black has a first mistake to go to")
        line.items[1].callback()
    end
end
if black_summary then UIManager:close(black_summary) end
check(black_review.state.status:find("Nc6", 1, true), "the first mistake of black is Nc6: " .. tostring(black_review.state.status))
UIManager:close(black_review)
home.my_id = "me"
-- Without an analysis and without the plugin's engine, the review just opens.
export_body = rapidjson.encode(export_of(false))
pages_before = #home.pages
ended.screen.on_button("review")
if not os.getenv("INK_KNIGHT_STOCKFISH") then
    check(#home.pages == pages_before and top_board() ~= ended.screen, "with no engine, the review just opens")
end
while #home.pages > pages_before do
    UIManager:close(home.pages[#home.pages])
end
if top_board() ~= ended.screen then
    UIManager:close(top_board())
end
UIManager:close(ended.screen)
-- A game that had already ended when its board opened gets no card, as in correspondence.
local old = LiveGame.open(home, "abcd1235")
feed({ type = "gameFull", speed = "correspondence", white = { id = "me", name = "Me" }, black = { id = "rival", name = "Rival" },
    state = { moves = MATE_MOVES, status = "mate", winner = "white" } })
check(old.screen.state.card == nil and ids(old.screen):find("review", 1, true), "a game already over opens without the card, with Review on the bar: " .. ids(old.screen))
UIManager:close(old.screen)
home.net = real_net

-- With a Stockfish: the same game analyzed by it, every move judged as Lichess judges them, and a summary with figures.
if os.getenv("INK_KNIGHT_STOCKFISH") then
    local util = require("ffi/util")
    local ReviewScreen = require("ink_knight/ui/review_screen")
    home.plugin_dir = plugin_dir
    -- The engine is started by "sh", which on a Mac is bash. The Kindle's is busybox, a POSIX shell that treats the
    -- input of a job in the background differently, as dash does: when the Mac has dash, "sh" becomes dash here.
    local dash = io.open("/bin/dash", "rb")
    if dash then
        dash:close()
        local shim = out_dir .. "/posix_sh"
        os.execute("mkdir -p '" .. shim .. "' && ln -sf /bin/dash '" .. shim .. "/sh'")
        local ffi = require("ffi")
        require("ffi/posix_h")
        ffi.C.setenv("PATH", shim .. ":" .. os.getenv("PATH"), 1)
        print("engine started by dash, a POSIX shell like the Kindle's")
    end
    -- First of all, the engine answers: one that gets no input quits at once, and every analysis below would wait for it to the limit.
    local Stockfish = require("ink_knight/stockfish")
    local EngineAnalysis = require("ink_knight/ui/engine_analysis")
    if not EngineAnalysis.check(Stockfish.find(plugin_dir), home:engine_dir()) then
        print("FAILED: the engine should answer readyok; nothing else with Stockfish is checked")
        os.exit(1)
    end
    -- A binary that cannot be the engine is refused at once, each, from the line its shell writes, so a device where it does not run keeps the small one without waiting.
    local function refused_quickly(binary, what)
        local started_at = util.getTimestamp()
        local works = EngineAnalysis.check(binary, home:engine_dir())
        local took = util.getTimestamp() - started_at
        check(works == false and took < 1, string.format("%s is refused at once: %s in %.2f s", what, tostring(works), took))
    end
    refused_quickly("/usr/bin/true", "a program that ends at once")
    local not_executable = out_dir .. "/not_executable"
    local file = io.open(not_executable, "wb")
    file:write("not a program\n")
    file:close()
    os.execute("chmod 600 '" .. not_executable .. "'")
    refused_quickly(not_executable, "a file that cannot run")
    -- The real one passes, and the answer is kept with the binary, so it is not asked again.
    home.settings:delSetting("engine_check")
    check(EngineAnalysis.available(home) == true, "the Stockfish of the check runs")
    local kept = home.settings:readSetting("engine_check")
    check(kept and kept.binary == os.getenv("INK_KNIGHT_STOCKFISH") and kept.size and kept.size > 0 and kept.modified, "a yes is kept with the binary, its size and its date")
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
    check(judged and judged.white_cp ~= nil, "the offline analysis keeps the scores for the chart")
    -- The summary opens by itself after the analysis, as at the end of a Lichess game, with the reader's side marked.
    local deep_summary = home.pages[#home.pages]
    check(deep_summary and deep_summary.title == s.review_summary, "the summary opens after the analysis of an offline game")
    if deep_summary and deep_summary.title == s.review_summary then
        UIManager:close(deep_summary)
    end
    local deep_review = top_board()
    deep_review.on_button("more")
    local deep_more = home.pages[#home.pages]
    check(deep_more and deep_more.lines[1].text == s.review_summary, "a summary with figures comes first in More: " .. tostring(deep_more and deep_more.title) .. " " .. tostring(deep_more and deep_more.lines[1] and deep_more.lines[1].text))
    UIManager:close(deep_more)
    UIManager:close(deep_review)
    -- Opened again, the review comes on its board, without the summary over it.
    local pages_now = #home.pages
    deep.screen.on_button("analyze")
    check(#home.pages == pages_now, "the review opened again comes without the summary")
    UIManager:close(top_board())
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
        local file = dying.analysis and io.open(dying.analysis.engine.pid_path, "rb")
        engine_pid = file and tonumber(file:read("*a"))
        if file then
            file:close()
        end
        return engine_pid ~= nil
    end, 5)
    check(engine_pid, "the engine should write its pid")
    os.execute(string.format("kill -9 %d", engine_pid or 0))
    local killed_at = os.time()
    wait(function() return dying.analysis == nil end, 30)
    check(os.time() - killed_at <= 3, "a dead engine is noticed at once, from the line its shell writes: " .. (os.time() - killed_at) .. " s")
    check(dying.game.summary == nil, "a dead engine should leave no summary")
    check(notices[#notices] == s.engine_stopped, "a dead engine should end the analysis with a notice: " .. tostring(notices[#notices]))
    UIManager:close(dying.screen)
    -- At the end of a game Lichess did not analyze: the plugin's engine offered first, with the time it takes.
    home:save_setting("analyze_always", false)
    home.net = fake_net
    export_body = rapidjson.encode(export_of(false))
    home:review_finished_game("abcd1234", false)
    local offer_page = home.pages[#home.pages]
    local end_review = top_board()
    check(offer_page and offer_page.title == s.review_game, "a game without analysis offers the plugin's engine")
    local primary, always
    for _, line in ipairs(offer_page and offer_page.lines or {}) do
        if line.kind == "primary" then primary = line end
        if line.kind == "toggle" then always = line end
    end
    check(primary and primary.text == s.analyze_plugin and always and always.on == false, "the offer has the engine first and the option off")
    offer_page:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/end_offer.png")
    primary.callback()
    check(end_review.state.progress and end_review.state.progress.total == 8, "the analysis shows its progress as a bar")
    end_review:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/end_progress.png")
    wait(function() return home.pages[#home.pages] and home.pages[#home.pages].title == s.review_summary end)
    local plugin_summary = home.pages[#home.pages]
    check(plugin_summary.lines[1].text == s.review_plugin_analysis, "the summary says the analysis is the plugin's")
    plugin_summary:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/end_summary_plugin.png")
    UIManager:close(plugin_summary)
    check(end_review.state.top.tag == s.engine_tag, "every move of the plugin's analysis carries the tag")
    end_review:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/end_review_tag.png")
    -- The option goes on from More, and then the next review analyzes at once.
    end_review.on_button("more")
    local more = home.pages[#home.pages]
    local toggle
    for _, line in ipairs(more.lines) do
        if line.kind == "toggle" then toggle = line end
    end
    check(toggle and toggle.text == s.analyze_always, "More of the reader's game has the option")
    toggle.callback()
    check(home:option("analyze_always") == true, "the option turns on from More")
    UIManager:close(more)
    UIManager:close(end_review)
    pages_before = #home.pages
    home:review_finished_game("abcd1234", false)
    local auto_review = top_board()
    check(#home.pages == pages_before and auto_review.state.progress ~= nil, "with the option on, the analysis starts with no question")
    UIManager:close(auto_review)
    check(engines_running() == 0, "no Stockfish left after the reviews: " .. engines_running())
    home:save_setting("analyze_always", false)
end

home.settings:delSetting("two_player_game")
home.settings:delSetting("offline_game")
home.settings:delSetting("analyze_always")
home.settings:delSetting("engine_check")
home.net, home.game_closed = real_net, real_closed
if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("game review: everything as expected")
os.exit(0)
