-- Goes through what happens when Lichess refuses the token, on the real screens, with invented answers and no network.
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=... tools/koreader/run_headless.sh tools/koreader/check_token_rejected.lua
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

local s = I18n.en
-- Built in parts, because a whole value in this shape looks like a real token to secret scanners.
local TOKEN = "lip_" .. string.rep("0", 20)
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
local answers = {}
local real_new = Net.new
Net.new = function(opts)
    local next_pid = 0
    opts.ca_file = ca_file
    opts.is_done = function() return true end
    opts.kill = function() end
    opts.spawn = function(spec)
        local path = spec.url:gsub("^https://[^/]+", ""):gsub("%?.*$", "")
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

local function hits_of(page)
    page:paintTo(Screen.bb, 0, 0)
    return page.hits
end

local function new_home()
    local home = Home:new{ version = "0" }
    UIManager:show(home)
    return home
end

local function save_token(home)
    assert(home.token_store:save(TOKEN))
    home.token = TOKEN
end

local function top_page(home)
    return home.pages[#home.pages]
end

-- The token is already refused when the online part opens.
do
    answers = { default = { 401 } }
    local home = new_home()
    save_token(home)
    home:open_hub()
    run_network(home)
    check(home.token_rejected == true, "the refused token should be noticed")
    local hits = hits_of(home.hub)
    check(#hits == 2, "only the way back and the row should answer, got " .. #hits)
    local rows = home.hub.lines
    check(rows[1].text == s.bad_token_short, "the first row should say the token was refused")
    check(rows[1].detail == s.tap_to_connect_again, "the first row should say what a tap does")
    for index = 2, #rows do
        if rows[index].kind == "tile_line" then
            for _, item in ipairs(rows[index].items) do
                check(item.disabled == true and item.callback == nil, "the tile " .. tostring(item.text) .. " should be disabled")
            end
        else
            check(rows[index].disabled == true, "row " .. index .. " should be disabled")
        end
    end
    home.hub:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/token_refused.png")
    check(home.token_store:load() == TOKEN, "the token should stay until the reader goes to connect again")

    local requests_before = home.net.serial
    home:reload_games()
    home:open_events()
    run_network(home)
    check(home.net.serial == requests_before, "nothing more should go to Lichess with a refused token")

    hits[#hits].callback()
    check(home.token_store:load() == nil, "the refused token should be gone")
    check(home.token == nil, "the first page should know there is no token")
    check(home.hub == nil, "the online part should be closed")
    check(home.net == nil, "the network should be stopped")
    check(home.token_rejected == nil, "the state should not outlive the online part")
    check(top_page(home) and top_page(home).title == s.connect, "the page for connecting should be on top")
    check(home:build_rows()[2].text == s.connect, "the first page should offer connecting")
    home.pages[#home.pages]:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/token_connect.png")
    UIManager:close(top_page(home))
    UIManager:close(home)

    -- Leaving without connecting, and opening again.
    local reopened = new_home()
    check(reopened.token == nil, "opening again should find no token")
    check(reopened:build_rows()[2].text == s.connect, "opening again should offer connecting")

    -- A new token works again.
    answers = { ["/api/account"] = { 200, '{"id":"reader","username":"Reader"}' }, ["/api/account/playing"] = { 200, '{"nowPlaying":[]}' }, default = { 200, "{}" } }
    reopened:accept_token(TOKEN)
    run_network(reopened)
    check(reopened.token_rejected == nil, "a new token should not be blocked")
    check(reopened.my_id == "reader", "a new token should load the account")
    check(#hits_of(reopened.hub) > 2, "with a good token the buttons should answer")
    UIManager:close(reopened.hub)
    UIManager:close(reopened)
end

-- The token stops working in the middle of the session, with a page open over the hub.
do
    answers = { ["/api/account"] = { 200, '{"id":"reader","username":"Reader"}' }, ["/api/account/playing"] = { 200, '{"nowPlaying":[{"gameId":"abcd1234","isMyTurn":true,"opponent":{"username":"Other"},"secondsLeft":60}]}' }, default = { 200, "{}" } }
    local home = new_home()
    save_token(home)
    home:open_hub()
    run_network(home)
    check(home.my_id == "reader", "the account should load")
    check(#home.games == 1, "the game should be listed")
    home:settings_menu()
    check(#home.pages == 1, "the settings should be open")
    answers = { default = { 401 } }
    home:reload_games()
    run_network(home)
    check(home.token_rejected == true, "a refusal from any request should count")
    check(#home.pages == 0, "the pages over the hub should close")
    local hits = hits_of(home.hub)
    check(#hits == 2, "the game should not answer either, got " .. #hits)
    UIManager:close(home.hub)
    check(home.token_rejected == nil, "leaving the online part should clear the state")
    check(home.token_store:load() == TOKEN, "leaving without tapping the row should keep the token")
    UIManager:close(home)
end

-- A network problem is not a refused token: it stays open and tries again.
do
    answers = { default = { 500 } }
    local home = new_home()
    save_token(home)
    home:open_hub()
    run_network(home)
    check(home.token_rejected == nil, "a server error should not count as a refused token")
    check(home.account_problem == s.action_failed, "a server error should be reported")
    check(#hits_of(home.hub) > 2, "a server error should not block the buttons")
    UIManager:close(home.hub)
    home:forget_token()
    UIManager:close(home)
end

os.remove(ca_file)
if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("token refused: everything as expected")
os.exit(0)
