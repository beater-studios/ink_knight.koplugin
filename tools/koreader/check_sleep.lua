-- Pattern "sleep". This file is copied unchanged into every
-- plugin that has the pattern, as tools/koreader/check_sleep.lua: change the pattern first, then copy it again.
--
-- Opens every full-screen window of the plugin, sends Suspend and puts a stand-in sleep screen on top as KOReader
-- does, runs every timer as a wakeup of the system would, and checks that the plugin asks for no paint and shows
-- nothing. A timer that keeps scheduling itself is only noted. Then sends Resume and checks that the window still
-- works.
-- The plugin id is the folder that holds sleep.lua; the windows are the modules with "covers_fullscreen = true",
-- each opened with { plugin_dir = <folder> }. A window whose timers only start in some state (a match with a
-- clock) needs that state: the plugin writes tools/koreader/sleep_cases.lua, which returns a table:
--   ["table with a clock"] = function(plugin_dir) local s = Screen:new{ ... }; s:start(); return s end,
--   ["<id>/ui/base"] = "base class, never opened by itself",   -- a string skips the module and says why
-- A case with a module name replaces the scan for that module.
-- Usage: KOREADER_DIR=<desktop KOReader> tools/koreader/run_headless.sh tools/koreader/check_sleep.lua
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))

require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path

local lfs = require("libs/libkoreader-lfs")
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
UIManager:init()
local Event = require("ui/event")
local InputContainer = require("ui/widget/container/inputcontainer")

local ROUNDS = 5
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

-- The plugin id: the folder with the pattern module.
local id
for entry in lfs.dir(plugin_dir) do
    if entry:sub(1, 1) ~= "." and read(plugin_dir .. "/" .. entry .. "/sleep.lua"):find('Pattern "sleep"', 1, true) then
        id = entry
    end
end
if not id then
    print("FAILED no <id>/sleep.lua from the pattern in " .. plugin_dir)
    os.exit(1)
end

local cases = {}
local cases_file = plugin_dir .. "/tools/koreader/sleep_cases.lua"
if lfs.attributes(cases_file, "mode") == "file" then
    cases = dofile(cases_file)
end

