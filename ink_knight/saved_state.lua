-- Pattern "saved_state". This file is copied unchanged into
-- every plugin that keeps state between openings, as <id>/saved_state.lua: change the pattern first, then
-- copy it again.
--
-- Reading back what an older version saved: fields added since then get their defaults, values that no
-- longer exist fall back, lists come back without holes, and a save that cannot be read is dropped instead
-- of breaking the opening. Plain Lua, no KOReader modules, so the engine tests can use it.
local SavedState = {}

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = copy(v)
    end
    return out
end
SavedState.copy = copy

-- A table with fields and no list part, such as { games = 0, best = { days = 0 } }.
local function is_record(t)
    return type(t) == "table" and next(t) ~= nil and #t == 0
end

-- The saved table over a copy of the defaults, field by field and level by level. A field missing from the
-- save, or saved with a different type, gets the default. Fields of the save that the defaults do not know
-- are kept. Lists and empty tables in the defaults are replaced whole by the saved value.
function SavedState.with_defaults(saved, defaults)
    if type(saved) ~= "table" then
        return copy(defaults)
    end
    local out = copy(saved)
    for k, default in pairs(defaults) do
        local value = saved[k]
        if value == nil or type(value) ~= type(default) then
            out[k] = copy(default)
        elseif is_record(default) then
            out[k] = SavedState.with_defaults(value, default)
        end
    end
    return out
end

-- A saved value from a closed list (a style, a size, a language): the value if it still exists, otherwise
-- the default. `allowed` is a list ({ "small", "large" }) or a set ({ small = true }). In a list, only the
-- items count, so a number saved by mistake never matches an index.
function SavedState.one_of(value, allowed, default)
    if value == nil then
        return default
    end
    if allowed[1] == nil then
        return allowed[value] == true and value or default
    end
    for _, item in ipairs(allowed) do
        if item == value then
            return value
        end
    end
    return default
end

-- Highest index read from a saved list without a size. A damaged save with a huge index would otherwise
-- build that many items while the screen opens.
SavedState.MAX_LIST = 10000

-- Highest whole positive index of `t`, up to MAX_LIST.
local function last_index(t)
    local size = 0
    for k in pairs(t) do
        if type(k) == "number" and k % 1 == 0 and k > size and k <= SavedState.MAX_LIST then
            size = k
        end
    end
    return size
end

-- A saved list read up to `size` items, with `fill` where the save has a hole or a value of the wrong type
-- (a saved list with nil in the middle comes back with the hole, and # and ipairs stop at it).
-- Without `size`, the list goes up to its highest index, at most MAX_LIST. Without `fill`, holes stay holes.
function SavedState.list(saved, size, fill)
    local out = {}
    if type(saved) ~= "table" then
        saved = {}
    end
    size = size or last_index(saved)
    for i = 1, size do
        local value = saved[i]
        if value == nil or (fill ~= nil and type(value) ~= type(fill)) then
            value = copy(fill)
        end
        out[i] = value
    end
    return out
end

-- Ids in the saved list that still exist in `known` (a set, or a function that returns true for a known id),
-- in order, without repeats. Holes in the saved list are skipped, not taken as its end.
function SavedState.known(ids, known)
    local out, seen = {}, {}
    local exists = type(known) == "function" and known or function(id) return known[id] ~= nil end
    if type(ids) ~= "table" then
        return out
    end
    for i = 1, last_index(ids) do
        local id = ids[i]
        if id ~= nil and not seen[id] and exists(id) then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    return out
end

-- True when `data` is a table saved with this version of the format.
function SavedState.is_version(data, version)
    return type(data) == "table" and data.version == version
end

-- Runs `restore(data)` protected. Returns what it returns, or nil when it raises an error, after reporting
-- the error to `warn` (logger.warn in the plugin, nothing in the tests). Use it for the game in progress, so
-- a save that slipped through the checks is dropped and the screen still opens.
function SavedState.restore(restore, data, warn)
    if data == nil then
        return nil
    end
    local ok, result = pcall(restore, data)
    if ok then
        return result
    end
    if warn then
        warn("saved state dropped: " .. tostring(result))
    end
    return nil
end

-- Removes a settings file and the backup KOReader keeps next to it (<path>.old). LuaSettings reads the backup
-- when the file is missing, so removing only the file brings the data back the next time the path is opened.
function SavedState.remove_file(path)
    os.remove(path)
    os.remove(path .. ".old")
end

return SavedState
