-- What the profile of a player shows besides its ratings, as text from the answers of Lichess: the recent activity,
-- the private notes, the FIDE player the account is linked to, the Puzzle Storm records and the top 10 of each
-- rating. It knows nothing about the screen or the network.
local Profile = {}

-- The ratings of the top 10 lists, in the order of the menu of a game.
Profile.TOP_PERFS = { "bullet", "blitz", "rapid", "classical", "correspondence" }

local function number(value)
    return type(value) == "number" and math.floor(value) or nil
end

-- The days of Lichess start at midnight UTC.
local function date_of(milliseconds)
    return os.date("!%Y-%m-%d", math.floor(milliseconds / 1000))
end

local function rating_change(s, score)
    local rp = type(score.rp) == "table" and score.rp or {}
    local before, after = number(rp.before), number(rp.after)
    return before and after and string.format(s.activity_rating, before, after) or nil
end

local function with_change(s, text, score)
    local change = rating_change(s, score)
    return change and (text .. " · " .. change) or text
end

-- The days of /api/user/{id}/activity, the last first: { { date, lines } }, only what the plugin has a word for.
function Profile.activity(s, data)
    local days = {}
    for _, day in ipairs(type(data) == "table" and data or {}) do
        local interval = type(day) == "table" and type(day.interval) == "table" and day.interval
        if interval and number(interval.start) then
            local lines = {}
            local games = type(day.games) == "table" and day.games or {}
            for _, key in ipairs(Profile.TOP_PERFS) do
                local score = games[key]
                if type(score) == "table" then
                    lines[#lines + 1] = with_change(s, string.format(s.activity_games, s.perf_names[key], number(score.win) or 0,
                        number(score.draw) or 0, number(score.loss) or 0), score)
                end
            end
            local puzzles = type(day.puzzles) == "table" and day.puzzles.score
            if type(puzzles) == "table" then
                lines[#lines + 1] = with_change(s, string.format(s.activity_puzzles, s.perf_names.puzzle, number(puzzles.win) or 0, number(puzzles.loss) or 0), puzzles)
            end
            if type(day.storm) == "table" and number(day.storm.runs) then
                lines[#lines + 1] = string.format(s.activity_storm, s.perf_names.storm, number(day.storm.score) or 0, number(day.storm.runs))
            end
            local moves = type(day.correspondenceMoves) == "table" and number(day.correspondenceMoves.nb)
            if moves then
                lines[#lines + 1] = string.format(s.activity_correspondence, moves)
            end
            local tournaments = type(day.tournaments) == "table" and number(day.tournaments.nb)
            if tournaments then
                lines[#lines + 1] = string.format(s.activity_tournaments, tournaments)
            end
            local follows = type(day.follows) == "table" and day.follows or {}
            for _, side in ipairs({ { "in", s.activity_followers }, { "out", s.activity_following } }) do
                -- The list of names is cut short on a busy day, and nb then has the whole count.
                local follow = type(follows[side[1]]) == "table" and follows[side[1]] or {}
                local count = number(follow.nb) or (type(follow.ids) == "table" and #follow.ids) or 0
                if count > 0 then
                    lines[#lines + 1] = string.format(side[2], count)
                end
            end
            if #lines > 0 then
                days[#days + 1] = { date = date_of(interval.start), lines = lines }
            end
        end
    end
    return days
end

-- The notes of /api/user/{id}/note, the last first: { { date, text } }.
function Profile.notes(data)
    local notes = {}
    for _, note in ipairs(type(data) == "table" and data or {}) do
        if type(note) == "table" and type(note.text) == "string" and note.text:match("%S") then
            local time = number(note.date)
            notes[#notes + 1] = { time = time or 0, date = time and os.date("%Y-%m-%d", math.floor(time / 1000)) or nil, text = note.text }
        end
    end
    table.sort(notes, function(a, b) return a.time > b.time end)
    return notes
end

-- The FIDE player of /api/fide/player/{id}, as lines; nil without a name.
function Profile.fide_lines(s, data)
    if type(data) ~= "table" or type(data.name) ~= "string" then
        return nil
    end
    local lines = { type(data.title) == "string" and (data.title .. " " .. data.name) or data.name }
    if type(data.federation) == "string" then
        lines[#lines + 1] = string.format(s.fide_federation, data.federation)
    end
    for _, item in ipairs({ { "standard", s.perf_names.classical }, { "rapid", s.perf_names.rapid }, { "blitz", s.perf_names.blitz } }) do
        local rating = number(data[item[1]])
        if rating then
            lines[#lines + 1] = string.format("%s: %d", item[2], rating)
        end
    end
    if number(data.year) then
        lines[#lines + 1] = string.format(s.fide_born, number(data.year))
    end
    return lines
end

-- The Puzzle Storm dashboard: the records, best first, and the days played, the last first.
function Profile.storm(s, data)
    local high = type(data) == "table" and type(data.high) == "table" and data.high or {}
    local records = {}
    for _, item in ipairs({ { "allTime", s.storm_all_time }, { "month", s.storm_month }, { "week", s.storm_week }, { "day", s.storm_day } }) do
        local score = number(high[item[1]])
        if score and score > 0 then
            records[#records + 1] = string.format(item[2], score)
        end
    end
    local days = {}
    for _, day in ipairs(type(data) == "table" and type(data.days) == "table" and data.days or {}) do
        if type(day) == "table" and type(day._id) == "string" and number(day.score) then
            days[#days + 1] = string.format(s.storm_day_row, day._id, number(day.score), number(day.runs) or 0)
        end
    end
    return records, days
end

-- The top 10 of /api/player for each rating of TOP_PERFS: { { key, players = { { id, name, title, rating } } } }.
function Profile.top10(data)
    local lists = {}
    for _, key in ipairs(Profile.TOP_PERFS) do
        local players = {}
        for _, user in ipairs(type(data) == "table" and type(data[key]) == "table" and data[key] or {}) do
            local perf = type(user) == "table" and type(user.perfs) == "table" and user.perfs[key]
            if type(perf) == "table" and type(user.id) == "string" and type(user.username) == "string" and number(perf.rating) then
                players[#players + 1] = { id = user.id, name = user.username, title = type(user.title) == "string" and user.title or nil, rating = number(perf.rating) }
            end
        end
        if #players > 0 then
            lists[#lists + 1] = { key = key, players = players }
        end
    end
    return lists
end

return Profile
