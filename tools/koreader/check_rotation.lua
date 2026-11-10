-- Pattern "portrait". This file is copied unchanged into every
-- plugin as tools/koreader/check_rotation.lua: change the pattern first, then copy it again.
--
-- Opens every full-screen window of the plugin with KOReader in landscape and checks that it turns to portrait,
-- ignores rotation while open and gives the landscape mode back on close. Then opens it with an empty folder in
-- place of the plugin folder and checks that a failed opening also gives the rotation back.
-- The plugin id is the folder that holds portrait.lua; the windows are the modules with "covers_fullscreen = true".
-- Each window is opened with { plugin_dir = <folder> }. A plugin whose windows need more fields, or that has a
-- window this scan misses or should skip, writes tools/koreader/rotation_cases.lua, which returns a table:
--   ["<id>/ui/screen"] = function(plugin_dir) return { plugin_dir = plugin_dir, other = ... } end,
--   ["<id>/ui/base"] = "base class, never opened by itself",   -- a string skips the module and says why
-- Usage: KOREADER_DIR=<desktop KOReader> tools/koreader/run_headless.sh tools/koreader/check_rotation.lua
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))
local out_dir = assert(os.getenv("OUTPUT_DIR"))

require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path

local lfs = require("libs/libkoreader-lfs")
local Device = require("device")
local Screen = Device.screen
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
UIManager:init()

local LANDSCAPE = Screen.DEVICE_ROTATED_CLOCKWISE
local problems = 0

local function problem(message)
    problems = problems + 1
    print("PROBLEM " .. message)
end

local function read(path)
    local file = io.open(path, "r")
    if not file then
        return ""
    end
    local text = file:read("*a")
    file:close()
    return text
end

local function first_line(text)
    return (tostring(text):match("^[^\n]*"))
end

local function portrait()
    return Screen:getWidth() <= Screen:getHeight()
end

-- The plugin id: the folder with the pattern module.
local id
for entry in lfs.dir(plugin_dir) do
    if entry:sub(1, 1) ~= "." and read(plugin_dir .. "/" .. entry .. "/portrait.lua"):find('Pattern "portrait"', 1, true) then
        id = entry
    end
end
if not id then
    print("FAILED no <id>/portrait.lua from the pattern in " .. plugin_dir)
    os.exit(1)
end

local cases = {}
local cases_file = plugin_dir .. "/tools/koreader/rotation_cases.lua"
if lfs.attributes(cases_file, "mode") == "file" then
    cases = dofile(cases_file)
end

-- Modules that declare a full-screen window, plus the ones named in the cases.
local modules, seen = {}, {}
local function add(module)
    if not seen[module] then
        seen[module] = true
        modules[#modules + 1] = module
    end
end
local function scan(dir, module)
    for entry in lfs.dir(dir) do
        if entry:sub(1, 1) ~= "." then
            local path = dir .. "/" .. entry
            if lfs.attributes(path, "mode") == "directory" then
                scan(path, module .. "/" .. entry)
            elseif entry:match("%.lua$") and read(path):find("covers_fullscreen%s*=%s*true") then
                add(module .. "/" .. entry:gsub("%.lua$", ""))
            end
        end
    end
end
scan(plugin_dir .. "/" .. id, id)
for module in pairs(cases) do
    add(module)
end
table.sort(modules)
if #modules == 0 then
    problem("no full-screen window found in " .. id)
end

local empty_dir = out_dir .. "/empty_plugin"
lfs.mkdir(empty_dir)

-- Whether an opening turned the screen upright, to tell a failed opening that gave the rotation back from one
-- that failed before turning anything.
local turned = false
local set_rotation = Screen.setRotationMode
Screen.setRotationMode = function(self, mode)
    if mode % 2 == 0 then
        turned = true
    end
    return set_rotation(self, mode)
end

local function create(module, dir)
    return pcall(function()
        local class = require(module)
        local case = cases[module]
        local fields = type(case) == "function" and case(dir) or { plugin_dir = dir }
        return class:new(fields)
    end)
end

local initial_rotation = Screen:getRotationMode()
for _, module in ipairs(modules) do
    local case = cases[module]
    if type(case) == "string" then
        print("skipped " .. module .. ": " .. case)
    else
        local before = problems
        Screen:setRotationMode(LANDSCAPE)
        local ok, window = create(module, plugin_dir)
        if not ok then
            problem(module .. " could not be opened: " .. first_line(window))
        else
            if not portrait() then
                problem(module .. " opened in landscape and did not turn to portrait")
            end
            if not (window.onSetRotationMode and window:onSetRotationMode(LANDSCAPE)) or not portrait() then
                problem(module .. " did not ignore a rotation while open")
            end
            if window.onCloseWidget then
                window:onCloseWidget()
            end
            if Screen:getRotationMode() ~= LANDSCAPE then
                problem(module .. " did not give the landscape mode back on close")
            end
        end
        Screen:setRotationMode(LANDSCAPE)
        turned = false
        if create(module, empty_dir) then
            print("not tested " .. module .. ": it opens without the plugin files, so a failed opening was not tried")
        elseif Screen:getRotationMode() ~= LANDSCAPE then
            problem(module .. " left the screen in portrait after a failed opening")
        elseif not turned then
            print("not tested " .. module .. ": without the plugin files it failed before turning the screen, so giving the rotation back was not tried")
        end
        if problems == before then
            print("ok " .. module)
        end
    end
end
Screen:setRotationMode(initial_rotation)

print(problems == 0 and "rotation: ok" or ("rotation: " .. problems .. " problem(s)"))
os.exit(problems == 0 and 0 or 1)
