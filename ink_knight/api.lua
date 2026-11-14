-- What each action asks of Lichess, as plain tables. Nothing here touches the network.
local Api = {}

Api.BASE = "https://lichess.org"
-- Where the plugin lives, in the User-Agent of every request, so Lichess knows which client it is and where to reach
-- its makers. Never anything about the reader.
Api.HOMEPAGE = "https://github.com/beater-studios/ink_knight.koplugin"

function Api.user_agent(version)
    return string.format("InkKnight/%s (+%s)", tostring(version), Api.HOMEPAGE)
end
-- The opening database asks for the token, and belongs to Lichess. The tablebase is public.
Api.EXPLORER = "https://explorer.lichess.org"
Api.TABLEBASE = "https://tablebase.lichess.org"
Api.COLORS = { "random", "white", "black" }
Api.RATING_MARGINS = { 0, 100, 200, 300, 500 }
Api.GIVE_TIME_SECONDS = 15
Api.PUZZLE_DAYS = 30
Api.PUZZLE_THEMES = {
    "mateIn1", "mateIn2", "mateIn3", "backRankMate", "fork", "pin", "skewer", "discoveredAttack",
    "sacrifice", "hangingPiece", "opening", "middlegame", "endgame", "rookEndgame", "pawnEndgame",
}
Api.REAL_TIME_SEEK = { { 10, 0 }, { 10, 5 }, { 15, 10 }, { 30, 0 }, { 30, 20 } }
Api.CHALLENGE_CLOCKS = { { 3, 2 }, { 5, 0 }, { 5, 3 }, { 10, 0 }, { 10, 5 }, { 15, 10 }, { 30, 0 } }
Api.DAYS = { 1, 2, 3, 5, 7, 10, 14 }
Api.AI_LEVELS = { 1, 2, 3, 4, 5, 6, 7, 8 }

-- A JSON null arrives as a special value that counts as true in Lua, so it goes away like a field that is absent.
function Api.without_nulls(value, null)
    for key, item in pairs(value) do
        if item == null then
            value[key] = nil
        elseif type(item) == "table" then
            Api.without_nulls(item, null)
        end
    end
    return value
end

local function encode(value)
    return (tostring(value):gsub("[^%w%-_%.~]", function(char)
        return string.format("%%%02X", char:byte())
    end))
end

