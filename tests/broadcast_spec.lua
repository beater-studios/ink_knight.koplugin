package.path = "./?.lua;" .. package.path
local Api = require("ink_knight/api")
local Broadcast = require("ink_knight/broadcast")
local I18n = require("ink_knight/i18n")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAILED: " .. name .. "\n  " .. tostring(err))
    end
end

local function eq(actual, expected, what)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
    end
end

local s = I18n.en

-- Two games of a round as /api/broadcast/round/{id}.pgn sends them, cut short.
local ROUND = [[
[Event "Round 10: Kazhgaleyev, Murtas - Georgiev, Kiril"]
[Site "https://lichess.org/broadcast/senior/round-10/rxDKpvAV/VPnpFyjk"]
[Result "*"]
[White "Kazhgaleyev, Murtas"]
[Black "Georgiev, Kiril"]
[WhiteElo "2532"]
[WhiteTitle "GM"]
[BlackElo "2512"]
[BlackTitle "GM"]
[Opening "Nimzo-Indian Defense: Sämisch Variation, Keres Variation"]
[GameURL "https://lichess.org/broadcast/senior/round-10/rxDKpvAV/VPnpFyjk"]

1. d4 { [%clk 1:28:54] } 1... Nf6 { [%clk 1:30:46] } 2. c4 { [%clk 1:29:19] } 2... e6 { [%clk 1:31:08] } 3. Nc3 { A comment. } ( 3. Nf3 b6 ) 3... Bb4 $1 { [%clk 1:29:36] } *


[Event "Round 10: Mikhalevski, Victor - Kotsur, Pavel"]
[Site "https://lichess.org/broadcast/senior/round-10/rxDKpvAV/05kVVEKb"]
[Result "1/2-1/2"]
[White "Mikhalevski, Victor"]
[Black "Kotsur, Pavel"]
[FEN "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"]
[SetUp "1"]
[GameURL "https://lichess.org/broadcast/senior/round-10/rxDKpvAV/05kVVEKb"]

1. e4 Kd7 1/2-1/2
]]

test("broadcast requests: none needs a token, and the ids are checked", function()
    eq(Api.broadcast_top(2).path, "/api/broadcast/top?page=2")
    eq(Api.broadcast_search("FIDE Candidates", 1).path, "/api/broadcast/search?q=FIDE%20Candidates&page=1")
    eq(Api.broadcast_tournament("yVOLKime").path, "/api/broadcast/yVOLKime")
    eq(Api.broadcast_players("yVOLKime").accept, "application/json")
    eq(Api.broadcast_round("rxDKpvAV").path, "/api/broadcast/-/-/rxDKpvAV")
    eq(Api.broadcast_round_pgn("rxDKpvAV").path, "/api/broadcast/round/rxDKpvAV.pgn")
    assert(not pcall(Api.broadcast_round, "../x"), "an id with a slash is refused")
    for _, request in ipairs({ Api.broadcast_top(1), Api.broadcast_search("x", 1), Api.broadcast_tournament("a"), Api.broadcast_players("a"), Api.broadcast_round("a"), Api.broadcast_round_pgn("a") }) do
        eq(request.anonymous, true, request.path .. " goes without the token")
    end
end)

test("clocks as a clock shows them", function()
    eq(Broadcast.clock_text(5334), "1:28:54")
    eq(Broadcast.clock_text(245), "4:05")
    eq(Broadcast.clock_text(-3), "0:00")
end)

