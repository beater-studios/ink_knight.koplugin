-- Pattern "sleep". This file is copied unchanged into every
-- plugin that has the pattern, as <id>/sleep.lua: change the pattern first, then copy it again.
--
-- Keeps a full-screen window from drawing and from running its timers while the device sleeps. KOReader
-- sends Suspend to every open window before the device sleeps and Resume after it wakes up, but the system
-- can wake up for a moment in between without turning the screen on, and KOReader then runs every timer
-- that came due. A timer that draws or shows something at that moment paints over the sleep screen.
--
--   Sleep.watch(window)                    once, in init: follows Suspend, Resume and the window closing
--   Sleep.schedule(window, seconds, fn, ...) like UIManager:scheduleIn; due while asleep, fn waits for Resume
--   Sleep.unschedule(window, fn)           cancels fn (a waiting call too); with no fn, everything
--   Sleep.dirty(window, ...)               UIManager:setDirty(window, ...) awake; asleep, a full repaint on Resume
--   Sleep.show(window, widget, ...)        UIManager:show(widget, ...) awake; asleep, shown on Resume
--   Sleep.asleep(window)                   true from Suspend until the sleep screen is gone after Resume
-- With a delay to close the sleep screen (screensaver_delay: a tap, a gesture or some seconds), Resume comes while
-- the sleep screen is still up: the waiting calls are then released on OutOfScreenSaver, or when the sleep screen
-- is gone without it.
local Device = require("device")
local UIManager = require("ui/uimanager")

local POLL_SECONDS = 1

local Sleep = {}

local function state_of(window)
    return assert(window._sleep, "sleep: call Sleep.watch(window) in init first")
end

local function release(window, state)
    UIManager:unschedule(state.poll)
    state.asleep, state.waking = false, false
    local waiting = state.waiting
    state.waiting = {}
    for _, call in ipairs(waiting) do
        if call.widget then
            UIManager:show(call.widget, unpack(call.args, 1, call.args.n))
        else
            call.fn(unpack(call.args, 1, call.args.n))
        end
    end
    if state.repaint then
        state.repaint = false
        UIManager:setDirty(window, "full")
    end
end

-- The window keeps its own onSuspend, onResume, onOutOfScreenSaver and onCloseWidget: they still run, after the
-- module's part on Suspend and before it on Resume, so the window has woken up before the waiting calls run.
function Sleep.watch(window)
    if window._sleep then
        return
    end
    local state = { asleep = false, waking = false, tasks = {}, waiting = {}, repaint = false }
    window._sleep = state
    state.poll = function()
        if not state.waking then
            return
        end
        if Device.screen_saver_mode then
            UIManager:scheduleIn(POLL_SECONDS, state.poll)
        else
            release(window, state)
        end
    end
    local on_suspend, on_resume = window.onSuspend, window.onResume
    local on_out, on_close = window.onOutOfScreenSaver, window.onCloseWidget
    window.onSuspend = function(self, ...)
        state.asleep, state.waking = true, false
        UIManager:unschedule(state.poll)
        if on_suspend then
            return on_suspend(self, ...)
        end
    end
    window.onResume = function(self, ...)
        local result
        if on_resume then
            result = on_resume(self, ...)
        end
        UIManager:unschedule(state.poll)
        if Device.screen_saver_mode then
            state.waking = true
            UIManager:scheduleIn(POLL_SECONDS, state.poll)
        else
            release(self, state)
        end
        return result
    end
    window.onOutOfScreenSaver = function(self, ...)
        if state.waking then
            release(self, state)
        end
        if on_out then
            return on_out(self, ...)
        end
    end
    window.onCloseWidget = function(self, ...)
        Sleep.unschedule(self)
        state.waking = false
        UIManager:unschedule(state.poll)
        if on_close then
            return on_close(self, ...)
        end
    end
end

function Sleep.asleep(window)
    return state_of(window).asleep
end

local function drop_waiting(state, fn)
    for i = #state.waiting, 1, -1 do
        if fn == nil or state.waiting[i].fn == fn then
            table.remove(state.waiting, i)
        end
    end
end

-- Scheduling fn again replaces the call already scheduled, as a clock that reschedules itself expects.
function Sleep.schedule(window, seconds, fn, ...)
    local state = state_of(window)
    Sleep.unschedule(window, fn)
    local args = table.pack(...)
    local task
    task = function()
        if state.tasks[fn] ~= task then
            return
        end
        state.tasks[fn] = nil
        if state.asleep then
            state.waiting[#state.waiting + 1] = { fn = fn, args = args }
        else
            fn(unpack(args, 1, args.n))
        end
    end
    state.tasks[fn] = task
    UIManager:scheduleIn(seconds, task)
end

function Sleep.unschedule(window, fn)
    local state = state_of(window)
    if fn == nil then
        for _, task in pairs(state.tasks) do
            UIManager:unschedule(task)
        end
        state.tasks = {}
    elseif state.tasks[fn] then
        UIManager:unschedule(state.tasks[fn])
        state.tasks[fn] = nil
    end
    drop_waiting(state, fn)
end

function Sleep.dirty(window, ...)
    local state = state_of(window)
    if state.asleep then
        state.repaint = true
        return
    end
    UIManager:setDirty(window, ...)
end

function Sleep.show(window, widget, ...)
    local state = state_of(window)
    if state.asleep then
        state.waiting[#state.waiting + 1] = { widget = widget, args = table.pack(...) }
        return
    end
    UIManager:show(widget, ...)
end

return Sleep
