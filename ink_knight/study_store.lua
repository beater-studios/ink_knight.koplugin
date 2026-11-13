-- Lichess studies kept on the device to read with no network: an index in the settings (each study, its name and its
-- chapters) and the PGN of the whole study in a file, downloaded in the background by the download pattern. Lichess
-- has no route for the chapters alone, so the index comes from the file once it is here. Downloading again sets the
-- old file aside until the new one is complete. No KOReader here, so the tests can use it; the folder operations come
-- in opts.
local Api = require("ink_knight/api")
local Broadcast = require("ink_knight/broadcast")

local Store = {}
Store.__index = Store

-- opts: dir, exists(path), remove(path), rename(from, to), make_dir(path), read(path).
function Store.new(opts)
    return setmetatable(opts, Store)
end

-- The kept studies read back from the settings, without what does not fit: { { id, name, at, chapters = { { name,
-- guided } } } }, the last kept first. A study whose download has not finished has no chapters yet.
function Store.read_index(saved)
    local list = {}
    for _, study in ipairs(type(saved) == "table" and saved or {}) do
        if type(study) == "table" and Api.is_safe_id(study.id) then
            local chapters = {}
            for _, chapter in ipairs(type(study.chapters) == "table" and study.chapters or {}) do
                if type(chapter) == "table" and type(chapter.name) == "string" then
                    chapters[#chapters + 1] = { name = chapter.name, guided = chapter.guided == true }
                end
            end
            list[#list + 1] = { id = study.id, name = type(study.name) == "string" and study.name or study.id, at = tonumber(study.at), chapters = chapters }
        end
    end
    return list
end

-- The index with entry first, in place of an older copy, and without one: the same as for broadcasts.
Store.with_entry = require("ink_knight/broadcast_store").with_entry
Store.without = require("ink_knight/broadcast_store").without

function Store:path(study)
    return self.dir .. "/" .. study.id .. ".pgn"
end

-- The file to read: the kept one, or, while a new copy downloads, the old one set aside, so the chapters still open.
function Store:readable(study)
    local path = self:path(study)
    if self.exists(path) then
        return path
    elseif self.exists(path .. ".old") then
        return path .. ".old"
    end
    return nil
end

function Store:is_kept(study)
    return self:readable(study) ~= nil
end

-- The download of a study: its PGN, or nothing when it is already here.
function Store:files(study)
    if self.exists(self:path(study)) then
        return {}
    end
    local request = Api.study_pgn(study.id)
    return { { (request.base or Api.BASE) .. request.path, self:path(study) } }
end

-- The chapters of the kept file, as the index keeps them, with the name of the study from its first chapter.
function Store:chapters_of(study)
    local text = self:readable(study) and self.read(self:readable(study))
    if not text then
        return nil
    end
    local chapters, name = {}, nil
    for index, chapter_text in ipairs(Broadcast.split_games(text)) do
        local tags = Broadcast.tags(chapter_text)
        name = name or tags.StudyName
        chapters[#chapters + 1] = { name = tags.ChapterName or tags.Event or tostring(index), guided = tags.ChapterMode == "gamebook" }
    end
    return chapters, name
end

-- The text of each chapter of the kept file, in order.
function Store:chapter_texts(study)
    local text = self:readable(study) and self.read(self:readable(study))
    return text and Broadcast.split_games(text) or nil
end

-- Before downloading again: the file is set aside, and comes back if the new one does not come.
function Store:set_aside(study)
    if self.exists(self:path(study)) then
        self.rename(self:path(study), self:path(study) .. ".old")
    end
end

function Store:settle(study)
    local path = self:path(study)
    if self.exists(path .. ".old") then
        if self.exists(path) then
            self.remove(path .. ".old")
        else
            self.rename(path .. ".old", path)
        end
    end
end

function Store:delete(study)
    local path = self:path(study)
    for _, suffix in ipairs({ "", ".part", ".code", ".old" }) do
        self.remove(path .. suffix)
    end
end

-- "abcdEFGH" from a study's address (https://lichess.org/study/abcdEFGH, with a chapter or not) or its code.
function Store.id_from(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local id = text:match("^https?://lichess%.org/study/(%w+)") or text:match("^lichess%.org/study/(%w+)") or text:match("^(%w+)$")
    return id and #id == 8 and id or nil
end

return Store