test("a round in PGN: its games apart, their tags, and the game asked for", function()
    local games = Broadcast.split_games(ROUND)
    eq(#games, 2)
    local tags = Broadcast.tags(games[1])
    eq(tags.White, "Kazhgaleyev, Murtas")
    eq(Broadcast.tag_player(tags, "white"), "GM Kazhgaleyev 2532")
    eq(Broadcast.tag_player(Broadcast.tags(games[2]), "black"), "Kotsur")
    local text, found = Broadcast.find_game(ROUND, "05kVVEKb")
    eq(found.Result, "1/2-1/2")
    assert(text:find("Kd7", 1, true))
    eq(Broadcast.find_game(ROUND, "nothere"), nil)
end)

test("the main line of a game: moves with their clocks, without variations, marks or comments", function()
    local moves, fen = Broadcast.main_line(Broadcast.split_games(ROUND)[1])
    eq(fen, nil)
    eq(#moves, 6)
    eq(moves[1].uci, "d2d4")
    eq(moves[1].clock, 5334)
    eq(moves[5].san, "Nc3")
    eq(moves[5].clock, nil, "a move without a clock")
    eq(moves[6].san, "Bb4")
    eq(moves[6].clock, 5376)
    -- From the position of its FEN.
    moves, fen = Broadcast.main_line(Broadcast.split_games(ROUND)[2])
    eq(fen, "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1")
    eq(#moves, 2)
    eq(moves[2].uci, "e8d7")
end)

test("a PGN written badly: a stray brace, a tag with an escaped quote, a FEN that cannot be read", function()
    local moves = Broadcast.main_line('[Event "x"]\n\n1. e4 } e5 2. Nf3 *')
    eq(#moves, 3, "a stray brace says nothing")
    local tags, body = Broadcast.tags('[Event "A \\"B\\" Open"]\n[White "Back\\\\slash"]\n\n1. d4 *')
    eq(tags.Event, 'A "B" Open')
    eq(tags.White, "Back\\slash")
    eq(#Broadcast.main_line('[Event "A \\"B\\" Open"]\n\n1. d4 d5 *'), 2, "the tag is not read as moves")
    assert(not body:find("Event", 1, true))
    local none, fen = Broadcast.main_line('[FEN "not a fen"]\n\n1. e4 *')
    eq(#none, 0); eq(fen, nil)
end)

test("the games of a round as rows: players, then live with the clocks or the result with the ratings", function()
    local games = Broadcast.round_games(s, { games = {
        { id = "VPnpFyjk", status = "*", players = {
            { name = "Kazhgaleyev, Murtas", title = "GM", rating = 2532, clock = 422600 },
            { name = "Georgiev, Kiril", title = "GM", rating = 2512, clock = 332900 } } },
        { id = "05kVVEKb", status = "1/2-1/2", players = { { name = "Mikhalevski, Victor", rating = 2466 }, { name = "Kotsur, Pavel" } } },
        { id = "bad/id", status = "*" },
    } })
    eq(#games, 2, "a game with a strange id is left out")
    eq(games[1].text, "GM Kazhgaleyev x GM Georgiev")
    eq(games[1].detail, s.broadcast_live .. " · 1:10:26 · 55:29")
    eq(games[2].detail, "½-½ · 2466 · ?")
end)

test("standings as a score over the games played", function()
    eq(Broadcast.score_text(7.5, 9), "7½/9")
    eq(Broadcast.score_text(0.5, 1), "½/1")
    eq(Broadcast.score_text(0, 3), "0/3")
    eq(Broadcast.score_text(nil, 3), nil)
end)

test("kept broadcasts: the index read back, only rounds already started, the files that are missing", function()
    local BroadcastStore = require("ink_knight/broadcast_store")
    local files = {}
    local store = BroadcastStore.new{
        dir = "/kept",
        exists = function(path) return files[path] ~= nil end,
        remove = function(path) files[path] = nil end,
        rename = function(from, to) files[to], files[from] = files[from], nil end,
        make_dir = function() end,
        read = function(path) return files[path] end,
    }
    local entry = BroadcastStore.entry_of({ tour = { id = "yVOLKime", name = "Seniors" }, rounds = {
        { id = "r1", name = "Round 1", finished = true },
        { id = "r2", name = "Round 2", ongoing = true },
        { id = "r3", name = "Round 3" },
    } }, 100)
    eq(#entry.rounds, 2, "a round still to come has nothing to keep")
    eq(entry.rounds[2].finished, false)
    eq(BroadcastStore.entry_of({ tour = { id = "x" }, rounds = { { id = "r9", name = "Later" } } }), nil, "nothing started, nothing to keep")
    local todo = store:files(entry)
    eq(#todo, 2)
    eq(todo[1][1], "https://lichess.org/api/broadcast/round/r1.pgn")
    eq(todo[1][2], "/kept/yVOLKime/r1.pgn")
    files["/kept/yVOLKime/r1.pgn"] = ROUND
    eq(#store:files(entry), 1, "a round already kept is not asked again")
    local have, all = store:count(entry)
    eq(have, 1); eq(all, 2)
    files["/kept/yVOLKime/r2.pgn"] = "old round 2"
    store:set_aside_unfinished(entry)
    eq(files["/kept/yVOLKime/r2.pgn"], nil, "the round being played is set aside, to come back up to date")
    eq(#store:files(entry), 1, "and is asked for again")
    eq(files["/kept/yVOLKime/r1.pgn"] ~= nil, true, "the finished one stays")
    -- A download that failed gives the old file back; one that came keeps the new file.
    store:settle(entry)
    eq(files["/kept/yVOLKime/r2.pgn"], "old round 2")
    store:set_aside_unfinished(entry)
    files["/kept/yVOLKime/r2.pgn"] = "new round 2"
    store:settle(entry)
    eq(files["/kept/yVOLKime/r2.pgn"], "new round 2")
    eq(files["/kept/yVOLKime/r2.pgn.old"], nil)
    files["/kept/yVOLKime/r2.pgn"] = nil
    local games = store:round_games(entry, entry.rounds[1], s)
    eq(#games, 2)
    eq(games[1].text, "GM Kazhgaleyev x GM Georgiev")
    eq(games[1].detail, s.broadcast_unfinished .. " · 2532 · 2512")
    eq(games[2].detail, "½-½ · ? · ?")
    eq(store:round_games(entry, entry.rounds[2], s), nil, "a round without its file")
    -- The index keeps what fits, the last kept first, without a second copy of the same tournament.
    local index = BroadcastStore.read_index({ entry, { id = "bad/id", name = "x", rounds = {} }, { id = "other", name = "Other", rounds = { { id = "o1", name = "R1", finished = true } } } })
    eq(#index, 2)
    index = BroadcastStore.with_entry(index, BroadcastStore.entry_of({ tour = { id = "other", name = "Other" }, rounds = { { id = "o1", name = "R1", finished = true }, { id = "o2", name = "R2", finished = true } } }, 200))
    eq(index[1].id, "other"); eq(#index[1].rounds, 2); eq(#index, 2)
    eq(#BroadcastStore.without(index, "other"), 1)
    files["/kept/yVOLKime/r1.pgn.part"] = "half"
    files["/kept/yVOLKime"] = "folder"
    store:delete(entry)
    eq(files["/kept/yVOLKime/r1.pgn"], nil, "deleting takes the files")
    eq(files["/kept/yVOLKime/r1.pgn.part"], nil, "and what a download cut short left")
    eq(files["/kept/yVOLKime"], nil, "and the folder")
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
