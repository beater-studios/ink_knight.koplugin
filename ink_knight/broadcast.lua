-- Lichess broadcasts, the over-the-board tournaments Lichess relays: what the lists, the rounds and the games need,
-- read from the answers of Lichess. A round comes as PGN; only the game opened is read move by move, since reading
-- every move of a round would take seconds on a Kindle. No KOReader here, so the tests can use it.
local Chess = require("ink_knight/chess")

local Broadcast = {}

-- "1:28:54", or "4:05" under an hour, from seconds.
function Broadcast.clock_text(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours, minutes, secs = math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, secs)
    end
    return string.format("%d:%02d", minutes, secs)
end

-- The games of a PGN with several, as their own texts, without reading the moves.
function Broadcast.split_games(text)
    local games = {}
    local current
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^%[Event ") then
            current = {}
            games[#games + 1] = current
        end
        if current then
            current[#current + 1] = line
        end
    end
    for index, lines in ipairs(games) do
        games[index] = table.concat(lines, "\n")
    end
    return games
end

-- The tags of a game, { White = "...", ... }, and its moves without them. A tag is a line of its own, and its value
-- may hold an escaped quote or backslash, as PGN writes them.
function Broadcast.tags(game_text)
    local tags, body = {}, {}
    for line in (tostring(game_text) .. "\n"):gmatch("([^\n]*)\n") do
        local name, value = line:match('^%s*%[(%w+)%s+"(.*)"%]%s*$')
        if name then
            tags[name] = value:gsub("\\(.)", "%1")
        else
            body[#body + 1] = line
        end
    end
    return tags, table.concat(body, "\n")
end

local function clock_seconds(comment)
    local h, m, s = comment:match("%[%%clk (%d+):(%d+):(%d+)")
    if h then
        return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
    end
    return nil
end

-- The main line of a game: { { uci, san, clock } }, clock being the seconds left after the move when the PGN has
-- them, read with the rules from the starting position (the FEN tag, or the usual one). Variations and other
-- comments are left out. Stops at a move it cannot read; a FEN it cannot read gives no moves.
function Broadcast.main_line(game_text)
    local tags, body = Broadcast.tags(game_text)
    local position = Chess.parse_fen(tags.FEN or Chess.START_FEN)
    if not position then
        return {}, nil
    end
    local moves = {}
    local depth = 0
    local pos = 1
    while position and pos <= #body do
        local c = body:sub(pos, pos)
        if c == "{" then
            local stop = body:find("}", pos, true) or #body
            local comment = body:sub(pos + 1, stop - 1)
            local clock = depth == 0 and clock_seconds(comment)
            if clock and #moves > 0 then
                moves[#moves].clock = clock
            end
            pos = stop + 1
        elseif c == "(" then
            depth = depth + 1
            pos = pos + 1
        elseif c == ")" then
            depth = math.max(0, depth - 1)
            pos = pos + 1
        elseif c:match("%s") then
            pos = pos + 1
        else
            local token = body:match("^[^%s{}()]+", pos)
            if not token then
                -- A stray brace says nothing.
                pos = pos + 1
            elseif depth == 0 and not (token:match("^%d+%.+$") or token:match("^%$%d+$") or token == "*" or token == "1-0" or token == "0-1" or token == "1/2-1/2") then
                local san = (token:match("^%d+%.+(.+)$") or token):gsub("[!?]+$", "")
                local move = Chess.parse_san(position, san)
                if not move then
                    break
                end
                moves[#moves + 1] = { uci = Chess.move_to_uci(move), san = Chess.to_san(position, move) }
                position = Chess.play(position, move)
            end
            pos = pos + #(token or "")
        end
    end
    return moves, tags.FEN
end

-- "2532" or nil, from a rating Lichess may send as a number or leave out.
local function rating(value)
    return tonumber(value) and string.format("%d", value) or nil
end

-- "GM Kazhgaleyev, Murtas 2532".
function Broadcast.player_text(player)
    if type(player) ~= "table" then
        return "?"
    end
    local parts = {}
    parts[#parts + 1] = type(player.title) == "string" and player.title or nil
    parts[#parts + 1] = type(player.name) == "string" and player.name or "?"
    parts[#parts + 1] = rating(player.rating)
    return table.concat(parts, " ")
end

-- A player of a game of the PGN as the bars show them, short enough for one: "GM Kazhgaleyev 2532".
function Broadcast.tag_player(tags, color)
    local prefix = color == "white" and "White" or "Black"
    local short = Broadcast.short_player({ title = tags[prefix .. "Title"], name = tags[prefix] })
    local elo = rating(tonumber(tags[prefix .. "Elo"]))
    return elo and (short .. " " .. elo) or short
end

-- "GM Kazhgaleyev": the title and the surname, as broadcasts write names "Surname, Given name".
function Broadcast.short_player(player)
    if type(player) ~= "table" or type(player.name) ~= "string" then
        return "?"
    end
    local surname = player.name:match("^([^,]+),") or player.name
    return type(player.title) == "string" and (player.title .. " " .. surname) or surname
end

-- "1-0", "0-1" or "½-½".
function Broadcast.result_text(result)
    return (tostring(result or ""):gsub("1/2", "½"))
end

-- The games of a round as Lichess sends them, as a row shows each: text (the players) and detail (live with the
-- clocks while it goes on, the result with the ratings after), all the width left to the names. s: the texts.
function Broadcast.round_games(s, data)
    local games = {}
    for _, game in ipairs(type(data) == "table" and type(data.games) == "table" and data.games or {}) do
        if type(game) == "table" and type(game.id) == "string" and game.id:match("^%w+$") then
            local players = type(game.players) == "table" and game.players or {}
            local white, black = type(players[1]) == "table" and players[1] or {}, type(players[2]) == "table" and players[2] or {}
            local ongoing = game.status == "*" or game.status == nil
            local parts = { ongoing and s.broadcast_live or Broadcast.result_text(game.status) }
            if ongoing and tonumber(white.clock) and tonumber(black.clock) then
                -- Lichess sends the clocks of a round in hundredths of a second.
                parts[2] = string.format(s.broadcast_clocks, Broadcast.clock_text(white.clock / 100), Broadcast.clock_text(black.clock / 100))
            elseif rating(white.rating) or rating(black.rating) then
                parts[2] = string.format(s.broadcast_clocks, rating(white.rating) or "?", rating(black.rating) or "?")
            end
            games[#games + 1] = {
                id = game.id,
                text = string.format("%s x %s", Broadcast.short_player(white), Broadcast.short_player(black)),
                detail = table.concat(parts, " · "),
                ongoing = ongoing,
            }
        end
    end
    return games
end

-- "7½/9", or nil.
function Broadcast.score_text(score, played)
    score, played = tonumber(score), tonumber(played)
    if not score or not played then
        return nil
    end
    local whole = math.floor(score)
    local half = score - whole >= 0.5 and "½" or ""
    return string.format("%s%s/%d", (whole > 0 or half == "") and tostring(whole) or "", half, played)
end

-- The game of the round PGN whose GameURL or Site ends with the id of the game.
function Broadcast.find_game(round_pgn, id)
    for _, text in ipairs(Broadcast.split_games(round_pgn)) do
        local tags = Broadcast.tags(text)
        local url = tags.GameURL or tags.Site or ""
        if url:match("/([%w]+)$") == id then
            return text, tags
        end
    end
    return nil
end

return Broadcast
