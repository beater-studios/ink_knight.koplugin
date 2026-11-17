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
            { text = s.study_search, callback = function() Studies.ask_search(app) end },
            { text = s.study_popular, callback = function()
                Studies.site_list(app, s.study_popular, function(page) return Api.study_popular(page, not app:reads_studies()) end)
            end },
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
                    local name = StudyStore.plain_name(study.name)
                    rows[#rows + 1] = {
                        text = name,
                        wrap = true,
                        detail = day_text(study.updatedAt),
                        callback = function() Studies.study(app, { id = study.id, name = name, chapters = {} }) end,
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

-- The characters of a text, each as its bytes in UTF-8.
local function characters(text)
    local chars = {}
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        chars[#chars + 1] = char
    end
    return chars
end

-- The studies of a page of the site, as rows, and whether it has a next page; nil when the answer is not the paginator the plugin knows. Lichess serves only the first Api.STUDY_SITE_PAGES pages and answers 400 past them, though the 40th still names a next one.
function Studies.site_rows(app, body)
    local s = app.strings
    local data = app.decode(body)
    local paginator = type(data) == "table" and data.paginator
    local results = type(paginator) == "table" and paginator.currentPageResults
    if type(results) ~= "table" then
        return nil
    end
    local rows = {}
    for _, study in ipairs(results) do
        if type(study) == "table" and Api.is_safe_id(study.id) and type(study.name) == "string" then
            local parts = {}
            if type(study.owner) == "table" and type(study.owner.name) == "string" then
                parts[#parts + 1] = study.owner.name
            end
            if type(study.likes) == "number" then
                parts[#parts + 1] = string.format(s.study_likes, study.likes)
            end
            local name = StudyStore.plain_name(study.name)
            rows[#rows + 1] = {
                text = name,
                wrap = true,
                detail = #parts > 0 and table.concat(parts, " · ") or nil,
                callback = function() Studies.study(app, kept_entry(app, study.id) or { id = study.id, name = name, chapters = {} }) end,
            }
        end
    end
    local next_page = paginator.nextPage
    return rows, type(next_page) == "number" and next_page <= Api.STUDY_SITE_PAGES
end

-- What went wrong with a page of the site. A 403 there is not about the token, which goes only with study:read: Lichess or what protects it turned the request away.
local function site_problem(app, status)
    if status == 403 then
        return app.strings.study_site_refused
    end
    return app:error_text(status)
end

-- A list of studies from a page of the site, which grows a page at a time with "More studies". request_of(page) gives the request of a page, from 1.
function Studies.site_list(app, title, request_of)
    local s = app.strings
    -- Loading from the start, so the page never opens saying nothing was found.
    local found = { rows = {}, page = 1, loading = true }
    local page_widget
    local function redraw()
        if page_widget and not found.closed then
            page_widget:reload()
        end
    end
    local function load()
        if not app.net then
            found.loading, found.problem, found.retry = false, s.no_network, false
            redraw()
            return
        end
        found.loading, found.problem = true, nil
        redraw()
        app.net:request(request_of(found.page), function(status, body)
            found.loading = false
            if status ~= 200 then
                found.problem = site_problem(app, status)
                -- Trying again helps only when the network or the load of the site was the trouble.
                found.retry = not status or status == 429 or status >= 500
            else
                local rows, more = Studies.site_rows(app, body)
                if not rows then
                    found.problem, found.retry = s.study_site_changed, false
                else
                    for _, row in ipairs(rows) do
                        found.rows[#found.rows + 1] = row
                    end
                    found.more, found.page = more, found.page + 1
                end
            end
            redraw()
        end)
    end
    page_widget = app:open_page{ title = title, on_closed = function() found.closed = true end, build = function()
        local rows = {}
        for _, row in ipairs(found.rows) do
            rows[#rows + 1] = row
        end
        if #rows == 0 then
            if found.loading then
                rows[1] = { kind = "state", piece = "N", fill = true, text = s.loading }
            elseif found.problem then
                rows[1] = { kind = "state", piece = "r", fill = true, text = found.problem }
            else
                rows[1] = { kind = "state", piece = "P", fill = true, text = s.study_search_none }
            end
        elseif found.loading then
            rows[#rows + 1] = { kind = "text", text = s.loading, center = true }
        elseif found.problem then
            rows[#rows + 1] = { kind = "text", text = found.problem, center = true }
        end
        if #found.rows > 0 and not found.loading and (found.problem and found.retry or not found.problem and found.more) then
            rows[#rows + 1] = { kind = "secondary", text = s.study_more, keep_open = true, callback = function()
                if not found.loading then
                    load()
                end
            end }
        end
        return rows
    end }
    load()
    return page_widget
end

-- The title of a search: what was searched, short enough for the title of the page, the first characters with "…" when it goes on.
function Studies.search_title(app, text)
    local chars = characters(text)
    if #chars > 16 then
        text = table.concat(chars, "", 1, 15) .. "…"
    end
    return string.format(app.strings.study_search_title, text)
end

-- What to search, typed with the keyboard of KOReader. Lichess takes a search of 2 characters or fewer as no search and answers with all studies, so those are not sent.
function Studies.ask_search(app)
    local s = app.strings
    local dialog
    dialog = InputDialog:new{
        title = s.study_search,
        buttons = { {
            { text = s.cancel, id = "close", callback = function() UIManager:close(dialog) end },
            { text = s.study_search, is_enter_default = true, callback = function()
                local text = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                UIManager:close(dialog)
                if text == "" then
                    return
                elseif #characters(text) < 3 then
                    app:info(s.study_search_short)
                    return
                end
                Studies.site_list(app, Studies.search_title(app, text), function(page) return Api.study_search(text, page, not app:reads_studies()) end)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
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
