package.path = "./?.lua;" .. package.path
local Api = require("ink_knight/api")
local Chess = require("ink_knight/chess")
local Game = require("ink_knight/game")
local Tls = require("ink_knight/tls")
local Net = require("ink_knight/net")

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
local function eq(actual, expected)
    if actual ~= expected then
        error(string.format("expected %s, got %s", tostring(expected), tostring(actual)), 2)
    end
end
local function pos(fen) return assert(Chess.parse_fen(fen)) end
local function has_move(position, uci)
    for _, move in ipairs(Chess.legal_moves(position)) do
        if Chess.move_to_uci(move) == uci then return true end
    end
    return false
end

-- Known counts of positions: any mistake in the rules changes them.
local PERFT = {
    { "start", Chess.START_FEN, { 20, 400, 8902 } },
    { "kiwipete", "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", { 48, 2039, 97862 } },
    { "endgame", "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", { 14, 191, 2812 } },
    { "promotions", "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", { 6, 264, 9467 } },
    { "mirror", "r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1", { 6, 264, 9467 } },
    { "bugs", "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", { 44, 1486, 62379 } },
}
for _, case in ipairs(PERFT) do
    test("perft " .. case[1], function()
        for depth, count in ipairs(case[3]) do
            eq(Chess.perft(pos(case[2]), depth), count)
        end
    end)
end

test("square names go both ways", function()
    eq(Chess.square_name(1), "a1"); eq(Chess.square_name(64), "h8")
    eq(Chess.square_from_name("e4"), 29); eq(Chess.square_from_name("z9"), nil)
end)

test("an invalid FEN is refused", function()
    eq(Chess.parse_fen("not a fen"), nil)
    eq(Chess.parse_fen("9/8/8/8/8/8/8/8/x w - -"), nil)
end)

test("castling cannot cross an attacked square", function()
    local position = pos("4k3/8/8/8/8/5r2/8/4K2R w K - 0 1")
    eq(has_move(position, "e1g1"), false)
end)

test("castling is not possible while in check", function()
    eq(has_move(pos("4k3/8/8/8/8/4r3/8/4K2R w K - 0 1"), "e1g1"), false)
end)

test("castling moves the rook too", function()
    local position = assert(Chess.apply_uci(pos("4k3/8/8/8/8/8/8/4K2R w K - 0 1"), "e1g1"))
    eq(position.board[Chess.square_from_name("f1")], "R")
    eq(position.board[Chess.square_from_name("h1")], nil)
    eq(position.board[Chess.square_from_name("g1")], "K")
end)

test("castling written as the king taking its rook is understood", function()
    local position = assert(Chess.apply_uci(pos("4k3/8/8/8/8/8/8/4K2R w K - 0 1"), "e1h1"))
    eq(position.board[Chess.square_from_name("g1")], "K")
    eq(position.board[Chess.square_from_name("f1")], "R")
end)

test("en passant removes the pawn that passed", function()
    local position = Chess.from_moves(nil, "e2e4 a7a6 e4e5 d7d5 e5d6")
    eq(position.board[Chess.square_from_name("d5")], nil)
    eq(position.board[Chess.square_from_name("d6")], "P")
end)

