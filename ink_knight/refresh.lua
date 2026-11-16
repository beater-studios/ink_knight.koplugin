-- Pattern "eink_refresh". This file is copied unchanged
-- into every plugin, as <id>/refresh.lua: change the pattern first, then copy it again.
--
-- Chooses between an update without a flash ("ui") and a full one ("full"). KOReader only counts "partial"
-- refreshes towards its periodic flash, never "ui", so a plugin that uses "ui" has to count them itself.
local Refresh = {}
Refresh.__index = Refresh

-- limit: how many updates without a flash may follow each other before a full one clears the ghosting.
function Refresh.new(limit)
    return setmetatable({ limit = limit or 8, count = 0 }, Refresh)
end

-- A flash takes about a second on a Kindle, and an update without one sent while it runs collides with it and is lost, leaving its part of the screen white until something draws there again. So the first update without a flash in the seconds after one waits for the flash to end. settle takes the mode of every update the plugin sends, the ones from mode() included; called where KOReader reads the mode (a function passed to setDirty), the update sent last is the flash. On a computer, or without KOReader, it only returns the mode.
local SETTLE_SECONDS = 2
local FLASHES = { full = true, flashui = true, flashpartial = true }
local flashed_at

function Refresh.settle(mode)
    local ok, time = pcall(require, "ui/time")
    if not ok then
        return mode
    end
    local now = time.now()
    if FLASHES[mode] then
        flashed_at = now
    elseif flashed_at then
        if now - flashed_at < time.s(SETTLE_SECONDS) then
            require("device").screen:refreshWaitForLast()
        end
        flashed_at = nil
    end
    return mode
end

-- kind names what is on the screen (a layout, a pane). The same kind again is a change inside it and gets
-- "ui"; a new kind, or the update after `limit` of them, gets "full".
function Refresh:mode(kind)
    if kind ~= nil and kind == self.kind and self.count < self.limit then
        self.count = self.count + 1
        return Refresh.settle("ui")
    end
    self.kind, self.count = kind, 0
    return Refresh.settle("full")
end

-- The next update is full, whatever its kind: for when something else covered the screen, such as a dialog
-- or the sleep screen.
function Refresh:reset()
    self.kind, self.count = nil, 0
end

return Refresh
