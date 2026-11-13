-- The broadcasts of Lichess: the tournaments live, coming and past, a tournament with its rounds and standings, a
-- round with its games, kept up to date while it is open, and a game in the review, following its moves while it is
-- played. A tournament can be kept on the device, downloaded in the background, to see with no network.
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")

local Api = require("ink_knight/api")
local Broadcast = require("ink_knight/broadcast")
local BroadcastStore = require("ink_knight/broadcast_store")
local ReviewScreen = require("ink_knight/ui/review_screen")
local Sleep = require("ink_knight/sleep")

local Broadcasts = {}

-- A round open on the screen is asked for again this often: a move of a classical game takes minutes.
local ROUND_REFRESH_SECONDS = 60

local function day_text(milliseconds)
    local seconds = tonumber(milliseconds)
    return seconds and os.date("%d/%m %H:%M", math.floor(seconds / 1000)) or nil
end

-- A row of a tournament in the lists, opening it on its round.
local function tour_row(app, item, detail)
    local tour = type(item) == "table" and type(item.tour) == "table" and item.tour or {}
    local round = type(item.round) == "table" and item.round or {}
    if not Api.is_safe_id(tour.id) then
        return nil
    end
    return {
        text = type(tour.name) == "string" and tour.name or "?",
        wrap = true,
        detail = detail(round),
        callback = function() Broadcasts.tournament(app, tour.id) end,
    }
end

