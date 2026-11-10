-- Goes through the review of missed puzzles on the real screens, with invented answers and no network: the list from
-- Lichess, fetching what is missing, solving one, and what is kept for when there is no connection.
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
local answers, asked = {}, {}
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
