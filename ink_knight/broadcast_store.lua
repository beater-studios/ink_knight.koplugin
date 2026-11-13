-- Broadcasts kept on the device to see with no network: an index in the settings (which tournaments, their rounds and
-- whether each round was over when it was kept) and a PGN file for each round, downloaded in the background by the
-- download pattern. A round missing its file is what a download cut short left; one that was still being played is
-- downloaded again when the reader asks, its old file set aside until the new one is complete. No KOReader here, so
-- the tests can use it; the folder operations come in opts.
local Api = require("ink_knight/api")
local Broadcast = require("ink_knight/broadcast")

local Store = {}
Store.__index = Store

-- opts: dir (where the files go), exists(path), remove(path), rename(from, to), make_dir(path), read(path).
function Store.new(opts)
    return setmetatable(opts, Store)
end

-- The kept tournaments read back from the settings, without what does not fit: { { id, name, at, rounds = { { id,
-- name, finished } } } }, the last kept first.
function Store.read_index(saved)
    local list = {}
    for _, tour in ipairs(type(saved) == "table" and saved or {}) do
        if type(tour) == "table" and Api.is_safe_id(tour.id) and type(tour.name) == "string" and type(tour.rounds) == "table" then
            local rounds = {}
            for _, round in ipairs(tour.rounds) do
                if type(round) == "table" and Api.is_safe_id(round.id) and type(round.name) == "string" then
                    rounds[#rounds + 1] = { id = round.id, name = round.name, finished = round.finished == true }
                end
            end
            if #rounds > 0 then
                list[#list + 1] = { id = tour.id, name = tour.name, at = tonumber(tour.at), rounds = rounds }
            end
        end
    end
    return list
end

-- A tournament as Lichess sends it (/api/broadcast/{id}), as the index keeps it: the rounds already started, since
-- the ones still to come have nothing to download.
function Store.entry_of(data, now)
    local tour = type(data) == "table" and type(data.tour) == "table" and data.tour or {}
    if not Api.is_safe_id(tour.id) then
        return nil
    end
    local rounds = {}
    for _, round in ipairs(type(data.rounds) == "table" and data.rounds or {}) do
        if type(round) == "table" and Api.is_safe_id(round.id) and (round.finished or round.ongoing) then
            rounds[#rounds + 1] = { id = round.id, name = type(round.name) == "string" and round.name or "?", finished = round.finished == true }
        end
    end
    if #rounds == 0 then
        return nil
    end
    return { id = tour.id, name = type(tour.name) == "string" and tour.name or "?", at = now, rounds = rounds }
end

-- The index with entry first, in place of an older copy of the same tournament.
function Store.with_entry(index, entry)
    local list = { entry }
    for _, tour in ipairs(index) do
        if tour.id ~= entry.id then
            list[#list + 1] = tour
        end
    end
    return list
end

function Store.without(index, id)
    local list = {}
    for _, tour in ipairs(index) do
        if tour.id ~= id then
            list[#list + 1] = tour
        end
    end
    return list
end

function Store:tour_dir(tour)
    return self.dir .. "/" .. tour.id
end

function Store:round_path(tour, round)
    return self:tour_dir(tour) .. "/" .. round.id .. ".pgn"
end

-- The download of a tournament: { url, path } for each round not on the device yet.
function Store:files(tour)
    local files = {}
    for _, round in ipairs(tour.rounds) do
        local path = self:round_path(tour, round)
        if not self.exists(path) then
            local request = Api.broadcast_round_pgn(round.id)
            files[#files + 1] = { (request.base or Api.BASE) .. request.path, path }
        end
    end
    return files
end

-- How many rounds are on the device, of how many.
function Store:count(tour)
    local have = 0
    for _, round in ipairs(tour.rounds) do
        if self.exists(self:round_path(tour, round)) then
            have = have + 1
        end
    end
    return have, #tour.rounds
end

-- Before downloading a tournament again: the files of the rounds that were still being played are set aside, so they
-- come back with the moves played since, and the old ones stay until then. The rounds that were over stay as they are.
function Store:set_aside_unfinished(tour)
    for _, round in ipairs(tour.rounds) do
        local path = self:round_path(tour, round)
        if not round.finished and self.exists(path) then
            self.rename(path, path .. ".old")
        end
    end
end

-- After a download, or when a page opens after one was cut short: a round that came keeps its new file, and one that
-- did not gets its old file back.
function Store:settle(tour)
    for _, round in ipairs(tour.rounds) do
        local path = self:round_path(tour, round)
        if self.exists(path .. ".old") then
            if self.exists(path) then
                self.remove(path .. ".old")
            else
                self.rename(path .. ".old", path)
            end
        end
    end
end

-- With what a download cut short leaves beside each file, so the folder goes too.
function Store:delete(tour)
    for _, round in ipairs(tour.rounds) do
        local path = self:round_path(tour, round)
        for _, suffix in ipairs({ "", ".part", ".code", ".old" }) do
            self.remove(path .. suffix)
        end
    end
    self.remove(self:tour_dir(tour))
end

-- The games of a kept round: { text, detail, game_text }, or nil when its file is not there.
function Store:round_games(tour, round, s)
    local text = self.read(self:round_path(tour, round))
    if not text then
        return nil
    end
    local games = {}
    for _, game_text in ipairs(Broadcast.split_games(text)) do
        local tags = Broadcast.tags(game_text)
        local white = Broadcast.short_player({ title = tags.WhiteTitle, name = tags.White })
        local black = Broadcast.short_player({ title = tags.BlackTitle, name = tags.Black })
        local result = tags.Result and tags.Result ~= "*" and Broadcast.result_text(tags.Result) or s.broadcast_unfinished
        games[#games + 1] = {
            text = string.format("%s x %s", white, black),
            detail = string.format(s.broadcast_clocks, result, string.format(s.broadcast_clocks, tags.WhiteElo or "?", tags.BlackElo or "?")),
            game_text = game_text,
        }
    end
    return games
end

return Store
