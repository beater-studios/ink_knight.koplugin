-- Goes through the page that receives the token with real connections, using curl as the phone.
-- Usage: OUTPUT_DIR=/tmp/out KOREADER_DIR=... tools/koreader/run_headless.sh tools/koreader/check_token_page.lua
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))
local out_dir = assert(os.getenv("OUTPUT_DIR"))
require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
UIManager:init()
local util = require("ffi/util")
local I18n = require("ink_knight/i18n")
local TokenScreen = require("ink_knight/ui/token_screen")

local problems = 0
local function check(ok, text)
    if not ok then
        problems = problems + 1
        print("PROBLEM: " .. text)
    end
end
local received
local screen = TokenScreen:new{ strings = I18n.pt, port = tonumber(os.getenv("TOKEN_PORT")) or 8644, on_token = function(token) received = token end }
assert(screen.url, "the page did not start")
UIManager:show(screen)
screen:paintTo(Device.screen.bb, 0, 0)
Device.screen.bb:writePNG(out_dir .. "/token_waiting.png")

-- curl runs in the background, and this keeps the server turning until it answers.
local serial = 0
local function fetch(args)
    serial = serial + 1
    local prefix = string.format("%s/fetch%d", out_dir, serial)
    os.execute(string.format("( curl -s -m 8 -o %s.body -w '%%{http_code}' %s > %s.code; echo x > %s.done ) >/dev/null 2>&1 &", prefix, args, prefix, prefix))
    for _ = 1, 200 do
        screen.server:tick()
        local done = io.open(prefix .. ".done", "rb")
        if done then
            done:close()
            break
        end
        util.usleep(30000)
    end
    local function read(path)
        local file = io.open(path, "rb")
        if not file then return "" end
        local data = file:read("*a")
        file:close()
        return data
    end
    return tonumber(read(prefix .. ".code")), read(prefix .. ".body")
end
local url = screen.url
local base_host = url:match("^(http://[^/]+)")
local save = "'" .. url .. "save'"

local status = fetch("'" .. base_host .. "/wrongcode/'")
check(status == 404, "a wrong code should be a 404, got " .. tostring(status))
local body
status, body = fetch("'" .. url .. "'")
check(status == 200 and body:find(I18n.pt.confirm_heading, 1, true), "the first device should wait for approval")
check(screen.access.pending_ip ~= nil, "the device should be pending")
status = fetch("-X POST -d 'token=lip_abcdefgh123' " .. save)
check(status == 404, "a token before approval should be refused")
check(received == nil and screen.received == nil, "a token was taken before approval")
screen.confirm.ok_callback()
status, body = fetch("'" .. url .. "'")
check(status == 200 and body:find("<form", 1, true), "the approved device should see the form")
status = fetch("-X POST -H 'Origin: http://evil.example' -d 'token=lip_abcdefgh123' " .. save)
check(status == 404, "another origin should be refused")
status, body = fetch("-X POST -d 'token=nottoken' " .. save)
check(status == 200 and body:find(I18n.pt.token_invalid, 1, true), "a bad token should show the error")
check(screen.received == nil, "a bad token was taken")
status = fetch("-X POST -H 'Content-Length: 99999' -d 'x' " .. save)
check(status ~= 200, "an oversized body should be dropped")
status, body = fetch("-X POST -d 'token=lip_abcdefgh123' " .. save)
check(status == 200 and body:find(I18n.pt.token_saved_heading, 1, true), "the token should be accepted")
check(screen.received == "lip_abcdefgh123", "the token did not arrive")
check(not body:find("lip_abcdefgh123", 1, true), "the page echoed the token")
UIManager:close(screen)
check(screen.server == nil, "the server should stop on closing")
print("problems: " .. problems)
os.exit(problems == 0 and 0 or 1)
