-- Goes through the challenges the reader sent, on the real screens, with invented answers and no network: the
-- buttons beside the received ones, canceling, and a challenge declined or accepted.
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=... tools/koreader/run_headless.sh tools/koreader/check_challenges.lua
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
local Home = require("ink_knight/ui/home")
local I18n = require("ink_knight/i18n")
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
-- The real network layer, with children that answer at once. answers[path] = { code, body }.
local answers, asked = {}, {}
local real_new = Net.new
Net.new = function(opts)
    local next_pid = 0
    opts.ca_file = ca_file
    opts.done = function() return true end
    opts.kill = function() end
    opts.spawn = function(spec)
        local path = spec.url:gsub("^https://[^/]+", ""):gsub("%?.*$", "")
        asked[#asked + 1] = path
        local answer = answers[path] or answers.default
        write(spec.code_path, tostring(answer[1]))
        write(spec.out_path, answer[2] or "")
        next_pid = next_pid + 1
        return next_pid
    end
    return real_new(opts)
end

local function run_network(home)
    for _ = 1, 12 do
        if home.net then
            home.net:tick()
        end
    end
end

local function challenge(id, from, to, extra)
    local item = { id = id, challenger = { id = from, name = from }, destUser = to and { id = to:lower(), name = to } or nil,
        timeControl = { type = "correspondence", daysPerTurn = 3 } }
    for key, value in pairs(extra or {}) do
        item[key] = value
    end
    return { type = "challenge", challenge = item }
end

local function buttons_row(home)
    for _, line in ipairs(home.hub.lines) do
        if line.kind == "buttons" then
            return line
        end
    end
end

local function top_page(home)
    return home.pages[#home.pages]
end

local function connected_home()
    answers = { ["/api/account"] = { 200, '{"id":"reader","username":"Reader"}' }, ["/api/account/playing"] = { 200, '{"nowPlaying":[]}' }, default = { 200, "{}" } }
    local home = Home:new{ version = "0" }
    UIManager:show(home)
    assert(home.token_store:save("lip_" .. string.rep("0", 20)))
    home.token = "lip_" .. string.rep("0", 20)
    home:open_hub()
    run_network(home)
    return home
end

local home = connected_home()
local s = home.strings
check(home.my_id == "reader", "the account should load")
check(buttons_row(home) == nil, "no challenge buttons with no challenges")

-- A sent challenge alone takes the whole line, as a bordered button.
home:on_event(challenge("sent0001", "reader", "Friend"))
local row = buttons_row(home)
check(row and #row.items == 1 and not row.items[1].primary, "one sent challenge: one bordered button")
check(row and row.items[1].text == string.format(s.sent_challenges, 1), "the button should count the sent one")

-- With a received one too, both share the line, the received one first and in black.
home:on_event(challenge("recv0001", "someone", "Reader"))
row = buttons_row(home)
check(row and #row.items == 2, "both should share one line")
check(row and row.items[1].primary and row.items[1].text == string.format(s.challenges, 1), "received first, in black")
check(row and not row.items[2].primary and row.items[2].text == string.format(s.sent_challenges, 1), "sent second, bordered")

-- Every label fits in half a line in the three languages, even with two digits.
for _, language in ipairs({ "pt", "en", "es" }) do
    local strings = I18n[language]
    local width = math.floor((home.hub.width - 2 * home.hub:px(16) - home.hub:px(8)) / 2) - 2 * home.hub:px(10)
    for _, label in ipairs({ string.format(strings.challenges, 12), string.format(strings.sent_challenges, 12) }) do
        local size = home.hub:fitting_size(label, "noto/NotoSans-Bold.ttf", 20, 14, width)
        check(size > 14, language .. ": '" .. label .. "' would need less than the smallest size")
        print(language, label, "size", size)
    end
end
home.hub:paintTo(Screen.bb, 0, 0)
Screen.bb:writePNG(out_dir .. "/challenges_both.png")

-- The page of sent challenges, and canceling one.
home:on_event(challenge("sent0002", "reader", "Other", { rematchOf = "game0001" }))
home:sent_menu()
local page = top_page(home)
check(page and page.title == s.sent_challenges_title, "the page of sent challenges should open")
check(page and #page.lines == 2, "it should list both sent challenges")
local rematch_line
for _, line in ipairs(page.lines) do
    if line.text == "Other" then
        rematch_line = line
    end
end
check(rematch_line and rematch_line.detail:find(s.rematch, 1, true), "a rematch should say so")
page:paintTo(Screen.bb, 0, 0)
Screen.bb:writePNG(out_dir .. "/challenges_sent.png")
rematch_line.callback()
local question = top_page(home)
check(question and question.title == string.format(s.cancel_challenge_question, "Other"), "canceling should ask first")
answers["/api/challenge/sent0002/cancel"] = { 200, '{"ok":true}' }
asked = {}
for _, line in ipairs(question.lines) do
    if line.kind == "primary" then
        UIManager:close(question)
        line.callback()
    end
end
run_network(home)
check(asked[1] == "/api/challenge/sent0002/cancel", "the cancel should go to Lichess, asked: " .. tostring(asked[1]))
check(home.sent.sent0002 == nil, "the canceled challenge should leave the list")
check(#page.lines == 1, "the page should show the one left")

-- Already answered: Lichess says 404, and it leaves the list all the same.
answers["/api/challenge/sent0001/cancel"] = { 404, '{"error":"Not found"}' }
home:ask_cancel_challenge(home.sent.sent0001, "Friend", function() end)
question = top_page(home)
for _, line in ipairs(question.lines) do
    if line.kind == "primary" then
        UIManager:close(question)
        line.callback()
    end
end
run_network(home)
check(home.sent.sent0001 == nil, "a challenge already gone should leave the list")
UIManager:close(page)

-- Declined and accepted challenges leave the list by themselves.
home:on_event(challenge("sent0003", "reader", "Friend"))
home:on_event(challenge("sent0004", "reader", "Friend"))
home:on_event({ type = "challengeDeclined", challenge = { id = "sent0003", destUser = { name = "Friend" } } })
check(home.sent.sent0003 == nil, "a declined challenge should leave the list")
home:on_event({ type = "gameStart", game = { gameId = "sent0004" } })
check(home.sent.sent0004 == nil, "an accepted challenge should leave the list")
row = buttons_row(home)
check(row and #row.items == 1 and row.items[1].primary, "only the received one should be left, full width")

-- When the stream opens again, after a sleep or a dropped connection, the lists start over: Lichess sends what is
-- still pending, and a challenge declined meanwhile does not stay behind.
home:on_event(challenge("sent0005", "reader", "Friend"))
check(home.sent.sent0005 ~= nil, "the challenge should be listed")
-- The invented children end at once, so the stream may be closed already, as after a dropped connection.
if home.events then
    home.net:close_stream(home.events)
    home.events = nil
end
home:open_events()
check(next(home.sent) == nil and next(home.challenges) == nil, "reopening the stream should start the lists over")
home:on_event(challenge("recv0001", "someone", "Reader"))
check(home.challenges.recv0001 ~= nil, "what Lichess sends again should come back")

-- With the token refused, the challenge buttons stay in place, in gray, and do not answer.
home:on_event(challenge("sent0006", "reader", "Friend"))
home:on_token_rejected()
row = buttons_row(home)
check(row and #row.items == 2, "both buttons should stay in place")
for _, item in ipairs(row and row.items or {}) do
    check(item.disabled and item.callback == nil, "a challenge button should be disabled: " .. tostring(item.text))
end
home.hub:paintTo(Screen.bb, 0, 0)
Screen.bb:writePNG(out_dir .. "/challenges_disabled.png")
local x = home.hub:px(16) + 5
local inside = Screen.bb:getPixel(x, row and (function()
    local y = home.hub:content_top()
    for _, line in ipairs(home.hub.sheets[home.hub.sheet]) do
        if line == row then
            return y + 20
        end
        y = y + home.hub.heights_of[line]
    end
end)() or 0):getColor8().a
check(inside > 0x80, "a disabled received button should not be painted black, got gray " .. inside)
home.token_rejected = nil

-- On the bar of a game, an anonymous white side is called anonymous, not by the name of black.
local LiveGame = require("ink_knight/ui/live_game")
local fake = { s = s, game = {
    white_name = nil, black_name = "Reader",
    rating_text = function() return nil end, clock_text = function() return nil end,
    is_active = function() return false end, position = { turn = "w" },
} }
check(LiveGame.player_info(fake, "w").name == s.anonymous, "white should be anonymous, got " .. LiveGame.player_info(fake, "w").name)
check(LiveGame.player_info(fake, "b").name == "Reader", "black should keep its name")

-- Leaving the online part forgets them, and the stream sends them again on the way back.
UIManager:close(home.hub)
check(next(home.sent) == nil and next(home.challenges) == nil, "leaving should forget the challenges")
home:forget_token()
UIManager:close(home)

os.remove(ca_file)
if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("challenges: everything as expected")
os.exit(0)
