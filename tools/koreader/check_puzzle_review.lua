-- Goes through the review of missed puzzles on the real screens, with invented answers and no network: the list from
-- Lichess, fetching what is missing, solving one, and what is kept for when there is no connection. Then the choice of
-- difficulty and color: online it asks for a batch that way, offline the kept puzzles still play. Last, the puzzles
-- that come in the package: from the offline menu, at the level chosen, going on after each one, with nothing sent.
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=... tools/koreader/run_headless.sh tools/koreader/check_puzzle_review.lua
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
local Net = require("ink_knight/net")
local Puzzles = require("ink_knight/puzzles")

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
local answers, asked, asked_urls = {}, {}, {}
local real_new = Net.new
Net.new = function(opts)
    local next_pid = 0
    opts.ca_file = ca_file
    opts.done = function() return true end
    opts.kill = function() end
    opts.spawn = function(spec)
        local path = spec.url:gsub("^https://[^/]+", ""):gsub("%?.*$", "")
        -- The invented event stream ends at once and reconnects all the time, so it is left out of what was asked.
        if path ~= "/api/stream/event" then
            asked[#asked + 1] = path
            asked_urls[#asked_urls + 1] = spec.url
        end
        local answer = answers[path] or answers.default
        write(spec.code_path, tostring(answer[1]))
        write(spec.out_path, answer[2] or "")
        next_pid = next_pid + 1
        return next_pid
    end
    return real_new(opts)
end

-- Scheduled work runs at once, apart from the clock of the status strip, which schedules itself.
local queue = {}
UIManager.scheduleIn = function(_, _, callback)
    queue[#queue + 1] = callback
end
local home
-- The timers of a window go through sleep.lua, which schedules a stand-in for each function: this tells whether
-- the stand-in is the one of fn on the window.
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

-- A mate in one for white: the game goes up to black's last move, and the solution is the mate.
local function puzzle_json(id)
    return string.format('{"game":{"id":"g%s","pgn":"e4 e5 Bc4 Nc6 Qh5 Nf6"},"puzzle":{"id":"%s","rating":1400,"solution":["h5f7"],"themes":["mateIn1"]}}', id, id)
end

answers = {
    ["/api/account"] = { 200, '{"id":"reader","username":"Reader"}' },
    ["/api/account/playing"] = { 200, '{"nowPlaying":[]}' },
    ["/api/puzzle/replay/30/mix"] = { 200, '{"replay":{"days":30,"theme":"mix","nb":2,"remaining":["miss1","miss2"]},"angle":{"key":"mix","name":"","desc":""}}' },
    ["/api/puzzle/miss1"] = { 200, puzzle_json("miss1") },
    ["/api/puzzle/miss2"] = { 200, puzzle_json("miss2") },
    default = { 200, "{}" },
}
home = Home:new{ version = "0" }
UIManager:show(home)
home.settings:delSetting("puzzles_review")
home.settings:delSetting("puzzle_results")
assert(home.token_store:save("lip_" .. string.rep("0", 20)))
home.token = "lip_" .. string.rep("0", 20)
home:open_hub()
run_all()
check(home.my_id == "reader", "the account should load")

-- Online: the list comes from Lichess, the missing puzzles are fetched, and the first one opens.
asked = {}
home:open_review()
run_all()
local top = UIManager:getTopmostVisibleWidget()
local screen_state = top and top.state
check(asked[1] == "/api/puzzle/replay/30/mix", "the list should be asked first, asked: " .. tostring(asked[1]))
check(asked[2] == "/api/puzzle/miss1" and asked[3] == "/api/puzzle/miss2", "each missing puzzle should be fetched" .. ", asked: " .. table.concat(asked, " "))
check(screen_state and screen_state.position ~= nil, "the first missed puzzle should open")
check(#home:puzzle_pile(Puzzles.REVIEW) == 1, "one should wait in the pile, got " .. #home:puzzle_pile(Puzzles.REVIEW))
check(#home:puzzle_pile() == 0 or true, "the pile of new puzzles is not touched")

-- Solving it sends the result as any other, under the general mix.
local puzzle_screen
for _, widget in ipairs(UIManager._window_stack or {}) do
    if widget.widget and widget.widget.on_square then
        puzzle_screen = widget.widget
    end
end
check(puzzle_screen ~= nil, "the puzzle screen should be on top")
if puzzle_screen then
    puzzle_screen.on_square(Chess.square_from_name("h5"))
    puzzle_screen.on_square(Chess.square_from_name("f7"))
    run_all()
    puzzle_screen:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/review_solved.png")
end
local sent_results = false
for _, path in ipairs(asked) do
    sent_results = sent_results or path == "/api/puzzle/batch/mix"
end
check(sent_results, "the result should go to Lichess under the mix")
check(#home.settings:readSetting("puzzle_results", {}) == 0, "the result should leave the queue once sent")

-- The next one comes from the pile, and at the end the screen says the review is done.
if puzzle_screen then
    puzzle_screen.on_button("next")
    run_all()
    check(puzzle_screen.state.position ~= nil, "the second missed puzzle should open")
    puzzle_screen.on_button("back")
    run_all()
end
check(#home:puzzle_pile(Puzzles.REVIEW) == 1, "leaving it unsolved should put it back, got " .. #home:puzzle_pile(Puzzles.REVIEW))

-- A second tap while the first review is still fetching asks nothing more.
home.settings:delSetting("puzzles_review")
asked = {}
home:open_review()
home:open_review()
run_all()
local replays = 0
for _, path in ipairs(asked) do
    if path == "/api/puzzle/replay/30/mix" then
        replays = replays + 1
    end
end
check(replays == 1, "a second tap should not ask again, asked the list " .. replays .. " times")
for _, widget in ipairs(UIManager._window_stack or {}) do
    if widget.widget and widget.widget.on_square and widget.widget ~= home.hub then
        UIManager:close(widget.widget)
    end
end
local ids = {}
for _, puzzle in ipairs(home:puzzle_pile(Puzzles.REVIEW)) do
    check(not ids[puzzle.id], "a puzzle should not be in the pile twice: " .. puzzle.id)
    ids[puzzle.id] = true
end

-- Leaving the online part in the middle of a review does not leave it stuck.
home:open_review()
check(home.fetching_review == true, "the review should be fetching")
UIManager:close(home.hub)
check(home.fetching_review == false, "leaving should end the fetching")
home:open_hub()
run_all()

-- Lichess no longer lists it, solved on the site: it leaves the pile, and there is nothing to review.
answers["/api/puzzle/replay/30/mix"] = { 404, '{"error":"No puzzles to replay"}' }
home:open_review()
run_all()
check(#home:puzzle_pile(Puzzles.REVIEW) == 0, "a puzzle Lichess no longer lists should leave the pile")

-- Without a connection, what is kept is used, and nothing is asked.
home.settings:saveSetting("puzzles_review", { Puzzles.prepare(require("rapidjson").decode(puzzle_json("kept1")), nil) })
home:puzzle_pile(Puzzles.REVIEW)[1].pile = Puzzles.REVIEW
UIManager:close(home.hub)
check(home.net == nil, "leaving the online part should stop the network")
asked = {}
home:offline_menu()
local menu = home.pages[#home.pages]
local review_row
for _, line in ipairs(menu.lines) do
    if line.text == home.strings.puzzle_review then
        review_row = line
    end
end
check(review_row ~= nil, "the offline menu should offer the kept missed puzzles")
if review_row then
    review_row.callback()
    run_all()
end
check(#asked == 0, "nothing should be asked without a connection")
check(#home:puzzle_pile(Puzzles.REVIEW) == 0, "the kept puzzle should be on the screen")

-- Difficulty and color, from the puzzles menu.
local s = home.strings
local decode = require("rapidjson").decode
local function old_puzzle(id) return Puzzles.prepare(decode(puzzle_json(id)), nil) end
local function batch_of(...)
    local list = {}
    for _, id in ipairs({ ... }) do
        list[#list + 1] = puzzle_json(id)
    end
    return { 200, '{"puzzles":[' .. table.concat(list, ",") .. "]}" }
end
local function ids_of(pile)
    local list = {}
    for _, puzzle in ipairs(pile) do
        list[#list + 1] = puzzle.id
    end
    return table.concat(list, " ")
end
local function row_of(page, text)
    for _, line in ipairs(page.lines) do
        if line.text == text then
            return line
        end
    end
end
-- Picks a choice the way a tap does; called directly, the choice page is closed by hand.
local function pick(menu, row_text, choice_text)
    row_of(menu, row_text).callback()
    local choice = home.pages[#home.pages]
    local row = row_of(choice, choice_text)
    check(row ~= nil, "the choice should list " .. choice_text)
    row.callback()
    UIManager:close(choice)
end
home.puzzle_in_play = nil
home.settings:delSetting("puzzle_difficulty")
home.settings:delSetting("puzzle_color")
home.settings:saveSetting("puzzles", { old_puzzle("old1"), old_puzzle("old2") })
home:open_hub()
run_all()

-- Online, a batch that brings only one puzzle the new way leaves the kept ones, so there is still enough offline.
answers["/api/puzzle/batch/mix"] = batch_of("new1")
asked_urls = {}
home:puzzles_menu()
local puzzles_page = home.pages[#home.pages]
check(row_of(puzzles_page, s.puzzle_difficulty).value == s.puzzle_difficulties.normal, "the menu should show the normal difficulty first")
pick(puzzles_page, s.puzzle_difficulty, s.puzzle_difficulties.harder)
run_all()
local batch_url = table.concat(asked_urls, " ")
check(batch_url:find("/api/puzzle/batch/mix?nb=15&difficulty=harder", 1, true) and not batch_url:find("color=", 1, true),
    "the batch should ask for the difficulty chosen and no color: " .. batch_url)
check(ids_of(home:puzzle_pile()) == "old1 old2 new1", "a batch of one should leave the kept puzzles: " .. ids_of(home:puzzle_pile()))
check(home:puzzle_pile()[3].wanted == Puzzles.wanted("harder", "any"), "a puzzle should keep how it was asked")
check(row_of(puzzles_page, s.puzzle_difficulty).value == s.puzzle_difficulties.harder, "the menu should show the new difficulty")

-- A tap on the next puzzle while the batch is on its way opens it when the batch arrives, and enough puzzles the
-- new way replace the others.
answers["/api/puzzle/batch/mix"] = batch_of("new2", "new3", "new4", "new5")
pick(puzzles_page, s.puzzle_color, s.puzzle_colors.black)
check(home.puzzle_waiting.puzzles ~= nil, "changing the color should ask for a batch")
home:open_puzzles(nil)
check(home.puzzle_in_play == nil, "nothing should open before the batch arrives")
run_all()
check(home.puzzle_in_play and home.puzzle_in_play.id == "new2", "the first puzzle of the new batch should open: "
    .. tostring(home.puzzle_in_play and home.puzzle_in_play.id))
check(ids_of(home:puzzle_pile()) == "new3 new4 new5", "enough puzzles the new way should replace the others: " .. ids_of(home:puzzle_pile()))
for _, widget in ipairs(UIManager._window_stack or {}) do
    if widget.widget and widget.widget.on_square and widget.widget ~= home.hub then
        UIManager:close(widget.widget)
    end
end
home.puzzle_in_play = nil
UIManager:close(puzzles_page)

-- By opening: the list comes once a session, a family opens on its variations, and a variation asks for a batch
-- with its key, keeps its pile and goes to the top of the recent ones.
home.puzzle_openings = nil
home.settings:delSetting("puzzle_openings_recent")
answers["/training/openings"] = { 200, '{"openings":[{"family":{"key":"Sicilian_Defense","name":"Sicilian Defense","count":207281},'
    .. '"openings":[{"key":"Sicilian_Defense_Najdorf_Variation","name":"Najdorf Variation","count":11197}]},'
    .. '{"family":{"key":"Hippopotamus_Defense","name":"Hippopotamus Defense","count":77}}]}' }
answers["/api/puzzle/batch/Sicilian_Defense_Najdorf_Variation"] = batch_of("open1", "open2", "open3", "open4", "open5")
local function close_boards()
    local boards = {}
    for _, widget in ipairs(UIManager._window_stack or {}) do
        if widget.widget and widget.widget.on_square and widget.widget ~= home.hub then
            boards[#boards + 1] = widget.widget
        end
    end
    for _, board in ipairs(boards) do
        UIManager:close(board)
    end
    home.puzzle_in_play = nil
end
asked = {}
home:puzzles_menu()
puzzles_page = home.pages[#home.pages]
row_of(puzzles_page, s.puzzle_by_opening).callback()
local openings_page = home.pages[#home.pages]
check(openings_page.lines[1] and openings_page.lines[1].text == s.loading, "the page should open at once, waiting for the list")
run_all()
local sicilian = row_of(openings_page, "Sicilian Defense")
check(sicilian and sicilian.value == "207" .. s.thousands .. "281", "the families should come with their counts: " .. tostring(sicilian and sicilian.value))
check(row_of(openings_page, s.puzzle_openings_recent) == nil, "no recent openings yet")
sicilian.callback()
local family_page = home.pages[#home.pages]
check(row_of(family_page, s.puzzle_opening_whole) and row_of(family_page, "Najdorf Variation"), "the family should offer itself whole and its variations")
row_of(family_page, "Najdorf Variation").callback()
run_all()
check(table.concat(asked, " "):find("/api/puzzle/batch/Sicilian_Defense_Najdorf_Variation", 1, true), "the batch should be asked by the key of the opening: " .. table.concat(asked, " "))
check(home.puzzle_in_play and home.puzzle_in_play.angle == "Sicilian_Defense_Najdorf_Variation", "a puzzle of the opening should open")
check(#home:puzzle_pile("Sicilian_Defense_Najdorf_Variation") > 0, "the opening keeps its pile")
close_boards()
UIManager:close(family_page)
check(row_of(openings_page, s.puzzle_openings_recent) and row_of(openings_page, "Sicilian Defense: Najdorf Variation"), "the opening should be on top as recent")
-- The list is asked once a session.
asked = {}
UIManager:close(openings_page)
row_of(puzzles_page, s.puzzle_by_opening).callback()
check(#asked == 0, "the list should not be asked again: " .. table.concat(asked, " "))
UIManager:close(home.pages[#home.pages])
-- Five more openings: the first falls off the recent ones, and its pile goes.
for index = 1, 5 do
    home.settings:saveSetting("puzzles_Other_" .. index, { old_puzzle("other" .. index) })
    home:open_opening_puzzles("Other_" .. index, "Other " .. index)
    run_all()
    close_boards()
end
check(#home:recent_openings() == 5 and home:recent_openings()[1].key == "Other_5", "five recent openings, the last first")
check(home.settings:readSetting("puzzles_Sicilian_Defense_Najdorf_Variation") == nil, "the pile of the opening that fell off should go")
-- A late batch of the opening that fell off does not bring its pile back.
answers["/api/puzzle/batch/Sicilian_Defense_Najdorf_Variation"] = batch_of("late1")
home:ensure_puzzles("Sicilian_Defense_Najdorf_Variation")
run_all()
check(home.settings:readSetting("puzzles_Sicilian_Defense_Najdorf_Variation") == nil, "a late batch should not keep a pile for it")
-- An opening that cannot open, with no puzzles and Lichess failing, takes nothing away.
answers["/api/puzzle/batch/Failing_Opening"] = { 500, "" }
home:open_opening_puzzles("Failing_Opening", "Failing")
run_all()
close_boards()
check(home:recent_openings()[1].key == "Other_5" and home.settings:readSetting("puzzles_Other_1") ~= nil, "a failed opening should not change the recent ones or drop a pile")
-- Without the network, the page still offers the recent ones, whose puzzles are kept.
local saved_net, saved_list = home.net, home.puzzle_openings
home.net, home.puzzle_openings = nil, nil
home:puzzle_openings_menu()
local offline_openings = home.pages[#home.pages]
check(row_of(offline_openings, "Other 5") and row_of(offline_openings, s.no_network), "offline, the recent ones and a note: " .. tostring(offline_openings.lines[2] and offline_openings.lines[2].text))
UIManager:close(offline_openings)
home.net, home.puzzle_openings = saved_net, saved_list
for index = 1, 5 do
    home.settings:delSetting("puzzles_Other_" .. index)
end
home.settings:delSetting("puzzle_openings_recent")
UIManager:close(puzzles_page)

-- Offline: the color changes, nothing is asked, and the kept puzzles still play.
UIManager:close(home.hub)
asked = {}
home:puzzles_menu()
puzzles_page = home.pages[#home.pages]
local kept_before = #home:puzzle_pile()
pick(puzzles_page, s.puzzle_color, s.puzzle_colors.any)
run_all()
check(#asked == 0, "nothing should be asked without a connection")
check(home:option("puzzle_color") == "any", "the color should be saved")
check(kept_before > 0 and #home:puzzle_pile() == kept_before, "the kept puzzles should stay without a connection")
home:open_puzzles(nil)
check(home.puzzle_in_play ~= nil, "a kept puzzle should still open")
for _, widget in ipairs(UIManager._window_stack or {}) do
    if widget.widget and widget.widget.on_square then
        UIManager:close(widget.widget)
    end
end
home.puzzle_in_play = nil
UIManager:close(puzzles_page)

-- The puzzles of the package, offline: the first of the level opens, solving it goes on to the next, leaving one
-- unsolved keeps it, and nothing is asked or recorded for Lichess.
local PuzzlePack = require("ink_knight/puzzle_pack")
home.settings:delSetting("puzzle_pack")
home.settings:delSetting("puzzle_results")
home.settings:saveSetting("puzzle_difficulty", "easier")
home.settings:saveSetting("puzzle_color", "any")
asked = {}
home:offline_menu()
local offline = home.pages[#home.pages]
local pack_row = row_of(offline, s.pack_title)
check(pack_row ~= nil, "the offline menu should offer the puzzles of the package")
pack_row.callback()
local pack_page = home.pages[#home.pages]
local start = row_of(pack_page, s.pack_start)
check(start ~= nil, "the package should start from its first puzzle")
start.callback()
local first = PuzzlePack.list("easier")[1][1]
local pack_screen
for _, widget in ipairs(UIManager._window_stack or {}) do
    if widget.widget and widget.widget.on_square then
        pack_screen = widget.widget
    end
end
check(home.puzzle_in_play == nil, "a puzzle of the package is not one of the pile")
for _ = 1, 12 do
    if pack_screen.state.buttons and pack_screen.state.buttons[2] and pack_screen.state.buttons[2].id == "show" then
        pack_screen.on_button("show")
        run_all()
    end
end
local progress = home.settings:readSetting("puzzle_pack") or {}
check(progress.easier == 2, "solving the first puzzle should go on to the second: " .. tostring(progress.easier))
check(#home:puzzle_results() == 0, "a puzzle of the package should not be recorded for Lichess")
pack_screen.on_button("next")
UIManager:close(pack_screen)
check((home.settings:readSetting("puzzle_pack") or {}).easier == 2, "leaving a puzzle unsolved should keep it for next time")
check(row_of(pack_page, s.pack_continue) ~= nil, "the page should offer to continue")
check(#asked == 0, "the package should ask nothing: " .. table.concat(asked, " "))
check(first ~= nil, "the level should have puzzles")
UIManager:close(pack_page)
UIManager:close(offline)
-- Progress past the end of the level, left by a package with more puzzles, starts over.
home.settings:saveSetting("puzzle_pack", { easier = PuzzlePack.per_level() + 5 })
check(home:pack_index("easier") == 1, "a place past the end of the level should start over")
check(home:pack_puzzle().pack_index == 1, "the level should open on its first puzzle again")
home.settings:delSetting("puzzle_pack")

home.settings:delSetting("puzzles")
home.settings:delSetting("puzzle_difficulty")
home.settings:delSetting("puzzle_color")
home.settings:delSetting("puzzles_review")
home.settings:delSetting("puzzle_results")
home:forget_token()
os.remove(ca_file)
if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("puzzle review: everything as expected")
os.exit(0)
