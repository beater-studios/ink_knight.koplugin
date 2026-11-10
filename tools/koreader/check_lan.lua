-- Pattern "lan_server". This file is copied unchanged into
-- every plugin that has the pattern, as tools/koreader/check_lan.lua: change the pattern first.
--
-- Checks <id>/lan.lua inside the desktop KOReader, pretending to be a Kindle: the firewall commands it would
-- run are recorded instead. The plugin id is the folder that holds lan.lua.
-- Usage: KOREADER_DIR=<desktop KOReader> tools/koreader/run_headless.sh tools/koreader/check_lan.lua
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))

require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path

local lfs = require("libs/libkoreader-lfs")
local Device = require("device")

local id
for name in lfs.dir(plugin_dir) do
    if name:sub(1, 1) ~= "." and lfs.attributes(plugin_dir .. "/" .. name .. "/lan.lua", "mode") == "file" then
        id = name
    end
end
if not id then
    print("FAILED no <id>/lan.lua in " .. plugin_dir)
    os.exit(1)
end

local settings = DataStorage:getSettingsDir()
lfs.mkdir(settings)
local marker = settings .. "/" .. id .. ".firewall"
os.remove(marker)

-- A pretend iptables: the rules it holds, every command it ran and, when set, the exit code every command
-- gets instead, to stand for a failure other than "no such rule".
local rules, commands, forced = {}, {}, nil
local marker_before_add
os.execute = function(command)
    commands[#commands + 1] = command
    local action, spec = command:match("^iptables %-(%u) (.-) 2>/dev/null$")
    if forced then
        return forced * 256
    end
    if action == "A" then
        if marker_before_add == nil then
            marker_before_add = lfs.attributes(marker, "mode") == "file"
        end
        rules[#rules + 1] = spec
        return 0
    elseif action == "D" then
        for index, rule in ipairs(rules) do
            if rule == spec then
                table.remove(rules, index)
                return 0
            end
        end
        return 256
    end
    return 0
end
Device.isKindle = function() return true end

local failures = 0
local function check(name, ok)
    print((ok and "ok    " or "FAILED ") .. name)
    if not ok then
        failures = failures + 1
    end
end
local function exists(path)
    return lfs.attributes(path, "mode") == "file"
end
local function read_marker()
    local file = io.open(marker)
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

local Lan = require(id .. "/lan")

local token = Lan.random_token()
check("a code has 16 characters by default", token ~= nil and #token == 16)
check("a code uses only unambiguous characters", token ~= nil and token:match("^[a-hjkmnp-z2-9]+$") ~= nil)
check("a code of another length", #(Lan.random_token(24) or "") == 24)
local private = { ["10.1.2.3"] = true, ["172.16.0.1"] = true, ["172.31.9.9"] = true, ["192.168.0.5"] = true }
local public = { "172.15.0.1", "172.32.0.1", "192.169.0.1", "8.8.8.8", "fe80::1", "", "not an ip" }
local classified = true
for ip in pairs(private) do
    classified = classified and Lan.is_private_ip(ip)
end
for _, ip in ipairs(public) do
    classified = classified and not Lan.is_private_ip(ip)
end
check("private and public addresses are told apart", classified and not Lan.is_private_ip(nil))

local function rules_for(port)
    local n = 0
    for _, rule in ipairs(rules) do
        if rule:find("port " .. port .. " ", 1, true) then
            n = n + 1
        end
    end
    return n
end

check("the marker is outside the cache folder, which KOReader can empty", not marker:find("/cache/", 1, true))

rules = { "INPUT -s 10.0.0.0/8 -p tcp --dport 8642 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
    "INPUT -s 10.0.0.0/8 -p tcp --dport 9000 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT" }
local leftover = io.open(marker, "w")
leftover:write("8642\n9000\n")
leftover:close()
Lan.install(id)
check("after a crash, install closes every port listed", #rules == 0)
check("after a crash, install removes the marker", not exists(marker))
commands = {}
Lan.install(id)
check("install recovers only once", #commands == 0)

check("open: returns true", Lan.open_firewall(8642) == true)
check("open: the port is listed in the marker before any rule is added", marker_before_add == true)
check("open: lists the port in the marker", read_marker() == "8642\n")
local private_only = #rules == 6
for _, rule in ipairs(rules) do
    private_only = private_only and (rule:find("^INPUT %-s ") or rule:find("^OUTPUT %-d ")) ~= nil
end
check("open: rules only for the three private networks", private_only)
Lan.open_firewall(8642)
check("open twice: the port is listed once and the rules are not doubled", read_marker() == "8642\n" and rules_for(8642) == 6)
Lan.open_firewall(9000)
check("close: returns true", Lan.close_firewall(8642) == true)
check("close: keeps the other ports listed", read_marker() == "9000\n")
check("close: deletes the rules of that port", rules_for(8642) == 0 and rules_for(9000) == 6)

forced = 4
check("close while iptables fails: returns false", Lan.close_firewall(9000) == false)
forced = nil
check("close while iptables fails: the port stays in the marker", read_marker() == "9000\n" and rules_for(9000) == 6)
Lan.recovered = nil
Lan.install(id)
check("the next install closes the port that was left", rules_for(9000) == 0 and not exists(marker))

local real_execute = os.execute
os.execute = function(command)
    if command:find("^iptables %-A OUTPUT") then
        commands[#commands + 1] = command
        return 256
    end
    return real_execute(command)
end
check("open when a rule cannot be added: returns false", Lan.open_firewall(8642) == false)
check("open when a rule cannot be added: nothing stays open or listed", rules_for(8642) == 0 and not exists(marker))
os.execute = real_execute

lfs.mkdir(marker)
commands = {}
check("open when the marker cannot be written: returns false", Lan.open_firewall(8642) == false)
check("open when the marker cannot be written: no rule is added", rules_for(8642) == 0)
lfs.rmdir(marker)

Device.isKindle = function() return false end
commands = {}
check("outside the Kindle: open returns true", Lan.open_firewall(8642) == true)
check("outside the Kindle: runs no command and writes no marker", #commands == 0 and not exists(marker))

print(string.format("%s: %d failures", id, failures))
os.exit(failures == 0 and 0 or 1)
