-- Finding players and looking at them: search, who the reader follows, profile, rating and games against them.
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")

local Api = require("ink_knight/api")
local ChartScreen = require("ink_knight/ui/chart_screen")
local Profile = require("ink_knight/profile")
local RatingChart = require("ink_knight/rating_chart")

local Players = {}

-- Lichess only searches from this many letters on. A shorter name is taken as it was typed.
local SEARCH_MIN_LETTERS = 4
-- These have runs instead of games, and no rating over time.
local NO_CHART = { storm = true, racer = true, streak = true }

function Players.menu(app)
    local s = app.strings
    local function open(username) Players.show(app, username) end
    app:choose(s.players, {
        { text = s.search_player, callback = function() Players.ask_name(app, open) end },
        { text = s.players_following, callback = function()
            app:with_feature("following", function() Players.pick(app, s.players_following, open, true) end)
        end },
        { text = s.rankings, callback = function() Players.show_rankings(app) end },
    })
end

-- Who the reader follows, with who is online. To choose an opponent, a name can be typed too, and with nobody
-- to show it goes straight to that. only_list is for looking at the list itself, and says when it is empty.
function Players.pick(app, title, on_pick, only_list)
    local s = app.strings
    if not app:allows("following") then
        Players.ask_name(app, on_pick)
        return
    end
    app.net:request(Api.following(), function(status, body)
        if only_list and status ~= 200 then
            app:info(app:error_text(status))
            return
        end
        local users = {}
        if status == 200 then
            for line in tostring(body):gmatch("[^\n]+") do
                local user = app.decode(line)
                if user and Api.is_safe_id(user.id) and user.username then
                    users[#users + 1] = user
                end
            end
        end
        if #users == 0 then
            if only_list then
                app:info(s.not_following_anyone)
            else
                Players.ask_name(app, on_pick)
            end
            return
        end
        table.sort(users, function(a, b) return a.username:lower() < b.username:lower() end)
        local ids = {}
        for _, user in ipairs(users) do
            ids[#ids + 1] = user.id
        end
        app.net:request(Api.players_status(ids), function(status_code, status_body)
            local online = {}
            local list = status_code == 200 and app.decode(status_body) or {}
            for _, entry in ipairs(list) do
                online[entry.id] = entry.online == true
            end
            local rows = {}
            if not only_list then
                rows[1] = { text = s.type_name, bold = true, callback = function() Players.ask_name(app, on_pick) end }
            end
            for _, user in ipairs(users) do
                rows[#rows + 1] = {
                    text = user.username,
                    value = online[user.id] and s.online or nil,
                    callback = function() on_pick(user.username) end,
                }
            end
            app:open_list(title, rows)
        end)
    end)
end

function Players.ask_name(app, on_pick)
    local s = app.strings
    local dialog
    dialog = InputDialog:new{
        title = s.username_title,
        buttons = { {
            { text = s.cancel, id = "close", callback = function() UIManager:close(dialog) end },
            { text = s.send, is_enter_default = true, callback = function()
                local name = (dialog:getInputText() or ""):gsub("%s+", "")
                UIManager:close(dialog)
                if not Api.is_safe_id(name) then
                    app:info(s.player_not_found)
                elseif #name < SEARCH_MIN_LETTERS then
                    on_pick(name)
                else
                    Players.search(app, name, on_pick)
                end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Players.search(app, term, on_pick)
    local s = app.strings
    app.net:request(Api.search_players(term), function(status, body)
        app:report_or(status, function()
            local data = app.decode(body) or {}
            local rows = {}
            for _, user in ipairs(data.result or {}) do
                if Api.is_safe_id(user.id) then
                    local name = user.name or user.id
                    rows[#rows + 1] = {
                        text = (user.title and (user.title .. " ") or "") .. name,
                        value = user.online and s.online or nil,
                        callback = function() on_pick(name) end,
                    }
                end
            end
            if #rows == 0 then
                app:info(s.player_not_found)
            else
                app:open_list(s.players, rows)
            end
        end)
    end)
end

function Players.show(app, username)
    local s = app.strings
    if not Api.is_safe_id(username) then
        return
    end
    app.net:request(Api.user(username), function(status, body)
        if status == 404 then
            app:info(s.player_not_found)
            return
        end
        app:report_or(status, function()
            local user = app.decode(body) or {}
            -- Every button of the profile puts the id in a path, so an answer without a usable one keeps the id
            -- that was asked for, which Lichess writes in lower case.
            if not Api.is_safe_id(user.id) then
                user.id = username:lower()
            end
            Players.open_profile(app, user)
        end)
    end)
end

local function rating_row(app, user, name, key)
    local s = app.strings
    local perf = user.perfs[key]
    local games = perf.games or perf.runs or 0
    local label = s.perf_names[key]
    -- The question mark is how Lichess shows a rating it is not sure of yet, so players know it from the site. The
    -- puzzle modes have a best score instead.
    local row = { text = string.format("%s: %d%s", label, perf.rating or perf.score, perf.prov and "?" or "") }
    if games == 0 then
        row.value = s.no_rating
        return row
    end
    if perf.runs and not perf.games then
        row.value = string.format(s.perf_runs, perf.runs)
    else
        row.value = games == 1 and s.perf_row_one or string.format(s.perf_row, games)
    end
    if key == "storm" then
        row.callback = function() Players.show_storm(app, user.id) end
    elseif not NO_CHART[key] then
        row.callback = function() Players.show_perf(app, user.id, name, key, label) end
    end
    return row
end

function Players.open_profile(app, user)
    local s = app.strings
    local mine = user.id == app.my_id
    local name = user.username or user.id or "?"
    local title = user.online and (name .. " · " .. s.online) or name
    app:open_page{ title = title, build = function(page)
        local rows = {}
        if not mine then
            rows[#rows + 1] = { kind = "primary", text = s.challenge_player, callback = function() app:challenge_time_menu(name) end }
            -- Lichess answers "ok" and records nothing for a player who does not accept followers.
            if user.following or user.followable ~= false then
                rows[#rows + 1] = {
                    text = user.following and s.unfollow_player or s.follow_player,
                    callback = function() Players.toggle_follow(app, user, name, page) end,
                }
            end
            if app.my_id then
                rows[#rows + 1] = { text = s.crosstable, callback = function() Players.show_crosstable(app, user, name) end }
                rows[#rows + 1] = {
                    text = user.blocking and s.unblock_player or s.block_player,
                    callback = function() Players.toggle_block(app, user, name, page) end,
                }
            end
        end
        rows[#rows + 1] = { text = s.past_games, callback = function()
            if mine then
                app:past_games_menu()
            else
                app:show_past_games(user.id, name)
            end
        end }
        rows[#rows + 1] = { text = s.profile_activity, callback = function() Players.show_activity(app, user.id) end }
        rows[#rows + 1] = { text = s.studies, callback = function() require("ink_knight/ui/studies").list(app, user.id, name) end }
        -- The notes are the reader's own, about someone else, and need an optional permission of their own.
        if not mine and app.my_id then
            rows[#rows + 1] = { text = s.profile_notes, callback = function()
                app:with_feature("notes", function() Players.show_notes(app, user.id, name) end)
            end }
        end
        -- Only an account linked to a FIDE player has an id; a rating typed in the profile is not checked.
        local fide_id = tonumber(user.fideId)
        if fide_id and fide_id > 0 then
            rows[#rows + 1] = { text = s.profile_fide, callback = function() Players.show_fide(app, math.floor(fide_id)) end }
        end
        rows[#rows + 1] = { kind = "section", text = s.ratings_section }
        local keys = {}
        -- Only what is played here: the variants other than Chess960 stay out of the list.
        for key in pairs(user.perfs or {}) do
            if s.perf_names[key] then
                keys[#keys + 1] = key
            end
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local perf = user.perfs[key]
            if type(perf) == "table" and (perf.rating or (NO_CHART[key] and perf.score and (perf.runs or 0) > 0)) then
                rows[#rows + 1] = rating_row(app, user, name, key)
            end
        end
        return rows
    end }
end

local function is_open(app, page)
    for _, other in ipairs(app.pages or {}) do
        if other == page then
            return true
        end
    end
    return false
end

-- Following and blocking are one relation on Lichess: a block drops the follow, and a follow replaces the block. So
-- after either change the profile is asked again for both, and the rows say what Lichess has recorded. field is
-- "following" or "blocking", and on is what the reader asked for.
local function change_relation(app, user, name, page, field, on)
    local s = app.strings
    local request
    if field == "following" then
        request = on and Api.follow(user.id) or Api.unfollow(user.id)
    else
        request = on and Api.block(user.id) or Api.unblock(user.id)
    end
    app.net:request(request, function(status)
        app:report_or(status, function()
            app.net:request(Api.user(user.id), function(check_status, body)
                local fresh = check_status == 200 and app.decode(body)
                if fresh then
                    user.following = fresh.following == true
                    user.blocking = fresh.blocking == true
                    user.followable = fresh.followable
                else
                    user[field] = on
                    if on then
                        user[field == "following" and "blocking" or "following"] = false
                    end
                end
                -- The reader may have left the profile while the two answers came.
                if not is_open(app, page) then
                    return
                end
                page:reload()
                if user[field] ~= on then
                    app:info(s.follow_not_saved)
                elseif field == "following" then
                    app:info(string.format(on and s.followed or s.unfollowed, name))
                else
                    app:info(string.format(on and s.blocked or s.unblocked, name))
                end
            end)
        end)
    end)
end

function Players.toggle_follow(app, user, name, page)
    app:with_feature("follow_change", function()
        change_relation(app, user, name, page, "following", not user.following)
    end)
end

-- Blocking asks first, saying what it does to a follow too; unblocking does not ask.
function Players.toggle_block(app, user, name, page)
    local s = app.strings
    app:with_feature("follow_change", function()
        if user.blocking then
            change_relation(app, user, name, page, "blocking", false)
            return
        end
        local text = string.format(s.block_confirm, name)
        if user.following then
            text = text .. " " .. s.block_unfollows
        end
        app:ask{ title = s.block_player, text = text, ok_text = s.block_player, on_ok = function()
            change_relation(app, user, name, page, "blocking", true)
        end }
    end)
end

function Players.show_crosstable(app, user, name)
    local s = app.strings
    app.net:request(Api.crosstable(app.my_id, user.id), function(status, body)
        app:report_or(status, function()
            local data = app.decode(body) or {}
            if (data.nbGames or 0) == 0 then
                app:info(s.crosstable_empty)
                return
            end
            local scores = data.users or {}
            app:open_list(s.crosstable, {
                { kind = "stat", text = s.crosstable_you, value = tostring(scores[app.my_id] or 0) },
                { kind = "stat", text = name, value = tostring(scores[user.id] or 0) },
                { kind = "stat", text = s.crosstable_games, value = tostring(data.nbGames) },
            })
        end)
    end)
end

-- These pages open over the profile, so their title is the part and the player is the page under them.
function Players.show_activity(app, user_id)
    local s = app.strings
    app.net:request(Api.user_activity(user_id), function(status, body)
        app:report_or(status, function()
            local days = Profile.activity(s, app.decode(body))
            if #days == 0 then
                app:info(s.activity_none)
                return
            end
            local rows = {}
            for _, day in ipairs(days) do
                rows[#rows + 1] = { kind = "section", text = day.date }
                rows[#rows + 1] = { kind = "text", text = table.concat(day.lines, "\n") }
            end
            app:open_list(s.profile_activity, rows)
        end)
    end)
end

-- The reader's notes about a player, which only the reader sees, and a new one written on the device.
function Players.show_notes(app, user_id, name)
    local s = app.strings
    app.net:request(Api.user_notes(user_id), function(status, body)
        app:report_or(status, function()
            local page
            local rows = { { kind = "primary", text = s.note_write, callback = function() Players.write_note(app, user_id, name, page) end } }
            local notes = Profile.notes(app.decode(body))
            if #notes == 0 then
                rows[#rows + 1] = { kind = "text", text = s.notes_none, center = true }
            end
            for _, note in ipairs(notes) do
                if note.date then
                    rows[#rows + 1] = { kind = "section", text = note.date }
                end
                rows[#rows + 1] = { kind = "text", text = note.text }
            end
            page = app:open_list(s.profile_notes, rows)
        end)
    end)
end

-- page: the notes, opened again with the new one once it is saved.
function Players.write_note(app, user_id, name, page)
    local s = app.strings
    local dialog
    dialog = InputDialog:new{
        title = string.format(s.note_title, name),
        allow_newline = true,
        buttons = { {
            { text = s.cancel, id = "close", callback = function() UIManager:close(dialog) end },
            { text = s.note_save, id = "save", is_enter_default = true, callback = function()
                local text = dialog:getInputText() or ""
                UIManager:close(dialog)
                if not text:match("%S") then
                    return
                end
                app.net:request(Api.write_note(user_id, text), function(status)
                    app:report_or(status, function()
                        app:info(s.note_saved)
                        if page then
                            UIManager:close(page)
                            Players.show_notes(app, user_id, name)
                        end
                    end)
                end)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Players.show_fide(app, fide_id)
    local s = app.strings
    app.net:request(Api.fide_player(fide_id), function(status, body)
        app:report_or(status, function()
            local lines = Profile.fide_lines(s, app.decode(body))
            if not lines then
                app:info(s.unexpected_error)
                return
            end
            app:open_list(s.profile_fide, { { kind = "text", text = table.concat(lines, "\n") } })
        end)
    end)
end

function Players.show_storm(app, user_id)
    local s = app.strings
    app.net:request(Api.storm_dashboard(user_id, 30), function(status, body)
        app:report_or(status, function()
            local records, days = Profile.storm(s, app.decode(body))
            local rows = {}
            if #records > 0 then
                rows[#rows + 1] = { kind = "text", text = table.concat(records, "\n") }
            end
            if #days > 0 then
                rows[#rows + 1] = { kind = "section", text = s.storm_days }
                rows[#rows + 1] = { kind = "text", text = table.concat(days, "\n") }
            end
            if #rows == 0 then
                app:info(s.storm_none)
                return
            end
            app:open_list(s.perf_names.storm, rows)
        end)
    end)
end

function Players.show_rankings(app)
    local s = app.strings
    app.net:request(Api.top10(), function(status, body)
        app:report_or(status, function()
            local rows = {}
            for _, list in ipairs(Profile.top10(app.decode(body))) do
                rows[#rows + 1] = { kind = "section", text = s.perf_names[list.key] }
                for index, player in ipairs(list.players) do
                    rows[#rows + 1] = {
                        text = string.format("%d. %s", index, player.title and (player.title .. " " .. player.name) or player.name),
                        value = tostring(player.rating),
                        callback = function() Players.show(app, player.id) end,
                    }
                end
            end
            if #rows == 0 then
                app:info(s.unexpected_error)
                return
            end
            app:open_list(s.rankings, rows)
        end)
    end)
end

-- The statistics are a bonus: without them, the chart still opens.
function Players.show_perf(app, user_id, name, key, label)
    app.net:request(Api.rating_history(user_id), function(status, body)
        app:report_or(status, function()
            local points = RatingChart.points(app.decode(body), key)
            app.net:request(Api.perf_stats(user_id, key), function(stats_status, stats_body)
                UIManager:show(ChartScreen:new{
                    title = string.format("%s · %s", name, label),
                    points = points,
                    stats = stats_status == 200 and app.decode(stats_body) or nil,
                    strings = app.strings,
                })
            end)
        end)
    end)
end

return Players