local function form(fields)
    local parts = {}
    for _, field in ipairs(fields) do
        parts[#parts + 1] = encode(field[1]) .. "=" .. encode(field[2])
    end
    return table.concat(parts, "&")
end

-- Ids and names go in the path, and in a shell command, so only these characters ever get through.
function Api.is_safe_id(id)
    return type(id) == "string" and id:match("^[%w_%-]+$") ~= nil and #id <= 64
end

local function path_id(id)
    if not Api.is_safe_id(id) then
        error("invalid id")
    end
    return id
end

function Api.account()
    return { method = "GET", path = "/api/account", want_scopes = true }
end

function Api.playing()
    return { method = "GET", path = "/api/account/playing?nb=50" }
end

function Api.following()
    return { method = "GET", path = "/api/rel/following" }
end

function Api.stream_events()
    return { method = "GET", path = "/api/stream/event", stream = true }
end

function Api.stream_game(id)
    return { method = "GET", path = "/api/board/game/stream/" .. path_id(id), stream = true }
end

-- The kind of game Lichess counts a clock as, from its estimate of the length of a game.
function Api.perf_of_clock(minutes, increment)
    local estimate = minutes * 60 + 40 * increment
    if estimate < 180 then
        return "bullet"
    elseif estimate < 480 then
        return "blitz"
    elseif estimate < 1500 then
        return "rapid"
    end
    return "classical"
end

-- nil with no margin, and Lichess advises leaving it out unless the reader wants it.
function Api.rating_range(rating, margin)
    if not rating or not margin or margin <= 0 then
        return nil
    end
    return string.format("%d-%d", math.max(0, rating - margin), rating + margin)
end

-- The variants the plugin plays on Lichess, standard unless said otherwise.
Api.VARIANTS = { standard = true, chess960 = true }

local function variant_of(variant)
    return Api.VARIANTS[variant] and variant or "standard"
end

-- The color is left out of a seek, as Lichess advises, so it evens out the colors by itself.
local function seek_fields(rated, range, variant)
    local fields = { { "rated", rated and "true" or "false" }, { "variant", variant_of(variant) } }
    if range then
        fields[#fields + 1] = { "ratingRange", range }
    end
    return fields
end

-- A real-time seek stays open until a game starts: closing the connection cancels it.
function Api.seek_clock(minutes, increment, rated, range, variant)
    local fields = seek_fields(rated, range, variant)
    fields[#fields + 1] = { "time", minutes }
    fields[#fields + 1] = { "increment", increment }
    return { method = "POST", path = "/api/board/seek", stream = true, body = form(fields) }
end

function Api.seek_days(days, rated, range, variant)
    local fields = seek_fields(rated, range, variant)
    fields[#fields + 1] = { "days", days }
    return { method = "POST", path = "/api/board/seek", body = form(fields) }
end

function Api.challenge_clock(username, minutes, increment, rated, color, variant)
    return {
        method = "POST", path = "/api/challenge/" .. path_id(username),
        body = form({ { "rated", rated and "true" or "false" }, { "clock.limit", minutes * 60 }, { "clock.increment", increment }, { "color", color or "random" }, { "variant", variant_of(variant) } }),
    }
end

function Api.challenge_days(username, days, rated, color, variant)
    return {
        method = "POST", path = "/api/challenge/" .. path_id(username),
        body = form({ { "rated", rated and "true" or "false" }, { "days", days }, { "color", color or "random" }, { "variant", variant_of(variant) } }),
    }
end

-- Lichess refuses a rated game with no time limit, so this one never asks for it.
function Api.challenge_no_limit(username, color, variant)
    return {
        method = "POST", path = "/api/challenge/" .. path_id(username),
        body = form({ { "rated", "false" }, { "color", color or "random" }, { "variant", variant_of(variant) } }),
    }
end

-- Against the computer of Lichess itself. It is never rated. Without minutes or days, the game has no time limit.
function Api.challenge_ai(level, minutes, increment, color, days, variant)
    local fields = { { "level", level } }
    if minutes then
        fields[#fields + 1] = { "clock.limit", minutes * 60 }
        fields[#fields + 1] = { "clock.increment", increment }
    elseif days then
        fields[#fields + 1] = { "days", days }
    end
    fields[#fields + 1] = { "color", color or "random" }
    fields[#fields + 1] = { "variant", variant_of(variant) }
    return { method = "POST", path = "/api/challenge/ai", body = form(fields) }
end

function Api.accept_challenge(id)
    return { method = "POST", path = "/api/challenge/" .. path_id(id) .. "/accept" }
end

function Api.decline_challenge(id)
    return { method = "POST", path = "/api/challenge/" .. path_id(id) .. "/decline" }
end

function Api.cancel_challenge(id)
    return { method = "POST", path = "/api/challenge/" .. path_id(id) .. "/cancel" }
end

function Api.move(id, uci)
    if not tostring(uci):match("^[a-h][1-8][a-h][1-8][qrbn]?$") then
        error("invalid move")
    end
    return { method = "POST", path = "/api/board/game/" .. path_id(id) .. "/move/" .. uci }
end

function Api.resign(id)
    return { method = "POST", path = "/api/board/game/" .. path_id(id) .. "/resign" }
end

function Api.abort(id)
    return { method = "POST", path = "/api/board/game/" .. path_id(id) .. "/abort" }
end

function Api.draw(id, accept)
    return { method = "POST", path = "/api/board/game/" .. path_id(id) .. "/draw/" .. (accept and "yes" or "no") }
end

function Api.takeback(id, accept)
    return { method = "POST", path = "/api/board/game/" .. path_id(id) .. "/takeback/" .. (accept and "yes" or "no") }
end

function Api.claim_victory(id)
    return { method = "POST", path = "/api/board/game/" .. path_id(id) .. "/claim-victory" }
end

-- Only when the opponent left the game. A draw by repetition goes through Api.draw.
function Api.claim_draw(id)
    return { method = "POST", path = "/api/board/game/" .. path_id(id) .. "/claim-draw" }
end

function Api.give_time(id, seconds)
    return { method = "POST", path = "/api/round/" .. path_id(id) .. "/add-time/" .. tostring(math.floor(seconds)) }
end

function Api.follow(username)
    return { method = "POST", path = "/api/rel/follow/" .. path_id(username) }
end

function Api.unfollow(username)
    return { method = "POST", path = "/api/rel/unfollow/" .. path_id(username) }
end

function Api.block(username)
    return { method = "POST", path = "/api/rel/block/" .. path_id(username) }
end

function Api.unblock(username)
    return { method = "POST", path = "/api/rel/unblock/" .. path_id(username) }
end

function Api.user(username)
    return { method = "GET", path = "/api/user/" .. path_id(username) }
end

function Api.rating_history(username)
    return { method = "GET", path = "/api/user/" .. path_id(username) .. "/rating-history" }
end

function Api.perf_stats(username, perf)
    return { method = "GET", path = "/api/user/" .. path_id(username) .. "/perf/" .. path_id(perf) }
end

-- This one needs preference:read, an optional permission of the token.
function Api.preferences()
    return { method = "GET", path = "/api/account/preferences" }
end

function Api.user_activity(username)
    return { method = "GET", path = "/api/user/" .. path_id(username) .. "/activity" }
end

function Api.user_notes(username)
    return { method = "GET", path = "/api/user/" .. path_id(username) .. "/note" }
end

function Api.write_note(username, text)
    return { method = "POST", path = "/api/user/" .. path_id(username) .. "/note", body = form({ { "text", text } }) }
end

function Api.fide_player(fide_id)
    return { method = "GET", path = string.format("/api/fide/player/%d", fide_id) }
end

function Api.storm_dashboard(username, days)
    return { method = "GET", path = string.format("/api/storm/dashboard/%s?days=%d", path_id(username), days) }
end

function Api.top10()
    return { method = "GET", path = "/api/player" }
end

function Api.crosstable(first, second)
    return { method = "GET", path = "/api/crosstable/" .. path_id(first) .. "/" .. path_id(second) }
end

function Api.search_players(term)
    return { method = "GET", path = "/api/player/autocomplete?object=true&term=" .. encode(term) }
end

-- Lichess answers for up to 100 players at a time.
function Api.players_status(ids)
    local safe = {}
    for _, id in ipairs(ids) do
        if #safe < 100 then
            safe[#safe + 1] = path_id(id)
        end
    end
    return { method = "GET", path = "/api/users/status?ids=" .. table.concat(safe, ",") }
end

-- The finished games of a player, one JSON per line, with the moves in the usual notation.
function Api.past_games(username, max)
    return {
        method = "GET", accept = "application/x-ndjson",
        path = string.format("/api/games/user/%s?max=%d&moves=true&clocks=false&evals=true&accuracy=true&division=true&opening=true&finished=true", path_id(username), max or 30),
    }
end

-- One game, finished or not, as a single JSON with the same fields as a game of past_games.
function Api.game_export(id)
    return {
        method = "GET", accept = "application/json",
        path = "/game/export/" .. path_id(id) .. "?moves=true&clocks=false&evals=true&accuracy=true&division=true&opening=true",
    }
end

function Api.bookmarks(max)
    return {
        method = "GET", accept = "application/x-ndjson",
        path = string.format("/api/games/export/bookmarks?max=%d&moves=true&clocks=false&evals=true&accuracy=true&division=true&opening=true", max or 30),
    }
end

-- This one needs preference:write, an optional permission of the token.
function Api.bookmark(id, add)
    return { method = "POST", path = "/bookmark/" .. path_id(id) .. "?v=" .. (add and "true" or "false") }
end

function Api.cloud_eval(fen)
    return { method = "GET", path = "/api/cloud-eval?fen=" .. encode(fen) }
end

function Api.explorer(fen)
    return { method = "GET", base = Api.EXPLORER, path = "/lichess?moves=5&topGames=0&recentGames=0&fen=" .. encode(fen) }
end

function Api.explorer_masters(fen)
    return { method = "GET", base = Api.EXPLORER, path = "/masters?moves=5&topGames=0&fen=" .. encode(fen) }
end

-- Lichess sends a new line as it indexes the player's games, the last one complete.
function Api.explorer_player(fen, player, color)
    return {
        method = "GET", base = Api.EXPLORER, accept = "application/x-ndjson",
        path = string.format("/player?player=%s&color=%s&moves=5&recentGames=0&fen=%s", encode(player), color, encode(fen)),
    }
end

function Api.tablebase(fen)
    return { method = "GET", base = Api.TABLEBASE, path = "/standard?fen=" .. encode(fen) }
end

function Api.puzzle_daily()
    return { method = "GET", path = "/api/puzzle/daily" }
end

-- difficulty: easiest to hardest, relative to the reader's puzzle rating. color: white or black, the side the
-- reader plays; nil for either, half and half. Lichess draws three times as many and keeps that color.
local PUZZLE_DIFFICULTIES = { easiest = true, easier = true, normal = true, harder = true, hardest = true }
function Api.puzzle_batch(count, angle, difficulty, color)
    local path = string.format("/api/puzzle/batch/%s?nb=%d", path_id(angle or "mix"), count)
    if PUZZLE_DIFFICULTIES[difficulty] then
        path = path .. "&difficulty=" .. difficulty
    end
    if color == "white" or color == "black" then
        path = path .. "&color=" .. color
    end
    return { method = "GET", path = path }
end

function Api.puzzle_results(body, angle)
    return { method = "POST", path = "/api/puzzle/batch/" .. path_id(angle or "mix"), body = body, content_type = "application/json" }
end

-- The ids of the puzzles missed in the last days and not solved since, for all themes.
function Api.puzzle_replay(days)
    return { method = "GET", path = string.format("/api/puzzle/replay/%d/mix", days) }
end

function Api.puzzle_by_id(id)
    return { method = "GET", path = "/api/puzzle/" .. path_id(id) }
end

-- before is in milliseconds.
function Api.puzzle_activity(max, before)
    local path = string.format("/api/puzzle/activity?max=%d", max)
    if before then
        path = path .. string.format("&before=%d", before)
    end
    return { method = "GET", accept = "application/x-ndjson", path = path }
end

-- Broadcasts: over-the-board tournaments Lichess relays. None needs a token, and they go without one (anonymous):
-- a round is a study on Lichess, so with a token that lacks study:read the tournament and the round are refused.
function Api.broadcast_top(page)
    return { method = "GET", anonymous = true, path = string.format("/api/broadcast/top?page=%d", page or 1) }
end

function Api.broadcast_search(term, page)
    return { method = "GET", anonymous = true, path = string.format("/api/broadcast/search?q=%s&page=%d", encode(term), page or 1) }
end

function Api.broadcast_tournament(id)
    return { method = "GET", anonymous = true, path = "/api/broadcast/" .. path_id(id) }
end

function Api.broadcast_players(id)
    return { method = "GET", anonymous = true, path = "/broadcast/" .. path_id(id) .. "/players", accept = "application/json" }
end

-- The games of a round, each with its position, players and clocks; the slugs before the id may be anything.
function Api.broadcast_round(id)
    return { method = "GET", anonymous = true, path = "/api/broadcast/-/-/" .. path_id(id) }
end

function Api.broadcast_round_pgn(id)
    return { method = "GET", anonymous = true, path = "/api/broadcast/round/" .. path_id(id) .. ".pgn", accept = "application/x-chess-pgn" }
end

-- Studies: public ones answer without a token; the private ones of the reader need study:read, and a token without it
-- is refused even for public ones, so the token goes only when it has that permission (anonymous otherwise).
function Api.study_list(username, anonymous)
    return { method = "GET", path = "/api/study/by/" .. path_id(username), accept = "application/x-ndjson", anonymous = anonymous }
end

-- The whole study in PGN, with comments, variations and drawings, without the clocks a study of a game may carry.
function Api.study_pgn(id)
    return { method = "GET", path = "/api/study/" .. path_id(id) .. ".pgn?clocks=false", accept = "application/x-chess-pgn" }
end

-- The openings Lichess has puzzles of, by family, the way its app asks for them: a page of the site that answers
-- JSON when asked to.
function Api.puzzle_openings()
    return { method = "GET", path = "/training/openings" }
end

function Api.puzzle_dashboard(days)
    return { method = "GET", path = string.format("/api/puzzle/dashboard/%d", days) }
end

-- Whose turn first, then the least time left: what needs an answer sooner comes on top.
function Api.sort_games(games)
    table.sort(games, function(a, b)
        if (a.isMyTurn == true) ~= (b.isMyTurn == true) then
            return a.isMyTurn == true
        end
        local left_a, left_b = a.secondsLeft or math.huge, b.secondsLeft or math.huge
        if left_a ~= left_b then
            return left_a < left_b
        end
        return tostring(a.gameId) < tostring(b.gameId)
    end)
    return games
end

-- A readable time for the list: minutes up to two hours, then hours, then days.
function Api.format_left(seconds)
    if not seconds then
        return ""
    end
    if seconds < 7200 then
        return string.format("%d min", math.max(0, math.ceil(seconds / 60)))
    end
    if seconds < 172800 then
        return string.format("%d h", math.floor(seconds / 3600))
    end
    return string.format("%d d", math.floor(seconds / 86400))
end

-- An evaluation in the view of white: a mate in so many moves, or pawns with two decimals.
function Api.eval_text(cp, mate)
    if mate then
        return "#" .. tostring(mate)
    elseif cp then
        return string.format("%+.2f", cp / 100)
    end
    return "?"
end

function Api.format_count(count)
    if count >= 1000000 then
        return string.format("%.1fM", count / 1000000)
    elseif count >= 1000 then
        return string.format("%.1fk", count / 1000)
    end
    return tostring(count)
end

-- "white", "black" or "draw", or nil when the tablebase is not sure. A category speaks for the side to move.
function Api.tablebase_winner(category, turn)
    if category == "draw" or category == "cursed-win" or category == "blessed-loss" then
        return "draw"
    elseif category == "win" or category == "syzygy-win" then
        return turn == "w" and "white" or "black"
    elseif category == "loss" or category == "syzygy-loss" then
        return turn == "w" and "black" or "white"
    end
    return nil
end

function Api.clock_label(minutes, increment)
    return string.format("%d+%d", minutes, increment)
end

-- Incoming challenges wait for an answer. Those the reader sent are not listed as questions.
function Api.is_incoming(challenge, my_id)
    local challenger = challenge.challenger and challenge.challenger.id
    return challenger ~= nil and my_id ~= nil and challenger:lower() ~= my_id:lower()
end

function Api.is_outgoing(challenge, my_id)
    local challenger = challenge.challenger and challenge.challenger.id
    return challenger ~= nil and my_id ~= nil and challenger:lower() == my_id:lower()
end

-- Lichess only sends a ready text for a clock, so the other two kinds need their own.
function Api.time_control_text(control, no_limit, days_label)
    control = control or {}
    if control.type == "unlimited" then
        return no_limit
    elseif control.type == "correspondence" and control.daysPerTurn then
        return days_label(control.daysPerTurn)
    end
    return control.show or ""
end

function Api.challenge_is_supported(challenge)
    local variant = challenge.variant and challenge.variant.key
    return variant == nil or Api.VARIANTS[variant] == true
end

return Api
