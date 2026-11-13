-- Goes through the screens against the real Lichess, with no window, and saves a picture of each one.
-- It reads everything it can, and with PLAY_AI=1 it also plays a casual game against level 1 and resigns it. With
-- PLAY_AI_960=1 it plays a casual game of Chess960 against level 1, clears its back rank, castles when it can, checks
-- Lichess took the castling, and resigns it. With
-- CHANGE_ACCOUNT=1 it also writes a private note about the bot maia1 and blocks and unblocks it, which leaves the note
-- on the account.
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
-- As main.lua does: the downloads keep the device awake.
require("ink_knight/awake").install("ink_knight")
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

-- What came after 0.4.0, read only: the puzzles by opening and the history, the summary of a favorite the site
-- analyzed, the explorers of masters and of the reader, the parts of the profile and the rankings. Nothing here is
-- sent to the account.
do
    local s = home.strings
    local Chess = require("ink_knight/chess")
    home:puzzle_openings_menu()
    pump(function() return home.puzzle_openings ~= nil end, 30, "openings list")
    print("puzzle openings: " .. (home.puzzle_openings and #home.puzzle_openings or 0) .. " families")
    shot("puzzle_openings")
    home:close_pages()

    home:puzzle_history()
    pump(function()
        local page = top_widget()
        local first = page.lines and page.lines[1]
        return first and first.text ~= s.loading
    end, 30, "puzzle history")
    local history_rows = items_of(top_widget())
    print("puzzle history rows: " .. #history_rows .. ", first: " .. tostring(history_rows[1] and history_rows[1].text))
    shot("puzzle_history")
    if history_rows[1] and history_rows[1].callback and history_rows[1].kind == nil then
        history_rows[1].callback()
        local board = top_widget()
        if not board.state or not board.state.position then
            problem("a puzzle of the history should open on its position")
        end
        shot("puzzle_history_open")
        -- Left unsolved, so nothing is sent.
        UIManager:close(board)
    end
    home:close_pages()

    local ReviewScreen = require("ink_knight/ui/review_screen")
    local real_open = ReviewScreen.open
    local last_review
    ReviewScreen.open = function(...)
        last_review = real_open(...)
        return last_review
    end
    home:show_favorites()
    if opened("favorites for the summary") then
        for _, row in ipairs(items_of(top_widget())) do
            if row.callback and not last_review then
                row.callback()
                if not last_review.game.summary then
                    UIManager:close(last_review.screen)
                    last_review = nil
                end
            end
        end
        if last_review then
            local summary = last_review.game.summary
            print(string.format("summary of an analyzed favorite: accuracy %s / %s, middlegame at %s, endgame at %s",
                tostring(summary.white.accuracy), tostring(summary.black.accuracy), tostring(summary.middle), tostring(summary.ending)))
            last_review:show_summary()
            shot("review_summary")
            home:close_pages()
            UIManager:close(last_review.screen)
        else
            print("no favorite the site analyzed")
        end
        home:close_pages()
    end
    ReviewScreen.open = real_open

    local start = Chess.parse_fen("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1")
    ReviewScreen.analyze(home, start, "white")
    pump(function() return top_widget().title == s.analysis_title end, 40, "analysis page")
    local analysis_page = top_widget()
    for _, label in ipairs({ s.analysis_masters, s.analysis_own_white }) do
        local row
        for _, item in ipairs(items_of(analysis_page)) do
            row = row or (item.text == label and item)
        end
        if not row then
            problem("the analysis should offer " .. label)
        else
            row.callback()
            pump(function() return top_widget() ~= analysis_page and top_widget().title == label end, 40, label)
            print(label .. ": " .. tostring(top_widget().lines and top_widget().lines[1] and top_widget().lines[1].text:sub(1, 60)))
            shot(label == s.analysis_masters and "explorer_masters" or "explorer_own")
            if top_widget() ~= analysis_page then
                close_top()
            end
        end
    end
    home:close_pages()

    Players.show(home, home.my_id)
    if opened("own profile") then
        local profile = top_widget()
        for _, item in ipairs(items_of(profile)) do
            if item.text == s.profile_activity or (item.text or ""):find(s.perf_names.storm, 1, true) then
                local before = #UIManager._window_stack
                item.callback()
                if pump(function() return #UIManager._window_stack > before end, 30, item.text) then
                    print(item.text .. ": " .. #items_of(top_widget()) .. " rows")
                    shot(item.text == s.profile_activity and "profile_activity" or "profile_storm")
                    close_top()
                end
            end
        end
        home:close_pages()
    end
    -- The notes need note:write, which this token may not have: then the profile says so instead of asking.
    print("notes allowed by the token: " .. tostring(home:allows("notes")))
    -- The preferences of the site need preference:read; bringing them only changes the options on the device.
    if home:allows("preferences") then
        -- The options go back afterwards, so the games below play as the check expects (with no confirmation).
        local kept = {}
        for _, key in ipairs({ "auto_queen", "board_coordinates", "confirm_moves", "piece_set" }) do
            kept[key] = home.settings:readSetting(key)
        end
        home:settings_menu()
        local settings_page = top_widget()
        home:import_preferences(settings_page)
        pump(function() return top_widget() ~= settings_page and top_widget().title == s.import_preferences end, 30, "preferences")
        print("preferences brought: auto queen " .. tostring(home:option("auto_queen")) .. ", coordinates " .. tostring(home:option("board_coordinates"))
            .. ", confirm " .. tostring(home:option("confirm_moves")) .. ", pieces " .. tostring(home:option("piece_set")))
        shot("preferences_brought")
        home:close_pages()
        for _, key in ipairs({ "auto_queen", "board_coordinates", "confirm_moves", "piece_set" }) do
            if kept[key] == nil then home.settings:delSetting(key) else home.settings:saveSetting(key, kept[key]) end
        end
        home:apply_board_look()
    else
        print("preferences: the token has no preference:read")
    end
    Players.show_rankings(home)
    if opened("rankings") then
        print("rankings rows: " .. #items_of(top_widget()))
        shot("rankings")
        close_top()
    end
    -- Broadcasts, read with no permission: the lists, the first tournament, its standings, its round going on (or the
    -- one Lichess opens on), that round's games and the first game in the review, with its clocks.
    local Broadcasts = require("ink_knight/ui/broadcasts")
    -- A page or a board, not a notice: a refused request shows a notice on top.
    local function opens(action, label)
        local before = #UIManager._window_stack
        action()
        local ok = pump(function() return #UIManager._window_stack > before end, 30, label)
        local widget = top_widget()
        if ok and not (widget.lines or (widget.state and widget.state.position)) then
            problem(label .. ": a notice instead of the screen")
            return false
        end
        return ok
    end
    local function first_row(test)
        for _, row in ipairs(items_of(top_widget())) do
            if row.callback and test(row) then
                return row
            end
        end
    end
    if opens(function() Broadcasts.menu(home) end, "broadcasts") then
        print("broadcast rows: " .. #items_of(top_widget()))
        shot("broadcasts")
        local tour = first_row(function(row) return row.wrap end)
        if not tour then
            problem("broadcasts: no tournament listed")
        elseif opens(tour.callback, "broadcast tournament") then
            shot("broadcast_tournament")
            local tournament = top_widget()
            local standings = first_row(function(row) return row.text == s.broadcast_standings end)
            if standings and opens(standings.callback, "broadcast standings") then
                print("broadcast standings rows: " .. #items_of(top_widget()))
                shot("broadcast_standings")
                close_top()
            end
            local round = first_row(function(row) return row.bold end) or first_row(function(row) return row.detail == s.broadcast_finished end)
            if round and top_widget() == tournament and opens(round.callback, "broadcast round") then
                local games = {}
                for _, row in ipairs(items_of(top_widget())) do
                    if row.kind == "game" then games[#games + 1] = row end
                end
                print(string.format("broadcast round %s: %d games, first %s (%s)", round.text, #games, games[1] and games[1].text or "-", games[1] and games[1].detail or "-"))
                shot("broadcast_round")
                if games[1] and opens(games[1].callback, "broadcast game") then
                    local board = top_widget()
                    print(string.format("broadcast game: %s against %s, clocks %s / %s, %s", tostring(board.state.bottom and board.state.bottom.name),
                        tostring(board.state.top and board.state.top.name), tostring(board.state.bottom and board.state.bottom.clock),
                        tostring(board.state.top and board.state.top.clock), tostring(board.state.status)))
                    shot("broadcast_game")
                    close_top()
                elseif not games[1] then
                    problem("broadcast round: no games")
                end
            end
        end
    end
    home:close_pages()
    -- Keeping a finished tournament for real, through the download pattern, then deleting it.
    local BroadcastStore = require("ink_knight/broadcast_store")
    local Api = require("ink_knight/api")
    local top, tour_data
    home.net:request(Api.broadcast_top(1), function(status, body) top = status == 200 and home.decode(body) or false end)
    pump(function() return top ~= nil end, 30, "broadcast top")
    local past = top and top.past and top.past.currentPageResults and top.past.currentPageResults[1]
    if past then
        home.net:request(Api.broadcast_tournament(past.tour.id), function(status, body) tour_data = status == 200 and home.decode(body) or false end)
        pump(function() return tour_data ~= nil end, 30, "broadcast tournament data")
    end
    local entry = tour_data and BroadcastStore.entry_of(tour_data, os.time())
    -- Three rounds are enough to see the download, and ask little of Lichess after everything this check asked.
    if entry then
        while #entry.rounds > 3 do
            table.remove(entry.rounds)
        end
    end
    if entry then
        local kept_before = home.settings:readSetting("saved_broadcasts")
        home:save_broadcast_index(BroadcastStore.with_entry(home:saved_broadcasts(), entry))
        local started = os.time()
        home:download_broadcast(entry)
        pump(function() return not home.downloads:active() end, 300, "broadcast download")
        local have, all = home:broadcast_store():count(entry)
        print(string.format("broadcast kept: %s, %d of %d rounds in %d s, result %s", entry.name, have, all, os.time() - started, tostring((home.download_results or {})[entry.id])))
        if have ~= all then
            problem("broadcast kept: rounds missing")
        end
        local games = home:broadcast_store():round_games(entry, entry.rounds[1], s)
        print("kept round 1 games: " .. tostring(games and #games))
        home:broadcast_store():delete(entry)
        home.settings:saveSetting("saved_broadcasts", kept_before)
        home.settings:flush()
    else
        problem("broadcast kept: no finished tournament to keep")
    end
    -- Studies, read without the token unless it has study:read: the studies of the account lichess, then the puzzle
    -- pack of the 2026 Olympiad kept for real, a chapter of it opened, and deleted.
    local Studies = require("ink_knight/ui/studies")
    print("studies with the token: " .. tostring(home:reads_studies()))
    if opens(function() Studies.list(home, "lichess", "lichess") end, "study list") then
        print("study list rows: " .. #items_of(top_widget()))
        shot("study_list")
        close_top()
    end
    local kept_studies_before = home.settings:readSetting("saved_studies")
    local study = { id = "Zwqt6BdF", name = "Zwqt6BdF", chapters = {} }
    home:save_study_index({ study })
    local study_started = os.time()
    home:download_study(study)
    pump(function() return not home.downloads:active() end, 300, "study download")
    local kept_study = home:saved_studies()[1]
    print(string.format("study kept: %s, %d chapters in %d s, result %s", tostring(kept_study and kept_study.name), kept_study and #kept_study.chapters or 0,
        os.time() - study_started, tostring((home.download_results or {})["study_Zwqt6BdF"])))
    if not (kept_study and #kept_study.chapters > 0) then
        problem("study kept: no chapters")
    elseif opens(function() Studies.open_chapter(home, kept_study, 1) end, "study chapter") then
        shot("study_chapter")
        while top_widget().title do close_top() end
        close_top()
    end
    home:study_store():delete(study)
    home.settings:saveSetting("saved_studies", kept_studies_before)
    home.settings:flush()
    home:close_pages()
end

-- Only with CHANGE_ACCOUNT=1: a private note about the bot maia1, written on the device and read back, and the bot
-- blocked and unblocked from its profile.
if os.getenv("CHANGE_ACCOUNT") == "1" then
    local s = home.strings
    local target = "maia1"
    Players.show(home, target)
    if opened("maia1 profile") then
        local profile = top_widget()
        local function row(text)
            for _, item in ipairs(items_of(profile)) do
                if item.text == text then
                    return item
                end
            end
        end
        -- The note, through the dialog of the device, only with note:write.
        if not home:allows("notes") then
            print("notes skipped: the token has no note:write")
        else
            local note = "Ink Knight test note " .. os.date("!%Y-%m-%dT%H:%M:%SZ")
            row(s.profile_notes).callback()
            if pump(function() return top_widget() ~= profile and top_widget().title == s.profile_notes end, 30, "notes page") then
                local notes_page = top_widget()
                items_of(notes_page)[1].callback()
                local dialog
                for _, window in ipairs(UIManager._window_stack) do
                    if window.widget.setInputText then
                        dialog = window.widget
                    end
                end
                dialog:setInputText(note)
                dialog.button_table:getButtonById("save").callback()
                pump(function() return top_widget() ~= notes_page and top_widget().title == s.profile_notes end, 30, "notes again")
                local found = false
                for _, item in ipairs(items_of(top_widget())) do
                    found = found or (item.text or ""):find(note, 1, true) ~= nil
                end
                print("note written and read back: " .. tostring(found))
                if not found then problem("the note should be listed once written") end
                shot("notes_after_writing")
            end
            while top_widget() ~= profile do close_top() end
        end
        -- Blocked after the confirmation, then unblocked, only with follow:write, and not when the account follows the
        -- bot (blocking would drop the follow, which unblocking does not give back) or has it blocked already.
        if not home:allows("follow_change") then
            print("blocking skipped: the token has no follow:write")
        elseif row(s.unfollow_player) or row(s.unblock_player) then
            print("blocking skipped: the account follows " .. target .. " or has it blocked")
        else
            row(s.block_player).callback()
            local confirm = top_widget()
            for _, item in ipairs(items_of(confirm)) do
                if item.kind == "primary" then item.callback() end
            end
            UIManager:close(confirm)
            pump(function() return row(s.unblock_player) ~= nil end, 30, "blocked")
            print("blocked: " .. tostring(row(s.unblock_player) ~= nil))
            shot("profile_blocked")
            if row(s.unblock_player) then
                row(s.unblock_player).callback()
                pump(function() return row(s.block_player) ~= nil end, 30, "unblocked")
                print("unblocked: " .. tostring(row(s.block_player) ~= nil))
            else
                problem("the profile should offer to unblock once blocked")
            end
        end
        while #UIManager._window_stack > depth do close_top() end
    end
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

-- Only with PLAY_AI_960=1: a game of Chess960 against the computer, to see Lichess take a castling sent as the king
-- taking its rook.
if os.getenv("PLAY_AI_960") == "1" then
    local Api = require("ink_knight/api")
    local game_id
    home.net:request(Api.challenge_ai(1, nil, nil, "white", nil, "chess960"), function(status, body)
        local data = home.decode(body)
        print("chess960 ai game status " .. tostring(status))
        if data and data.id then
            game_id = data.id
            home:open_game(game_id)
        end
    end)
    if pump(function() return game_id ~= nil end, 25, "chess960 ai game") then
        local screen = top_widget()
        if pump(function() return screen.state.position ~= nil and screen.state.status ~= home.strings.loading end, 25, "chess960 stream") then
            print("the position is Chess960: " .. tostring(screen.state.position.chess960 == true))
            if not screen.state.position.chess960 then problem("a game of Chess960 should read as one") end
            local function my_turn() return screen.state.position.turn == "w" end
            local castled
            for turn = 1, 20 do
                if not pump(my_turn, 40, "chess960 turn " .. turn) then break end
                local position = screen.state.position
                local moves = Chess.legal_moves(position)
                local move
                for _, candidate in ipairs(moves) do
                    if candidate.castle then move = candidate end
                end
                -- Otherwise a piece standing where a castling needs room goes off the back rank: between king, rook and
                -- their squares (g and f, or c and d).
                local king_file = (Chess.king_square(position, "w") - 1) % 8 + 1
                local room = {}
                for letter in position.castling:gmatch("%u") do
                    local rook_file = letter:byte() - 64
                    local king_to, rook_to = rook_file > king_file and 7 or 3, rook_file > king_file and 6 or 4
                    for file = math.min(king_file, rook_file, king_to, rook_to), math.max(king_file, rook_file, king_to, rook_to) do
                        room[file] = true
                    end
                end
                local rank = {}
                for file = 1, 8 do rank[file] = position.board[file] or "." end
                print("turn " .. turn .. ": " .. table.concat(rank) .. " castling " .. position.castling)
                for _, candidate in ipairs(moves) do
                    local piece = position.board[candidate.from]
                    if not move and candidate.from <= 8 and room[candidate.from] and piece ~= "K" and piece ~= "R" and candidate.to > 8 then
                        move = candidate
                    end
                end
                -- Else a pawn of the second rank opens a way for them.
                for _, candidate in ipairs(moves) do
                    if not move and position.board[candidate.from] == "P" and candidate.from <= 16 then
                        move = candidate
                    end
                end
                move = move or moves[1]
                local before = position
                screen.on_square(move.from)
                screen.on_square(move.castle or move.to)
                pump(function() return screen.state.position ~= before and not my_turn() end, 15, "chess960 move")
                if move.castle then
                    castled = move
                    pump(my_turn, 40, "chess960 reply after castling")
                    local after = screen.state.position
                    local king_file = (Chess.king_square(after, "w") - 1) % 8 + 1
                    print(string.format("castled with %s: king on file %d", Chess.move_to_uci(move), king_file))
                    if king_file ~= 7 and king_file ~= 3 then problem("Lichess should keep the castling") end
                    shot("chess960_castled")
                    break
                end
                pump(my_turn, 40, "chess960 reply " .. turn)
            end
            if not castled then print("no castling came up in the moves played") end
            local done = false
            home.net:request(Api.resign(game_id), function(status) done = status == 200 end)
            pump(function() return done end, 25, "chess960 resign")
        end
        UIManager:close(screen)
        pump(function() return next(home.open_games) == nil end, 5, "chess960 game closed")
    end
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
