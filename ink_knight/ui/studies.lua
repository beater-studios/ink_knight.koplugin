-- Lichess studies: the reader's own, another player's, or one by its address or code; each kept on the device,
-- downloaded in the background, and read with no network in the screen of the practice lessons: a chapter as a
-- commented game, an interactive one as a guided chapter.
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")

local Api = require("ink_knight/api")
local PracticeScreen = require("ink_knight/ui/practice_screen")
local StudyChapter = require("ink_knight/study_chapter")
local StudyStore = require("ink_knight/study_store")

local Studies = {}

local function day_text(milliseconds)
    local seconds = tonumber(milliseconds)
    return seconds and os.date("%d/%m/%Y", math.floor(seconds / 1000)) or nil
end

-- A text with a count, in its singular form when the count is one: key and key_one.
local function counted(s, key, count, ...)
    return string.format(count == 1 and s[key .. "_one"] or s[key], ...)
end

local function kept_entry(app, id)
    for _, study in ipairs(app:saved_studies()) do
        if study.id == id then
            return study
        end
    end
end

-- What the pages of studies show of the downloads, to draw them again only when it changes.
local function downloads_signature(app)
    local parts = {}
    for _, study in ipairs(app:saved_studies()) do
        parts[#parts + 1] = study.id .. ":" .. tostring(app:study_download_state(study)) .. ":" .. #study.chapters
    end
    return table.concat(parts, ",")
end

-- A page that follows the downloads of studies, drawn again only when what it shows of them changes.
local function open_following(app, args)
    local page, last
    local build = args.build
    args.build = function(...)
        last = downloads_signature(app)
        return build(...)
    end
    page = app:open_page(args)
    page.on_download = function()
        if downloads_signature(app) ~= last then
            page:reload()
        end
    end
    return page
end

local function kept_rows(app, rows)
    local s = app.strings
    for _, study in ipairs(app:saved_studies()) do
        local state = app:study_download_state(study)
        rows[#rows + 1] = {
            text = study.name,
            wrap = true,
            detail = state and s.study_keeping or (#study.chapters > 0 and counted(s, "study_chapter_count", #study.chapters, #study.chapters) or s.study_not_downloaded),
            callback = function() Studies.study(app, study) end,
        }
    end
end

function Studies.menu(app)
    local s = app.strings
    open_following(app, { title = s.studies, build = function()
        local rows = {
            { text = s.study_mine, detail = not app:reads_studies() and s.study_mine_public or nil, callback = function() Studies.list(app, app.my_id, s.study_mine) end },
            { text = s.study_of_player, callback = function()
                require("ink_knight/ui/players").ask_name(app, function(name) Studies.list(app, name, name) end)
            end },
            { text = s.study_open_code, callback = function() Studies.ask_code(app) end },
            { kind = "section", text = s.study_kept_section },
        }
        local before = #rows
        kept_rows(app, rows)
        if #rows == before then
            rows[#rows + 1] = { kind = "text", text = s.study_none_kept, center = true }
        end
        return rows
    end })
end

-- The kept studies, from the offline menu.
function Studies.kept_menu(app)
    local s = app.strings
    open_following(app, { title = s.study_kept_menu, build = function()
        local rows = {}
        kept_rows(app, rows)
        if #rows == 0 then
            rows[1] = { kind = "text", text = s.study_none_kept, center = true }
        end
        return rows
    end })
end

-- The studies of a player, the last changed first. With study:read the reader's own private ones come too.
function Studies.list(app, username, title)
    local s = app.strings
    if not Api.is_safe_id(username) then
        app:info(s.study_none)
        return
    end
    app.net:request(Api.study_list(username, not app:reads_studies()), function(status, body)
        app:report_or(status, function()
            local rows = {}
            for line in tostring(body or ""):gmatch("[^\n]+") do
                local study = app.decode(line)
                if type(study) == "table" and Api.is_safe_id(study.id) and type(study.name) == "string" then
                    rows[#rows + 1] = {
                        text = study.name,
                        wrap = true,
                        detail = day_text(study.updatedAt),
                        callback = function() Studies.study(app, { id = study.id, name = study.name, chapters = {} }) end,
                    }
                end
            end
            if #rows == 0 then
                app:info(s.study_none)
                return
            end
            app:open_list(title or s.studies, rows)
        end)
    end)
end

function Studies.ask_code(app)
    local s = app.strings
    local dialog
    dialog = InputDialog:new{
        title = s.study_code_title,
        buttons = { {
            { text = s.cancel, id = "close", callback = function() UIManager:close(dialog) end },
            { text = s.study_code_ok, is_enter_default = true, callback = function()
                local id = StudyStore.id_from(dialog:getInputText())
                UIManager:close(dialog)
                if id then
                    Studies.study(app, kept_entry(app, id) or { id = id, name = id, chapters = {} })
                else
                    app:info(s.study_code_bad)
                end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- A study: keeping it on the device and how its download goes, its chapters once kept, and deleting it.
function Studies.study(app, study)
    local s = app.strings
    local store = app:study_store()
    local page
    page = open_following(app, { title = s.studies, build = function()
        local entry = kept_entry(app, study.id)
        local shown = entry or study
        local rows = { { kind = "text", text = shown.name } }
        local state = entry and app:study_download_state(entry)
        if not state and entry then
            store:settle(entry)
        end
        local kept = entry and store:is_kept(entry)
        local function keep()
            local fresh = { id = study.id, name = shown.name, at = os.time(), chapters = entry and entry.chapters or {} }
            if entry then
                store:set_aside(entry)
            end
            app:save_study_index(StudyStore.with_entry(app:saved_studies(), fresh))
            app:download_study(fresh)
            page:reload()
        end
        if state == "running" then
            rows[#rows + 1] = { text = s.study_keeping }
        elseif state == "queued" then
            rows[#rows + 1] = { text = s.broadcast_waiting }
        elseif not entry then
            rows[#rows + 1] = { text = s.study_keep, detail = s.study_keep_detail, callback = keep }
        elseif not kept then
            local stopped = (app.download_results or {})["study_" .. study.id] == "stopped"
            rows[#rows + 1] = { text = s.study_resume, detail = stopped and s.study_failed or nil, callback = function()
                app:download_study(entry)
                page:reload()
            end }
        else
            -- An update that did not come leaves the study as it was, and says so.
            local stopped = (app.download_results or {})["study_" .. study.id] == "stopped"
            rows[#rows + 1] = { text = s.study_kept, detail = stopped and s.study_failed or s.study_kept_update, callback = keep }
        end
        if kept and #entry.chapters > 0 then
            rows[#rows + 1] = { kind = "section", text = s.study_chapters }
            for index, chapter in ipairs(entry.chapters) do
                rows[#rows + 1] = {
                    text = chapter.name,
                    wrap = true,
                    detail = chapter.guided and s.study_interactive or nil,
                    callback = function() Studies.open_chapter(app, entry, index) end,
                }
            end
        end
        if entry then
            rows[#rows + 1] = { kind = "secondary", text = s.broadcast_delete, callback = function()
                app:ask{ text = s.study_delete_ask, ok_text = s.broadcast_delete, on_ok = function()
                    if app.downloads then
                        app.downloads:cancel("study_" .. study.id)
                    end
                    store:delete(entry)
                    app:save_study_index(StudyStore.without(app:saved_studies(), study.id))
                    UIManager:close(page)
                    app:reload_pages()
                end }
            end }
        end
        return rows
    end })
end

-- A chapter in the screen of the practice lessons, read only when it is reached; Next goes on through the study.
function Studies.open_chapter(app, study, index)
    local s = app.strings
    local texts = app:study_store():chapter_texts(study)
    if not texts or not texts[index] then
        app:info(s.study_not_downloaded)
        return
    end
    local placeholders = {}
    for i = 1, #texts do
        placeholders[i] = { id = study.id .. "_" .. i }
    end
    local cache = {}
    PracticeScreen.open(app, { chapters = placeholders }, index, {
        title = study.name,
        load = function(i)
            if not cache[i] then
                local chapter, chapter_texts = StudyChapter.read(texts[i], study.id .. "_" .. i)
                cache[i] = { chapter or { id = study.id .. "_" .. i, kind = "lesson", fen = require("ink_knight/chess").START_FEN, color = "w", line = {}, shapes = {}, wrong = {} }, chapter_texts or {} }
            end
            return cache[i][1], cache[i][2]
        end,
    })
end

return Studies