local function list_rows(app, items, detail, rows)
    for _, item in ipairs(type(items) == "table" and items or {}) do
        local row = tour_row(app, item, detail)
        if row then
            rows[#rows + 1] = row
        end
    end
end

function Broadcasts.menu(app)
    local s = app.strings
    app.net:request(Api.broadcast_top(1), function(status, body)
        app:report_or(status, function()
            local data = app.decode(body) or {}
            local function round_name(round)
                return type(round.name) == "string" and round.name or nil
            end
            local rows = {
                { text = s.broadcast_search, callback = function() Broadcasts.ask_search(app) end },
                { kind = "section", text = s.broadcast_live_section },
            }
            local live = #rows
            list_rows(app, data.active, function(round) return round_name(round) and string.format(s.broadcast_round_live, round.name) end, rows)
            if #rows == live then
                rows[#rows + 1] = { kind = "text", text = s.broadcast_none_live, center = true }
            end
            if type(data.upcoming) == "table" and #data.upcoming > 0 then
                rows[#rows + 1] = { kind = "section", text = s.broadcast_upcoming_section }
                list_rows(app, data.upcoming, function(round)
                    local when = day_text(round.startsAt)
                    return round_name(round) and when and string.format("%s · %s", round.name, when) or round_name(round)
                end, rows)
            end
            local past = type(data.past) == "table" and data.past or {}
            rows[#rows + 1] = { kind = "section", text = s.broadcast_past_section }
            list_rows(app, past.currentPageResults, round_name, rows)
            if past.nextPage then
                rows[#rows + 1] = { text = s.broadcast_older, callback = function() Broadcasts.past(app, past.nextPage) end }
            end
            app:open_list(s.broadcasts, rows)
        end)
    end)
end

function Broadcasts.past(app, page)
    local s = app.strings
    app.net:request(Api.broadcast_top(page), function(status, body)
        app:report_or(status, function()
            local past = (app.decode(body) or {}).past or {}
            local rows = {}
            list_rows(app, past.currentPageResults, function(round) return type(round.name) == "string" and round.name or nil end, rows)
            if past.nextPage then
                rows[#rows + 1] = { text = s.broadcast_older, callback = function() Broadcasts.past(app, past.nextPage) end }
            end
            if #rows == 0 then
                app:info(s.broadcast_none)
                return
            end
            app:open_list(s.broadcast_past_section, rows)
        end)
    end)
end

function Broadcasts.ask_search(app)
    local s = app.strings
    local dialog
    dialog = InputDialog:new{
        title = s.broadcast_search_title,
        buttons = { {
            { text = s.cancel, id = "close", callback = function() UIManager:close(dialog) end },
            { text = s.broadcast_search_ok, is_enter_default = true, callback = function()
                local term = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                UIManager:close(dialog)
                if term ~= "" then
                    Broadcasts.search(app, term)
                end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Broadcasts.search(app, term)
    local s = app.strings
    app.net:request(Api.broadcast_search(term, 1), function(status, body)
        app:report_or(status, function()
            local rows = {}
            list_rows(app, (app.decode(body) or {}).currentPageResults, function(round) return type(round.name) == "string" and round.name or nil end, rows)
            if #rows == 0 then
                app:info(s.broadcast_none)
                return
            end
            app:open_list(term, rows)
        end)
    end)
end

-- A tournament: what it is, its rounds (the one going on first marked) and the standings.
function Broadcasts.tournament(app, id)
    local s = app.strings
    app.net:request(Api.broadcast_tournament(id), function(status, body)
        app:report_or(status, function()
            local data = app.decode(body) or {}
            local tour = type(data.tour) == "table" and data.tour or {}
            local info = type(tour.info) == "table" and tour.info or {}
            local rows = { { kind = "text", text = type(tour.name) == "string" and tour.name or "?" } }
            local facts = {}
            for _, key in ipairs({ "format", "tc", "location" }) do
                if type(info[key]) == "string" and info[key] ~= "" then
                    facts[#facts + 1] = info[key]
                end
            end
            if #facts > 0 then
                rows[#rows + 1] = { kind = "text", text = table.concat(facts, "\n") }
            end
            rows[#rows + 1] = { text = s.broadcast_standings, callback = function() Broadcasts.standings(app, id, tour.name) end }
            local save_index = #rows + 1
            rows[save_index] = false
            rows[#rows + 1] = { kind = "section", text = s.broadcast_rounds }
            for _, round in ipairs(type(data.rounds) == "table" and data.rounds or {}) do
                if type(round) == "table" and Api.is_safe_id(round.id) then
                    local detail
                    if round.ongoing then
                        detail = s.broadcast_live
                    elseif round.finished then
                        detail = s.broadcast_finished
                    else
                        detail = day_text(round.startsAt)
                    end
                    rows[#rows + 1] = {
                        text = type(round.name) == "string" and round.name or "?",
                        detail = detail,
                        bold = round.ongoing == true,
                        focus = round.id == data.defaultRoundId or nil,
                        callback = function() Broadcasts.round(app, round.id, round.name) end,
                    }
                end
            end
            local page
            local last
            page = app:open_page{ title = s.broadcasts, build = function()
                rows[save_index] = Broadcasts.save_row(app, data, function() page:reload() end)
                last = rows[save_index].text
                return rows
            end }
            -- The progress of the download, drawn again only when its text changes.
            page.on_download = function()
                local row = Broadcasts.save_row(app, data, function() end)
                if row.text ~= last then
                    page:reload()
                end
            end
        end)
    end)
end

-- The download of a kept tournament: its state, and, when none runs, the old files an update cut short set aside put
-- back.
local function download_state(app, tour)
    local state, done, total = app:broadcast_download_state(tour)
    if not state then
        app:broadcast_store():settle(tour)
    end
    return state, done, total
end

-- A text with a count, in its singular form when the count is one: key and key_one.
local function counted(s, key, count, ...)
    return string.format(count == 1 and s[key .. "_one"] or s[key], ...)
end

-- What the pages of kept tournaments show of the downloads, to draw them again only when it changes.
local function downloads_signature(app)
    local parts = {}
    for _, tour in ipairs(app:saved_broadcasts()) do
        local state, done = app:broadcast_download_state(tour)
        parts[#parts + 1] = tour.id .. ":" .. tostring(state) .. ":" .. tostring(done)
    end
    return table.concat(parts, ",")
end

local function saved_entry(app, id)
    for _, tour in ipairs(app:saved_broadcasts()) do
        if tour.id == id then
            return tour
        end
    end
end

-- The row that keeps a tournament on the device: to keep it, its progress while it downloads, what is missing after a
-- download cut short, or, once kept, to bring the rounds still being played up to date. changed: after a tap.
function Broadcasts.save_row(app, data, changed)
    local s = app.strings
    local id = data.tour and data.tour.id
    local entry = saved_entry(app, id)
    local state, done, total
    if entry then
        state, done, total = download_state(app, entry)
    end
    if state == "running" then
        return { text = counted(s, "broadcast_saving", total, done, total) }
    elseif state == "queued" then
        return { text = s.broadcast_waiting }
    end
    local function keep()
        local fresh = BroadcastStore.entry_of(data, os.time())
        if not fresh then
            app:info(s.broadcast_nothing_to_save)
            return
        end
        if entry then
            app:broadcast_store():set_aside_unfinished(entry)
        end
        app:save_broadcast_index(BroadcastStore.with_entry(app:saved_broadcasts(), fresh))
        app:download_broadcast(fresh)
        changed()
    end
    if not entry then
        return { text = s.broadcast_save, detail = s.broadcast_save_detail, callback = keep }
    end
    local have, all = app:broadcast_store():count(entry)
    if have < all then
        local stopped = (app.download_results or {})[entry.id] == "stopped"
        return { text = counted(s, "broadcast_resume", all - have, all - have), detail = stopped and s.broadcast_stopped or nil, callback = function()
            app:download_broadcast(entry)
            changed()
        end }
    end
    -- An update that did not come leaves the rounds as they were, and says so.
    local stopped = (app.download_results or {})[entry.id] == "stopped"
    return { text = s.broadcast_saved, detail = stopped and s.broadcast_stopped or s.broadcast_saved_update, callback = keep }
end

function Broadcasts.standings(app, id, name)
    local s = app.strings
    app.net:request(Api.broadcast_players(id), function(status, body)
        app:report_or(status, function()
            local rows = {}
            for index, player in ipairs(app.decode(body) or {}) do
                if type(player) == "table" then
                    rows[#rows + 1] = {
                        text = string.format("%d. %s", tonumber(player.rank) or index, Broadcast.player_text(player)),
                        wrap = true,
                        value = Broadcast.score_text(player.score, player.played),
                    }
                end
            end
            if #rows == 0 then
                app:info(s.broadcast_no_standings)
                return
            end
            table.insert(rows, 1, { kind = "text", text = name or "" })
            app:open_list(s.broadcast_standings, rows)
        end)
    end)
end

-- A round: its games, asked for again every ROUND_REFRESH_SECONDS while the page is open.
function Broadcasts.round(app, id, name)
    local s = app.strings
    local games, updated
    local page
    local function load(after)
        app.net:request(Api.broadcast_round(id), function(status, body)
            if status == 200 then
                games, updated = Broadcast.round_games(s, app.decode(body)), os.date("%H:%M")
            end
            after(status)
        end)
    end
    local function rows()
        local list = {
            { kind = "section", text = updated and string.format(s.updated_at, updated) or name, action_text = s.refresh, action = function()
                load(function() if page then page:reload() end end)
            end },
        }
        for _, game in ipairs(games or {}) do
            list[#list + 1] = {
                kind = "game",
                text = game.text,
                detail = game.detail,
                callback = function() Broadcasts.game(app, id, game) end,
            }
        end
        if #(games or {}) == 0 then
            list[#list + 1] = { kind = "text", text = s.broadcast_no_games, center = true }
        end
        return list
    end
    local function tick()
        if page and not page.closed then
            load(function()
                if page and not page.closed then
                    page:reload()
                    Sleep.schedule(page, ROUND_REFRESH_SECONDS, tick)
                end
            end)
        end
    end
    load(function(status)
        app:report_or(status, function()
            page = app:open_page{ title = name or s.broadcasts, build = rows, on_closed = function(closed) closed.closed = true end }
            Sleep.schedule(page, ROUND_REFRESH_SECONDS, tick)
        end)
    end)
end

-- A game of the PGN as the review takes it, and whether it is still being played.
local function review_of(text)
    local tags = Broadcast.tags(text)
    local moves, fen = Broadcast.main_line(text)
    local result = tags.Result and tags.Result ~= "*" and Broadcast.result_text(tags.Result) or nil
    local opening = tags.Opening and tags.Opening ~= "?" and tags.Opening or nil
    return {
        moves = moves,
        initial_fen = fen,
        white = Broadcast.tag_player(tags, "white"),
        black = Broadcast.tag_player(tags, "black"),
        intro = opening,
        opening = opening,
        result_text = result,
    }, result == nil
end

-- A game of a round in the review, from the PGN of the round; one still being played follows its moves.
function Broadcasts.game(app, round_id, game)
    local s = app.strings
    local function fetch(on_game)
        app.net:request(Api.broadcast_round_pgn(round_id), function(status, body)
            local text
            if status == 200 then
                text = Broadcast.find_game(body, game.id)
            end
            if not text then
                on_game(nil, status)
                return
            end
            local review, ongoing = review_of(text)
            on_game(review, status, ongoing)
        end)
    end
    fetch(function(review, status, ongoing)
        if not review then
            app:info(status == 200 and s.broadcast_game_missing or app:error_text(status))
            return
        end
        ReviewScreen.open(app, review, { refresh = ongoing and function(on_game)
            fetch(function(again) on_game(again) end)
        end or nil })
    end)
end

-- What is kept on the device, to see with no network ---------------------------------------------------------------

function Broadcasts.saved_menu(app)
    local s = app.strings
    local page, last
    page = app:open_page{ title = s.broadcast_saved_menu, build = function()
        local rows = {}
        local store = app:broadcast_store()
        last = downloads_signature(app)
        for _, tour in ipairs(app:saved_broadcasts()) do
            local state, done, total = download_state(app, tour)
            local have, all = store:count(tour)
            rows[#rows + 1] = {
                text = tour.name,
                wrap = true,
                detail = state == "running" and counted(s, "broadcast_saving", total, done, total) or counted(s, "broadcast_saved_rounds", all, have, all),
                callback = function() Broadcasts.saved_tournament(app, tour, function() page:reload() end) end,
            }
        end
        if #rows == 0 then
            rows[1] = { kind = "text", text = s.broadcast_none_saved, center = true }
        end
        return rows
    end }
    page.on_download = function()
        if downloads_signature(app) ~= last then
            page:reload()
        end
    end
end

-- A kept tournament: its rounds, what is still to download, and deleting it. changed: after it is deleted.
function Broadcasts.saved_tournament(app, tour, changed)
    local s = app.strings
    local store = app:broadcast_store()
    local page, last
    page = app:open_page{ title = s.broadcast_saved_menu, build = function()
        local rows = { { kind = "text", text = tour.name } }
        last = downloads_signature(app)
        local state, done, total = download_state(app, tour)
        local have, all = store:count(tour)
        if state == "running" then
            rows[#rows + 1] = { text = counted(s, "broadcast_saving", total, done, total) }
        elseif have < all then
            local stopped = (app.download_results or {})[tour.id] == "stopped"
            rows[#rows + 1] = { text = counted(s, "broadcast_resume", all - have, all - have), detail = stopped and s.broadcast_stopped or nil, callback = function()
                app:download_broadcast(tour)
                page:reload()
            end }
        end
        rows[#rows + 1] = { kind = "section", text = s.broadcast_rounds }
        for _, round in ipairs(tour.rounds) do
            local kept = store:readable(tour, round) ~= nil
            rows[#rows + 1] = {
                text = round.name,
                detail = not kept and s.broadcast_missing or (not round.finished and s.broadcast_unfinished or nil),
                dim = not kept,
                callback = kept and function() Broadcasts.saved_round(app, tour, round) end or nil,
            }
        end
        rows[#rows + 1] = { kind = "secondary", text = s.broadcast_delete, callback = function()
            app:ask{ text = s.broadcast_delete_ask, ok_text = s.broadcast_delete, on_ok = function()
                if app.downloads then
                    app.downloads:cancel("broadcast_" .. tour.id)
                end
                store:delete(tour)
                app:save_broadcast_index(BroadcastStore.without(app:saved_broadcasts(), tour.id))
                UIManager:close(page)
                changed()
            end }
        end }
        return rows
    end }
    page.on_download = function()
        if downloads_signature(app) ~= last then
            page:reload()
        end
    end
end

function Broadcasts.saved_round(app, tour, round)
    local s = app.strings
    local games = app:broadcast_store():round_games(tour, round, s)
    if not games or #games == 0 then
        app:info(s.broadcast_no_games)
        return
    end
    local rows = {}
    for _, game in ipairs(games) do
        rows[#rows + 1] = { kind = "game", text = game.text, detail = game.detail, callback = function()
            ReviewScreen.open(app, (review_of(game.game_text)))
        end }
    end
    app:open_list(round.name, rows)
end

return Broadcasts