test("promotion gives the chosen piece", function()
    local position = assert(Chess.apply_uci(pos("8/P6k/8/8/8/8/8/K7 w - - 0 1"), "a7a8n"))
    eq(position.board[Chess.square_from_name("a8")], "N")
    local targets = Chess.targets_from(pos("8/P6k/8/8/8/8/8/K7 w - - 0 1"), Chess.square_from_name("a7"))
    eq(#targets[Chess.square_from_name("a8")], 4)
end)

test("a pinned piece cannot leave the line", function()
    eq(has_move(pos("4r2k/8/8/8/8/8/4N3/4K3 w - - 0 1"), "e2c3"), false)
end)

test("a checkmate has no moves", function()
    local position = Chess.from_moves(nil, "f2f3 e7e5 g2g4 d8h4")
    eq(#Chess.legal_moves(position), 0)
    eq(Chess.in_check(position), true)
end)

test("the last move comes with the position", function()
    local _, last = Chess.from_moves(nil, "e2e4 e7e5")
    eq(Chess.square_name(last.to), "e5")
end)

test("a game follows the stream", function()
    local game = Game.new("abc", "Me")
    game:on_event({ type = "gameFull", speed = "rapid", rated = true, clock = { initial = 600000, increment = 0 },
        white = { id = "me", name = "Me", rating = 1500 }, black = { id = "other", name = "Other", rating = 1600 },
        state = { moves = "e2e4", wtime = 600000, btime = 600000, status = "started" } }, 100)
    eq(game.my_color, "w"); eq(game.black_name, "Other"); eq(game:is_my_turn(), false); eq(game:is_live(), true)
    game:on_event({ type = "gameState", moves = "e2e4 e7e5", wtime = 590000, btime = 595000, status = "started" }, 200)
    eq(game:is_my_turn(), true)
    eq(game.position.board[Chess.square_from_name("e5")], "p")
    eq(Chess.square_name(game.last_move.to), "e5")
    eq(game:time_left("w", 210), 580000)
    eq(game:time_left("b", 210), 595000)
    game:on_event({ type = "gameState", moves = "e2e4 e7e5", status = "resign", winner = "black" }, 300)
    eq(game:is_active(), false); eq(game:outcome(), "loss"); eq(game:is_my_turn(), false)
end)

test("the clock waits until both have moved", function()
    local game = Game.new("abc", "me")
    game:on_event({ type = "gameFull", speed = "rapid", clock = { initial = 600000 }, white = { id = "me" }, black = { id = "o" },
        state = { moves = "", wtime = 600000, btime = 600000, status = "started" } }, 100)
    eq(game:time_left("w", 200), 600000)
end)

test("correspondence has no running clock", function()
    local game = Game.new("abc", "me")
    game:on_event({ type = "gameFull", speed = "correspondence", daysPerTurn = 3, white = { id = "me" }, black = { id = "o" },
        state = { moves = "", wtime = 2147483647, btime = 2147483647, status = "started" } }, 100)
    eq(game:is_live(), false); eq(game:time_left("w", 200), nil)
end)

test("offers and outcomes", function()
    local game = Game.new("abc", "me")
    game:on_event({ type = "gameFull", white = { id = "o" }, black = { id = "me" }, state = { moves = "", status = "started", wdraw = true, wtakeback = true } }, 1)
    eq(game:opponent_offers_draw(), true); eq(game:i_offered_draw(), false); eq(game:opponent_offers_takeback(), true)
    game:on_event({ type = "gameState", moves = "", status = "draw" }, 2)
    eq(game:outcome(), "draw")
    game:on_event({ type = "gameState", moves = "", status = "aborted" }, 3)
    eq(game:outcome(), "aborted")
    game:on_event({ type = "gameState", moves = "", status = "mate", winner = "black" }, 4)
    eq(game:outcome(), "win")
end)

test("a game against the computer has a name", function()
    local game = Game.new("abc", "me")
    game:on_event({ type = "gameFull", white = { id = "me" }, black = { aiLevel = 3 }, state = { moves = "", status = "started" } }, 1)
    eq(game.black_name, "Stockfish 3")
    game:on_event({ type = "gameFull", white = { id = "me", rating = 1500 }, black = { aiLevel = 3, rating = 1500 }, state = { moves = "", status = "started" } }, 2)
    eq(game.black_rating, nil); eq(game.white_rating, 1500)
end)

test("other variants are told apart", function()
    local game = Game.new("abc", "me")
    game:on_event({ type = "gameFull", variant = { key = "chess960" }, white = { id = "me" }, black = { id = "o" }, state = { moves = "" } }, 1)
    eq(game:is_supported(), false)
    eq(Api.challenge_is_supported({ variant = { key = "standard" } }), true)
    eq(Api.challenge_is_supported({ variant = { key = "atomic" } }), false)
end)

test("clocks are readable", function()
    eq(Game.format_clock(65000), "1:05"); eq(Game.format_clock(3725000), "1:02:05"); eq(Game.format_clock(100), "0:01"); eq(Game.format_clock(nil), "")
end)

test("ids that could reach a shell are refused", function()
    for _, bad in ipairs({ "a b", "a;rm", "a'b", "a/../b", "$(x)", "`x`", "", string.rep("a", 65) }) do
        eq(Api.is_safe_id(bad), false)
        eq(pcall(Api.stream_game, bad), false)
        eq(pcall(Api.challenge_clock, bad, 5, 0, false), false)
    end
    eq(Api.is_safe_id("Some_User-1"), true)
    eq(pcall(Api.move, "abc", "e2e4;rm"), false)
    eq(Api.move("abc", "e7e8q").path, "/api/board/game/abc/move/e7e8q")
end)

test("a seek keeps the connection open only in real time", function()
    eq(Api.seek_clock(10, 0, true).stream, true)
    eq(Api.seek_clock(10, 0, true).body, "rated=true&time=10&increment=0")
    eq(Api.seek_clock(10, 0, true, "1400-1600").body, "rated=true&ratingRange=1400-1600&time=10&increment=0")
    eq(Api.seek_days(3, false).stream, nil)
    eq(Api.seek_days(3, false).body, "rated=false&days=3")
end)

test("no real-time seek goes below what Lichess accepts", function()
    for _, clock in ipairs(Api.REAL_TIME_SEEK) do
        assert(clock[1] * 60 + 40 * clock[2] >= 480, "this would count as blitz")
    end
end)

test("games needing an answer come first", function()
    local games = Api.sort_games({
        { gameId = "a", isMyTurn = false, secondsLeft = 10 },
        { gameId = "b", isMyTurn = true, secondsLeft = 500 },
        { gameId = "c", isMyTurn = true, secondsLeft = 50 },
    })
    eq(games[1].gameId, "c"); eq(games[2].gameId, "b"); eq(games[3].gameId, "a")
end)

test("time left in the list", function()
    eq(Api.format_left(90), "2 min"); eq(Api.format_left(10800), "3 h"); eq(Api.format_left(259200), "3 d"); eq(Api.format_left(nil), "")
end)

test("incoming challenges are told apart from those sent", function()
    eq(Api.is_incoming({ challenger = { id = "other" } }, "Me"), true)
    eq(Api.is_incoming({ challenger = { id = "me" } }, "Me"), false)
end)

-- The network layer, with child processes that are only recorded, and files written by the test.
local function temp_dir()
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p '" .. dir .. "'")
    return dir
end
local function write(path, text)
    local file = assert(io.open(path, "wb"))
    file:write(text)
    file:close()
end
local function read_all(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end
local CA = os.tmpname()
write(CA, "certificates")
local function fake_net(overrides)
    local record = { spawned = {}, killed = {}, dead = {}, waited = {} }
    local dir = temp_dir()
    local next_pid = 100
    local opts = {
        token = "lip_secret", dir = dir, version = "1", ca_file = CA,
        shell = function() return 0 end,
        spawn = function(spec)
            next_pid = next_pid + 1
            record.spawned[#record.spawned + 1] = spec
            return next_pid
        end,
        is_done = function(pid, wait)
            if wait then record.waited[#record.waited + 1] = pid end
            return record.dead[pid] == true
        end,
        kill = function(pid) record.killed[#record.killed + 1] = pid; record.dead[pid] = true end,
        file_size = function(path)
            local data = read_all(path)
            return data and #data or nil
        end,
    }
    for key, value in pairs(overrides or {}) do opts[key] = value end
    local net = Net.new(opts)
    assert(net:start())
    return net, record, dir
end

test("requests carry the token and always ask for the certificates", function()
    local net, record = fake_net()
    net:request(Api.account(), function() end)
    net:tick()
    local spec = record.spawned[1]
    eq(spec.headers.authorization, "Bearer lip_secret")
    eq(spec.ca_file, CA)
    eq(spec.url, "https://lichess.org/api/account")
    assert(not spec.url:find("lip_secret", 1, true), "the token reached the address")
end)

test("the token is never written to the folder of the requests", function()
    local net, record, dir = fake_net()
    net:request(Api.seek_days(3, false), function() end)
    net:tick()
    local listing = io.popen("ls -a '" .. dir .. "'")
    for name in listing:lines() do
        if name ~= "." and name ~= ".." then
            local data = read_all(dir .. "/" .. name) or ""
            assert(not data:find("lip_secret", 1, true), "found in " .. name)
        end
    end
    listing:close()
    eq(record.spawned[1].body, "rated=false&days=3")
    eq(record.spawned[1].headers["content-length"], tostring(#record.spawned[1].body))
end)

test("without the certificates, it does not start", function()
    local net = Net.new({ token = "lip_secret", dir = temp_dir(), ca_file = "/nonexistent/ca.crt", shell = function() return 0 end })
    eq(net:start(), false)
end)

test("a folder that cannot be made stops the start, whatever the shell answers", function()
    for _, answer in ipairs({ 1, 256, false }) do
        local net = Net.new({ token = "lip_secret", dir = temp_dir(), ca_file = CA, shell = function() return answer end })
        eq(net:start(), false)
    end
    for _, answer in ipairs({ 0, true }) do
        local net = Net.new({ token = "lip_secret", dir = temp_dir(), ca_file = CA, shell = function() return answer end })
        eq(net:start(), true)
    end
end)

test("a token with odd characters does not start", function()
    local net = Net.new({ token = 'lip_"x\nurl = "http://evil', dir = temp_dir(), ca_file = CA, shell = function() return 0 end })
    eq(net:start(), false)
end)

test("every request verifies the certificate and the name of the server, and refuses redirects", function()
    local worker = read_all("ink_knight/https_worker.lua")
    assert(worker:find("Tls.create", 1, true))
    assert(worker:find("redirect = false", 1, true))
    assert(not worker:find("ssl.https", 1, true), "KOReader's module does not check the name on stable versions")
    local tls = read_all("ink_knight/tls.lua")
    assert(tls:find('verify = "peer"', 1, true))
    assert(tls:find("cafile = opts.ca_file", 1, true))
    assert(tls:find("Tls.host_matches(Tls.certificate_names", 1, true))
end)

test("the name of the server must be in the certificate", function()
    local names = { "lichess.org", "*.lichess.org" }
    eq(Tls.host_matches(names, "lichess.org"), true)
    eq(Tls.host_matches(names, "LICHESS.org"), true)
    eq(Tls.host_matches(names, "explorer.lichess.org"), true)
    eq(Tls.host_matches(names, "a.b.lichess.org"), false)
    eq(Tls.host_matches(names, "lichess.org.evil.com"), false)
    eq(Tls.host_matches(names, "evillichess.org"), false)
    eq(Tls.host_matches({ "*.badssl.com", "badssl.com" }, "wrong.host.badssl.com"), false)
    eq(Tls.host_matches({ "*.org" }, "lichess.org"), false)
    eq(Tls.host_matches({ "*" }, "lichess.org"), false)
    eq(Tls.host_matches({ "lich*.org" }, "lichess.org"), false)
    eq(Tls.host_matches({}, "lichess.org"), false)
    eq(Tls.host_matches(nil, "lichess.org"), false)
    eq(Tls.host_matches(names, ""), false)
    eq(Tls.certificate_names(nil)[1], nil)
    eq(Tls.certificate_names({ extensions = function() return {} end })[1], nil)
    eq(Tls.certificate_names({ extensions = function() return { ["2.5.29.17"] = { dNSName = { "a.org" } } } end })[1], "a.org")
end)

test("requests run one at a time and in order", function()
    local net, record = fake_net()
    local answers = {}
    net:request(Api.account(), function(status, body) answers[#answers + 1] = { status, body } end)
    net:request(Api.playing(), function(status, body) answers[#answers + 1] = { status, body } end)
    net:tick()
    eq(#record.spawned, 1)
    net:tick()
    eq(#record.spawned, 1)
    write(net.current.prefix .. ".out", "{}")
    write(net.current.prefix .. ".code", "200")
    record.dead[net.current.pid] = true
    net:tick()
    eq(answers[1][1], 200); eq(answers[1][2], "{}")
    eq(#record.spawned, 2)
    assert(record.spawned[2].url:find("/api/account/playing", 1, true))
end)

test("a request with no answer gives nil", function()
    local net, record = fake_net()
    local got = "unset"
    net:request(Api.account(), function(status) got = status end)
    net:tick()
    write(net.current.prefix .. ".code", "0")
    record.dead[net.current.pid] = true
    net:tick()
    eq(got, nil)
end)

test("a child that dies without saying anything ends the request", function()
    local net, record = fake_net()
    local got = "unset"
    net:request(Api.account(), function(status) got = status end)
    net:tick()
    record.dead[net.current.pid] = true
    net:tick()
    eq(got, nil)
    eq(net.current, nil)
end)

test("a request that takes too long is killed", function()
    local now = 1000
    local net, record = fake_net{ clock = function() return now end }
    local got = "unset"
    net:request(Api.account(), function(status) got = status end)
    net:tick()
    local pid = net.current.pid
    now = 1044
    net:tick()
    eq(got, "unset")
    now = 1045
    net:tick()
    eq(got, nil)
    eq(record.killed[1], pid)
end)

test("a child that could not start ends the request, without an error", function()
    local net = fake_net{ spawn = function() return false, "fork failed" end }
    local got = "unset"
    net:request(Api.account(), function(status) got = status end)
    net:tick()
    net:tick()
    eq(got, nil)
end)

test("after a 429 the queue waits a minute", function()
    local now = 1000
    local net, record = fake_net{ clock = function() return now end }
    net:request(Api.account(), function() end)
    net:request(Api.playing(), function() end)
    net:tick()
    write(net.current.prefix .. ".code", "429")
    record.dead[net.current.pid] = true
    net:tick()
    eq(#record.spawned, 1)
    now = 1059
    net:tick()
    eq(#record.spawned, 1)
    now = 1060
    net:tick()
    eq(#record.spawned, 2)
end)

test("a stream hands out whole lines and skips the empty ones", function()
    local net, record = fake_net()
    local lines, ended = {}, 0
    local stream = net:stream(Api.stream_events(), function(line) lines[#lines + 1] = line end, function() ended = ended + 1 end)
    write(stream.prefix .. ".out", '{"a":1}\n\n{"b"')
    net:tick()
    eq(#lines, 1); eq(lines[1], '{"a":1}')
    write(stream.prefix .. ".out", '{"a":1}\n\n{"b":2}\n')
    net:tick()
    eq(#lines, 2); eq(lines[2], '{"b":2}')
    eq(ended, 0)
    record.dead[stream.pid] = true
    net:tick()
    eq(ended, 1)
    eq(#net.streams, 0)
end)

test("a stream file is opened only after it grew", function()
    local size = 0
    local net = fake_net{ file_size = function() return size end }
    local lines = {}
    local stream = net:stream(Api.stream_events(), function(line) lines[#lines + 1] = line end)
    write(stream.prefix .. ".out", '{"a":1}\n')
    net:tick()
    eq(#lines, 0)
    size = 8
    net:tick()
    eq(#lines, 1)
end)

test("only requests ask for the fast pace, not an open stream", function()
    local net, record = fake_net()
    net:stream(Api.stream_events(), function() end)
    eq(net:has_pending_request(), false)
    net:request(Api.account(), function() end)
    eq(net:has_pending_request(), true)
    net:tick()
    eq(net:has_pending_request(), true)
    record.dead[net.current.pid] = true
    net:tick()
    eq(net:has_pending_request(), false)
end)

test("a game with days per move shows days, and one with no limit shows nothing", function()
    local game = Game.new("x", "me")
    game:on_event({ type = "gameFull", speed = "correspondence", daysPerTurn = 14, white = { id = "me" }, black = { aiLevel = 1 }, state = { moves = "", wtime = 1209598000, btime = 1209600000, status = "started" } }, 0)
    eq(game:is_live(), false)
    eq(game:clock_text("w", 0), "13 d")
    local unlimited = Game.new("y", "me")
    unlimited:on_event({ type = "gameFull", speed = "correspondence", white = { id = "me" }, black = { aiLevel = 1 }, state = { moves = "", wtime = 2147483647, btime = 2147483647, status = "started" } }, 0)
    eq(unlimited:is_my_turn(), true)
    eq(unlimited:clock_text("w", 0), "")
end)

test("the color of a challenge can be chosen", function()
    assert(Api.challenge_clock("friend", 5, 3, false, "white").body:find("color=white", 1, true))
    assert(Api.challenge_days("friend", 3, false, "black").body:find("color=black", 1, true))
    assert(Api.challenge_no_limit("friend", "white").body:find("color=white", 1, true))
    assert(Api.challenge_ai(2, 15, 10, "black").body:find("color=black", 1, true))
    assert(Api.challenge_clock("friend", 5, 3, false).body:find("color=random", 1, true))
end)

test("the rating range of a seek follows the rating and the margin", function()
    eq(Api.rating_range(1500, 200), "1300-1700")
    eq(Api.rating_range(1500, 0), nil)
    eq(Api.rating_range(nil, 200), nil)
    eq(Api.rating_range(100, 200), "0-300")
    eq(Api.perf_of_clock(10, 0), "rapid"); eq(Api.perf_of_clock(15, 10), "rapid"); eq(Api.perf_of_clock(30, 0), "classical")
    eq(Api.perf_of_clock(3, 2), "blitz")
end)

test("the token only goes to the servers of Lichess that ask for it", function()
    local net, record = fake_net()
    net:request(Api.explorer("x"), function() end)
    net:tick()
    eq(record.spawned[1].headers.authorization, "Bearer lip_secret")
    assert(record.spawned[1].url:find("https://explorer.lichess.org/", 1, true) == 1)
    local other, other_record = fake_net()
    other:request(Api.tablebase("x"), function() end)
    other:tick()
    eq(other_record.spawned[1].headers.authorization, nil)
    assert(other_record.spawned[1].url:find("https://tablebase.lichess.org/", 1, true) == 1)
    local unknown, unknown_record = fake_net()
    unknown:request({ method = "GET", base = "https://example.org", path = "/" }, function() end)
    unknown:tick()
    eq(unknown_record.spawned[1].headers.authorization, nil)
end)

test("a game with no limit is never asked to be rated, and has no clock or days", function()
    local request = Api.challenge_no_limit("friend")
    eq(request.path, "/api/challenge/friend")
    eq(request.body, "rated=false&color=random&variant=standard")
    eq(Api.challenge_ai(3).body, "level=3&color=random&variant=standard")
    eq(Api.challenge_ai(3, 15, 10).body, "level=3&clock.limit=900&clock.increment=10&color=random&variant=standard")
end)

test("a challenge received says its time in all three kinds", function()
    local function days(n) return n .. " days" end
    eq(Api.time_control_text({ type = "clock", show = "5+3" }, "No limit", days), "5+3")
    eq(Api.time_control_text({ type = "correspondence", daysPerTurn = 3 }, "No limit", days), "3 days")
    eq(Api.time_control_text({ type = "unlimited" }, "No limit", days), "No limit")
    eq(Api.time_control_text(nil, "No limit", days), "")
end)

test("a new request tells the screen right away", function()
    local calls = 0
    local net = fake_net{ on_request = function() calls = calls + 1 end }
    net:stream(Api.stream_events(), function() end)
    eq(calls, 0)
    net:request(Api.account(), function() end)
    eq(calls, 1)
end)

test("a stream whose child died ends, with what it had written", function()
    local net, record = fake_net()
    local lines, ended = {}, 0
    local stream = net:stream(Api.stream_events(), function(line) lines[#lines + 1] = line end, function() ended = ended + 1 end)
    write(stream.prefix .. ".out", '{"a":1}\n')
    record.dead[stream.pid] = true
    net:tick()
    eq(#lines, 1); eq(ended, 1)
end)

test("closing a stream kills the child, does not call on_end, and collects it", function()
    local net, record = fake_net()
    local ended = 0
    local stream = net:stream(Api.stream_events(), function() end, function() ended = ended + 1 end)
    net:close_stream(stream)
    eq(record.killed[1], stream.pid)
    eq(#net.streams, 0)
    eq(#net.finished, 1)
    net:tick()
    eq(ended, 0)
    eq(#net.finished, 0)
end)

test("stopping kills every child and waits for them", function()
    local net, record = fake_net()
    local stream = net:stream(Api.stream_events(), function() end)
    net:request(Api.account(), function() end)
    net:tick()
    local pid = net.current.pid
    net:stop()
    eq(#record.killed, 2)
    eq(#record.waited, 2)
    eq(net:has_pending_request(), false)
    eq(#net.streams, 0)
    assert(stream.pid ~= pid)
end)

test("the scopes of the token come with the account, and the file is cleaned up", function()
    local net, record = fake_net()
    local status, scopes
    net:request(Api.account(), function(code, _, list) status, scopes = code, list end)
    net:tick()
    local spec = record.spawned[1]
    assert(spec.scopes_path, "the account asks for the scopes")
    write(net.current.prefix .. ".code", "200")
    write(spec.scopes_path, "board:play,puzzle:read")
    record.dead[net.current.pid] = true
    local path = spec.scopes_path
    net:tick()
    eq(status, 200); eq(scopes, "board:play,puzzle:read")
    eq(read_all(path), nil)
    local other, other_record = fake_net()
    other:request(Api.playing(), function() end)
    other:tick()
    eq(other_record.spawned[1].scopes_path, nil)
end)

test("a game knows when a repetition can be claimed", function()
    local game = Game.new("x", "me")
    game:on_event({ type = "gameFull", white = { id = "me" }, black = { id = "them" }, state = { moves = "g1f3 g8f6 f3g1 f6g8 g1f3 g8f6 f3g1", status = "started" } }, 0)
    eq(game:can_claim_repetition(), false)
    game:on_event({ type = "gameState", moves = "g1f3 g8f6 f3g1 f6g8 g1f3 g8f6 f3g1 f6g8", status = "started" }, 0)
    eq(game:can_claim_repetition(), true)
end)

test("a pawn that moved two squares leaves no mark when nothing can take it", function()
    local position = Chess.from_moves(nil, "e2e4")
    eq(position.passant, nil)
    position = Chess.from_moves(nil, "e2e4 d7d5 e4e5 f7f5")
    eq(Chess.square_name(position.passant), "f6")
    assert(has_move(position, "e5f6"))
end)

test("the first time a position happens counts, even right after a pawn moved two squares", function()
    -- The position after 1.e4 comes back after 3.Ng1 and 5.Ng1.
    local moves = "e2e4 b8c6 g1f3 c6b8 f3g1 b8c6 g1f3 c6b8 f3g1"
    eq(Chess.repetitions(nil, moves), 3)
    local game = Game.new("x", "me")
    game:on_event({ type = "gameFull", white = { id = "me" }, black = { id = "them" }, state = { moves = moves, status = "started" } }, 0)
    eq(game:can_claim_repetition(), true)
end)

test("a capture in passing that a pin forbids does not make the position different", function()
    -- The white king on a5 and the black rook on h5 pin the pawn on e5, so it cannot take on d6.
    local before = pos("4k3/3p4/8/K3P2r/8/8/8/8 b - - 0 1")
    local after = assert(Chess.apply_uci(before, "d7d5"))
    eq(Chess.square_name(after.passant), "d6")
    eq(has_move(after, "e5d6"), false)
    eq(Chess.position_key(after), Chess.position_key(pos("4k3/8/8/K2pP2r/8/8/8/8 w - - 0 1")))
end)

test("a rematch keeps the time and swaps the colors", function()
    local game = Game.new("x", "me")
    game:on_event({ type = "gameFull", rated = true, clock = { initial = 300000, increment = 3000 }, white = { id = "me" }, black = { id = "them" }, state = { moves = "", status = "mate" } }, 0)
    local request, starts = game:rematch_request()
    eq(request.path, "/api/challenge/them")
    eq(request.body, "rated=true&clock.limit=300&clock.increment=3&color=black&variant=standard")
    eq(starts, false)
    local days = Game.new("y", "me")
    days:on_event({ type = "gameFull", daysPerTurn = 3, white = { id = "them" }, black = { id = "me" }, state = { moves = "", status = "mate" } }, 0)
    eq(days:rematch_request().body, "rated=false&days=3&color=white&variant=standard")
    local free = Game.new("z", "me")
    free:on_event({ type = "gameFull", white = { id = "them" }, black = { id = "me" }, state = { moves = "", status = "mate" } }, 0)
    eq(free:rematch_request().body, "rated=false&color=white&variant=standard")
    local ai = Game.new("a", "me")
    ai:on_event({ type = "gameFull", clock = { initial = 900000, increment = 10000 }, white = { id = "me" }, black = { aiLevel = 4 }, state = { moves = "", status = "mate" } }, 0)
    local ai_request, ai_starts = ai:rematch_request()
    eq(ai_request.path, "/api/challenge/ai")
    eq(ai_request.body, "level=4&clock.limit=900&clock.increment=10&color=black&variant=standard")
    eq(ai_starts, true)
end)

test("a position becomes a FEN and back", function()
    local fen = "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 1"
    eq(Chess.to_fen(Chess.parse_fen(fen)), fen)
    eq(Chess.to_fen(Chess.parse_fen("8/8/8/8/4Pp2/8/8/4K2k b - e3 0 1")), "8/8/8/8/4Pp2/8/8/4K2k b - e3 0 1")
end)

test("moves are written in the usual notation", function()
    local function san(fen, uci)
        local position = Chess.parse_fen(fen)
        return Chess.to_san(position, Chess.parse_uci(position, uci))
    end
    eq(san(Chess.START_FEN, "g1f3"), "Nf3")
    eq(san(Chess.START_FEN, "e2e4"), "e4")
    eq(san("4k3/8/8/3p4/4P3/8/8/4K3 w - - 0 1", "e4d5"), "exd5")
    eq(san("r3k3/8/8/8/8/8/8/4K2R w K - 0 1", "e1g1"), "O-O")
    eq(san("4k3/P7/8/8/8/8/8/4K3 w - - 0 1", "a7a8q"), "a8=Q+")
    eq(san("6k1/8/6K1/8/8/8/8/R7 w - - 0 1", "a1a8"), "Ra8#")
    eq(san("6k1/8/8/8/8/8/4K3/R6R w - - 0 1", "a1d1"), "Rad1")
    eq(san("4k3/8/R7/8/8/8/8/R3K3 w - - 0 1", "a1a3"), "R1a3")
end)

test("evaluations and counts read well", function()
    eq(Api.eval_text(35), "+0.35"); eq(Api.eval_text(-120), "-1.20"); eq(Api.eval_text(nil, 3), "#3"); eq(Api.eval_text(nil, -2), "#-2")
    eq(Api.format_count(950), "950"); eq(Api.format_count(1500), "1.5k"); eq(Api.format_count(2500000), "2.5M")
    eq(Api.tablebase_winner("win", "w"), "white"); eq(Api.tablebase_winner("loss", "w"), "black")
    eq(Api.tablebase_winner("win", "b"), "black"); eq(Api.tablebase_winner("draw", "b"), "draw")
    eq(Api.tablebase_winner("cursed-win", "w"), "draw"); eq(Api.tablebase_winner("unknown", "w"), nil)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