local names, seen = {}, {}
local function add(name)
    if not seen[name] then
        seen[name] = true
        names[#names + 1] = name
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
for name in pairs(cases) do
    add(name)
end
table.sort(names)
if #names == 0 then
    problem("no full-screen window found in " .. id)
end

-- What the plugin draws or shows, recorded while the device sleeps, and the widgets asked to paint while
-- "painted" is a table.
local asleep, drawn, painted = false, {}, nil
local function label(widget)
    return tostring(type(widget) == "table" and (widget.name or "a widget") or widget)
end
local set_dirty, show = UIManager.setDirty, UIManager.show
UIManager.setDirty = function(self, widget, ...)
    if asleep then
        drawn[#drawn + 1] = "setDirty(" .. label(widget) .. ")"
    end
    if painted then
        painted[#painted + 1] = widget
    end
    return set_dirty(self, widget, ...)
end
UIManager.show = function(self, widget, ...)
    if asleep then
        drawn[#drawn + 1] = "show(" .. label(widget) .. ")"
    end
    return show(self, widget, ...)
end
for _, name in ipairs({ "widgetRepaint", "widgetInvert" }) do
    local original = UIManager[name]
    UIManager[name] = function(self, widget, ...)
        if asleep then
            drawn[#drawn + 1] = name .. "(" .. label(widget) .. ")"
        end
        return original(self, widget, ...)
    end
end
local Screen = Device.screen
for _, name in ipairs({ "refreshFull", "refreshPartial", "refreshNoMergePartial", "refreshFlashPartial", "refreshUI",
    "refreshNoMergeUI", "refreshFlashUI", "refreshFast", "refreshA2" }) do
    local original = Screen[name]
    if original then
        Screen[name] = function(...)
            if asleep then
                drawn[#drawn + 1] = "Screen:" .. name
            end
            return original(...)
        end
    end
end

-- Runs every scheduled task once, as KOReader does when it wakes up after they came due, in KOReader's order
-- (the queue is sorted with the next task last). Returns the errors.
local function run_due()
    local queue = UIManager._task_queue
    UIManager._task_queue = {}
    local errors = {}
    for i = #queue, 1, -1 do
        local task = queue[i]
        local ok, err = pcall(task.action, unpack(task.args, 1, task.args.n))
        if not ok then
            errors[#errors + 1] = first_line(err)
        end
    end
    return errors, #queue
end

-- The module itself, on a stand-in window.
do
    local Sleep = require(id .. "/sleep")
    local function check(label, ok)
        if not ok then
            problem("module: " .. label)
        end
    end
    local calls, closed, resumed = {}, false, false
    local window = InputContainer:new{ name = id .. "_sleep_check", covers_fullscreen = true }
    function window:onResume()
        resumed = true
    end
    function window:onCloseWidget()
        closed = true
    end
    Sleep.watch(window)
    Sleep.watch(window)
    UIManager:show(window)
    local function tick(label)
        calls[#calls + 1] = label
    end
    Sleep.schedule(window, 1, tick, "a")
    Sleep.schedule(window, 1, tick, "b")
    run_due()
    check("scheduling again replaces the call", table.concat(calls, ",") == "b")
    UIManager:forceRePaint()
    UIManager:broadcastEvent(Event:new("Suspend"))
    check("asleep after Suspend", Sleep.asleep(window))
    Sleep.schedule(window, 1, tick, "c")
    asleep, drawn = true, {}
    run_due()
    Sleep.dirty(window, "ui")
    Sleep.show(window, InputContainer:new{ name = "held" })
    asleep = false
    check("nothing drawn while asleep (" .. table.concat(drawn, ", ") .. ")", #drawn == 0)
    check("a timer due while asleep waits", #calls == 1)
    painted = {}
    UIManager:broadcastEvent(Event:new("Resume"))
    local repainted = false
    for _, widget in ipairs(painted) do
        repainted = repainted or widget == window
    end
    painted = nil
    check("the window's own onResume runs", resumed)
    check("the waiting timer runs on Resume", calls[2] == "c")
    local held_shown = false
    for i = 1, #UIManager._window_stack do
        if UIManager._window_stack[i].widget.name == "held" then
            held_shown = true
            UIManager:close(UIManager._window_stack[i].widget)
            break
        end
    end
    check("a widget shown while asleep appears on Resume", held_shown)
    check("a skipped paint becomes a repaint on Resume", repainted)
    check("awake after Resume", not Sleep.asleep(window))

    -- A delay to close the sleep screen: Resume comes while it is still up.
    local saver_mode = Device.screen_saver_mode
    UIManager:broadcastEvent(Event:new("Suspend"))
    Sleep.schedule(window, 1, tick, "e")
    run_due()
    Device.screen_saver_mode = true
    asleep, drawn = true, {}
    UIManager:broadcastEvent(Event:new("Resume"))
    run_due()
    asleep = false
    check("nothing drawn while the sleep screen stays up after Resume (" .. table.concat(drawn, ", ") .. ")", #drawn == 0)
    check("a timer waits while the sleep screen stays up after Resume", calls[#calls] ~= "e" and Sleep.asleep(window))
    UIManager:broadcastEvent(Event:new("OutOfScreenSaver"))
    check("OutOfScreenSaver after Resume releases the waiting timer", calls[#calls] == "e" and not Sleep.asleep(window))
    UIManager:broadcastEvent(Event:new("Suspend"))
    Sleep.schedule(window, 1, tick, "f")
    run_due()
    UIManager:broadcastEvent(Event:new("Resume"))
    Device.screen_saver_mode = false
    run_due()
    check("the sleep screen gone without OutOfScreenSaver releases the waiting timer", calls[#calls] == "f")
    Device.screen_saver_mode = saver_mode
    local count = #calls
    Sleep.schedule(window, 1, tick, "d")
    UIManager:close(window)
    run_due()
    check("the window's own onCloseWidget runs", closed)
    check("closing cancels the timers", #calls == count)
    UIManager:forceRePaint()
    UIManager._task_queue = {}
    print(problems == 0 and "ok module" or "module: problems above")
end

local function open(name)
    local case = cases[name]
    if type(case) == "function" then
        return case(plugin_dir)
    end
    local class = require(name)
    return class:new{ plugin_dir = plugin_dir }
end

for _, name in ipairs(names) do
    local case = cases[name]
    if type(case) == "string" then
        print("skipped " .. name .. ": " .. case)
    else
        local before = problems
        local ok, window = pcall(open, name)
        if not ok then
            problem(name .. " could not be opened: " .. first_line(window))
        else
            if not UIManager:isWidgetShown(window) then
                UIManager:show(window)
            end
            UIManager:forceRePaint()
            UIManager:broadcastEvent(Event:new("Suspend"))
            local sleep_screen = InputContainer:new{ name = "ScreenSaver", covers_fullscreen = true }
            UIManager:show(sleep_screen, "full")
            UIManager:forceRePaint()
            asleep, drawn = true, {}
            local left = 0
            for _ = 1, ROUNDS do
                local errors
                errors, left = run_due()
                for _, err in ipairs(errors) do
                    problem(name .. ": a timer failed while asleep: " .. err)
                end
                if left == 0 then
                    break
                end
            end
            asleep = false
            if #drawn > 0 then
                problem(name .. " asked for a paint while asleep: " .. table.concat(drawn, ", "))
            end
            if left > 0 then
                print("note " .. name .. ": a timer still schedules itself after " .. ROUNDS .. " wakeups while asleep")
            end
            UIManager:close(sleep_screen)
            UIManager:broadcastEvent(Event:new("Resume"))
            for _, err in ipairs((run_due())) do
                problem(name .. ": a timer failed after Resume: " .. err)
            end
            local drew, err = pcall(UIManager.forceRePaint, UIManager)
            if not drew then
                problem(name .. " could not be drawn after Resume: " .. first_line(err))
            end
            UIManager:close(window)
            UIManager:forceRePaint()
            UIManager._task_queue = {}
        end
        if problems == before then
            print("ok " .. name)
        end
    end
end

print(problems == 0 and "sleep: ok" or ("sleep: " .. problems .. " problem(s)"))
os.exit(problems == 0 and 0 or 1)
