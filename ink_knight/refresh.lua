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

-- kind names what is on the screen (a layout, a pane). The same kind again is a change inside it and gets
-- "ui"; a new kind, or the update after `limit` of them, gets "full".
function Refresh:mode(kind)
    if kind ~= nil and kind == self.kind and self.count < self.limit then
        self.count = self.count + 1
        return "ui"
    end
    self.kind, self.count = kind, 0
    return "full"
end

-- The next update is full, whatever its kind: for when something else covered the screen, such as a dialog
-- or the sleep screen.
function Refresh:reset()
    self.kind, self.count = nil, 0
end

return Refresh
