package.path = "./?.lua;" .. package.path
-- The token page only needs these from LuaSocket, so the tests run without a network.
package.loaded.socket = package.loaded.socket or { gettime = os.clock }
local Analysis = require("ink_knight/analysis")
local Api = require("ink_knight/api")
local BoardDiff = require("ink_knight/board_diff")
local Chess = require("ink_knight/chess")
local Game = require("ink_knight/game")
local Engine = require("ink_knight/engine")
local I18n = require("ink_knight/i18n")
local Pgn = require("ink_knight/pgn")
local Puzzles = require("ink_knight/puzzles")
local RatingChart = require("ink_knight/rating_chart")
local TokenAccess = require("ink_knight/token_access")
local TokenScopes = require("ink_knight/token_scopes")
local TokenStore = require("ink_knight/token_store")

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
local function san(position, text)
    local move = Chess.parse_san(position, text)
    return move and Chess.move_to_uci(move)
end

test("the usual notation is read", function()
    local start = pos(Chess.START_FEN)
    eq(san(start, "e4"), "e2e4")
    eq(san(start, "Nf3"), "g1f3")
    eq(san(start, "Nf3+"), "g1f3")
    eq(san(start, "Ke2"), nil)
    eq(san(start, "e5"), nil)
end)

test("castling in the usual notation", function()
    local position = pos("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
    eq(san(position, "O-O"), "e1g1")
    eq(san(position, "O-O-O"), "e1c1")
    eq(san(position, "0-0"), "e1g1")
end)

test("two pieces that can reach the same square are told apart", function()
    local position = pos("4k3/8/8/8/8/8/8/R3K2R w - - 0 1")
    eq(san(position, "Rad1"), "a1d1")
    position = pos("4k3/8/8/R7/8/8/8/R3K3 w - - 0 1")
    eq(san(position, "R1a3"), "a1a3")
    eq(san(position, "R5a3"), "a5a3")
end)

test("promotion and captures in the usual notation", function()
    local position = pos("1n5k/P7/8/8/8/8/8/K7 w - - 0 1")
    eq(san(position, "a8=Q"), "a7a8q")
    eq(san(position, "a8=N+"), "a7a8n")
    eq(san(position, "axb8=R#"), "a7b8r")
end)

test("a list of moves becomes UCI", function()
    local moves = Pgn.san_list_to_moves("e4 c5 Nf3")
    eq(#moves, 3)
    eq(moves[3].uci, "g1f3")
end)

test("the ending of a game is recognized", function()
    eq(Chess.ending(pos("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")), "stalemate")
    eq(Chess.ending(Chess.from_moves(nil, "f2f3 e7e5 g2g4 d8h4")), "mate")
    eq(Chess.ending(pos("8/8/4k3/8/8/4K3/8/8 w - - 0 1")), "insufficient")
    eq(Chess.ending(pos("8/8/4k3/8/8/4KB2/8/8 w - - 0 1")), "insufficient")
    eq(Chess.ending(pos("8/8/4k3/8/8/4KQ2/8/8 w - - 0 1")), nil)
    eq(Chess.ending(pos("8/8/4k3/8/8/4KQ2/8/8 w - - 100 80")), "fifty")
    eq(Chess.ending(pos(Chess.START_FEN)), nil)
end)

test("the count for the fifty-move rule restarts with a pawn or a capture", function()
    local position = assert(Chess.apply_uci(pos("4k3/8/8/8/8/8/4P3/4K2R w - - 40 60"), "h1h2"))
    eq(position.halfmove, 41)
    position = assert(Chess.apply_uci(pos("4k3/8/8/8/8/8/4P3/4K2R w - - 40 60"), "e2e4"))
    eq(position.halfmove, 0)
end)

local function run_search(position, level, random)
    local fake_time = 0
    local search = Engine.search(position, { level = level, now = function() fake_time = fake_time + 0.0001; return fake_time end, random = random, nodes_per_slice = 20 })
    local slices = 0
    while true do
        local ok, result = coroutine.resume(search)
        assert(ok, result)
        if coroutine.status(search) == "dead" then
            return result, slices
        end
        slices = slices + 1
    end
end

test("the review pile follows what Lichess still lists as missed", function()
    local pile = { { id = "aaaa1" }, { id = "bbbb2" } }
    local kept, fetch = Puzzles.review_plan(pile, { "bbbb2", "cccc3", "dddd4", "eeee5" }, { dddd4 = true }, 10)
    eq(#kept, 1)
    eq(kept[1].id, "bbbb2")
    eq(table.concat(fetch, " "), "cccc3 eeee5")
    local _, limited = Puzzles.review_plan({}, { "a1", "b2", "c3" }, {}, 2)
    eq(table.concat(limited, " "), "a1 b2")
    local _, safe = Puzzles.review_plan({}, { "ok1", "../x", "a b" }, {}, 10)
    eq(table.concat(safe, " "), "ok1")
    kept, fetch = Puzzles.review_plan(pile, {}, {}, 10)
    eq(#kept, 0)
    eq(#fetch, 0)
    eq(Api.puzzle_replay(30).path, "/api/puzzle/replay/30/mix")
    eq(Api.puzzle_by_id("w6sQc").path, "/api/puzzle/w6sQc")
end)

test("a challenge is sent or received depending on who made it", function()
    local mine = { challenger = { id = "Reader" }, destUser = { id = "friend" } }
    local theirs = { challenger = { id = "friend" }, destUser = { id = "reader" } }
    assert(Api.is_outgoing(mine, "reader") and not Api.is_incoming(mine, "reader"))
    assert(Api.is_incoming(theirs, "reader") and not Api.is_outgoing(theirs, "reader"))
    assert(not Api.is_outgoing(mine, nil), "with no account loaded, nothing is the reader's")
end)

test("a player who is not signed in is called anonymous, and the computer by its level", function()
    eq(Game.player_name({}, "Anônimo"), "Anônimo")
    eq(Game.player_name(nil, "Anônimo"), "Anônimo")
    eq(Game.player_name({ aiLevel = 3 }, "Anônimo"), "Stockfish 3")
    eq(Game.player_name({ user = { name = "Friend" } }, "Anônimo"), "Friend")
end)

test("a game becomes a list in the usual notation, numbered from where it started", function()
    local list, number, turn = Chess.san_list(nil, "e2e4 e7e5 g1f3 b8c6 f1b5 a7a6 e1g1")
    eq(table.concat(list, " "), "e4 e5 Nf3 Nc6 Bb5 a6 O-O")
    eq(number, 1)
    eq(turn, "w")
    list, number, turn = Chess.san_list("r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 2 12", "g8f6 f3e5")
    eq(table.concat(list, " "), "Nf6 Nxe5")
    eq(number, 12)
    eq(turn, "b")
    eq(table.concat((Chess.san_list(nil, "f2f3 e7e5 g2g4 d8h4")), " "), "f3 e5 g4 Qh4#")
    eq(#Chess.san_list(nil, "e2e4 e2e4 d7d5"), 1)
end)

test("the notation of a game that only grew is written for its new moves alone", function()
    local real_to_san, written = Chess.to_san, 0
    Chess.to_san = function(...) written = written + 1; return real_to_san(...) end
    local cache = {}
    local ok, err = pcall(function()
        eq(table.concat((Chess.san_list(nil, "e2e4 e7e5", cache)), " "), "e4 e5")
        eq(written, 2)
        eq(table.concat((Chess.san_list(nil, "e2e4 e7e5 g1f3", cache)), " "), "e4 e5 Nf3")
        eq(written, 3)
        eq(table.concat((Chess.san_list(nil, "e2e4 e7e5 g1f3", cache)), " "), "e4 e5 Nf3")
        eq(written, 3)
        -- A move taken back is not a game that grew: it is written again from the start.
        eq(table.concat((Chess.san_list(nil, "e2e4 e7e5", cache)), " "), "e4 e5")
        eq(written, 5)
        -- Neither is a move that only shares the first letters of the last one.
        eq(table.concat((Chess.san_list(nil, "e2e4 e7e6", cache)), " "), "e4 e6")
        eq(written, 7)
        local _, number, turn = Chess.san_list("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1", "e7e5", cache)
        eq(number, 1)
        eq(turn, "b")
        eq(written, 8)
        eq(#Chess.san_list(nil, "e2e4 e2e4 d7d5", cache), 1)
        eq(#Chess.san_list(nil, "e2e4 e2e4 d7d5 g1f3", cache), 1)
    end)
    Chess.to_san = real_to_san
    assert(ok, err)
end)

test("the move list pairs the moves by number, marks one and opens where it matters", function()
    local MoveList = require("ink_knight/ui/move_list")
    local rows = MoveList.rows({ "e4", "e5", "Nf3" }, 1, "w")
    eq(#rows, 2)
    eq(rows[1].number, "1.")
    eq(rows[1].white, "e4")
    eq(rows[1].black, "e5")
    eq(rows[2].white, "Nf3")
    eq(rows[2].black, nil)
    eq(rows[2].focus, true)
    rows = MoveList.rows({ "Nf6", "Nxe5", "d6" }, 12, "b", { current = 2, on_pick = function(index) rows.picked = index end })
    eq(rows[1].number, "12.")
    eq(rows[1].white, "…")
    eq(rows[1].black, "Nf6")
    eq(rows[2].white, "Nxe5")
    eq(rows[2].white_current, true)
    eq(rows[2].focus, true)
    eq(rows[1].focus, false)
    rows[2].black_callback()
    eq(rows.picked, 3)
    eq(rows[1].white_callback, nil)
    rows = MoveList.rows({ "e4", "e5", "Nf3", "Nc6", "Bb5" }, 1, "w", { current = 0 })
    eq(rows[1].focus, true)
    assert(not rows[3].focus, "only the first row should be in focus")
end)

test("taking back goes to the last move of a color, with what came after it", function()
    eq(Chess.take_back("e2e4 e7e5 g1f3 b8c6", "w"), "e2e4 e7e5")
    eq(Chess.take_back("e2e4 e7e5 g1f3", "w"), "e2e4 e7e5")
    eq(Chess.take_back("e2e4 e7e5 g1f3 b8c6", "b"), "e2e4 e7e5 g1f3")
    eq(Chess.take_back("e2e4", "w"), "")
    eq(Chess.take_back("e2e4", "b"), nil)
    eq(Chess.take_back("", "w"), nil)
end)

test("a hint is the best move found, with no noise", function()
    local function hint(fen)
        local search = Engine.search(pos(fen), { limits = Engine.HINT, now = function() return 0 end, random = function(n) return n end })
        while true do
            local ok, result = coroutine.resume(search)
            assert(ok, result)
            if coroutine.status(search) == "dead" then
                return result
            end
        end
    end
    eq(Engine.HINT.noise, 0)
    eq(Chess.move_to_uci(hint("6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1")), "a1a8")
    eq(Chess.move_to_uci(hint("4k3/8/8/3q4/4P3/8/8/4K3 w - - 0 1")), "e4d5")
end)

test("the engine works in slices", function()
    local move, slices = run_search(pos(Chess.START_FEN), 3, function() return 1 end)
    assert(move)
    assert(slices > 1, "it did not give the screen a turn")
end)

test("every level finds a mate in one", function()
    local position = pos("6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1")
    for level = 1, 4 do
        local move = run_search(position, level, function(n) return n end)
        eq(Chess.move_to_uci(move), "a1a8")
    end
end)

test("the higher levels take a free queen", function()
    local position = pos("4k3/8/8/3q4/4P3/8/8/4K3 w - - 0 1")
    for level = 3, 4 do
        local move = run_search(position, level, function() return 1 end)
        eq(Chess.move_to_uci(move), "e4d5")
    end
end)

test("the engine always returns a legal move, and nothing when there is none", function()
    local position = pos("r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3")
    local move = run_search(position, 2, function(n) return n end)
    local found = false
    for _, legal in ipairs(Chess.legal_moves(position)) do
        found = found or Chess.move_to_uci(legal) == Chess.move_to_uci(move)
    end
    assert(found)
    eq(run_search(Chess.from_moves(nil, "f2f3 e7e5 g2g4 d8h4"), 1), nil)
end)

test("the clock stops the search with what was already decided", function()
    local now_value = 0
    local search = Engine.search(pos(Chess.START_FEN), { level = 4, now = function() return now_value end, random = function() return 1 end, nodes_per_slice = 5 })
    local move
    for step = 1, 100000 do
        if step > 400 then now_value = 100 end
        local ok, result = coroutine.resume(search)
        assert(ok, result)
        if coroutine.status(search) == "dead" then
            move = result
            break
        end
    end
    assert(move, "the search did not stop")
end)

test("every level still sees a mate a move away at the edge of its search", function()
    -- Black threatens Qxg2 mate, and only one move stops it: level 2 must see the mate at its last ply.
    local position = pos("6k1/8/8/8/8/5q2/5P1P/6K1 w - - 0 1")
    for level = 2, 4 do
        local move = run_search(position, level, function(n) return n end)
        local after = Chess.play(position, move)
        local mated = false
        for _, reply in ipairs(Chess.legal_moves(after)) do
            mated = mated or Chess.ending(Chess.play(after, reply)) == "mate"
        end
        eq(mated, false)
    end
end)

test("a lower level with noise still only picks among moves close to the best", function()
    -- Taking the queen is worth far more than anything else, so even level 3's noise cannot reach another move.
    local position = pos("4k3/8/8/3q4/4P3/8/8/4K3 w - - 0 1")
    for pick = 1, 3 do
        local move = run_search(position, 3, function(n) return math.min(pick, n) end)
        eq(Chess.move_to_uci(move), "e4d5")
    end
end)

local RAW_PUZZLE = {
    game = { pgn = "e4 e5 Bc4 Nc6 Qh5 Nf6" },
    puzzle = { id = "abc12", rating = 1200, solution = { "h5f7" }, themes = { "mateIn1" }, initialPly = 5 },
}

test("a puzzle starts after the moves of its game", function()
    local puzzle = Puzzles.prepare(RAW_PUZZLE)
    local session = Puzzles.new_session(puzzle)
    eq(session.my_color, "w")
    eq(session.position.board[Chess.square_from_name("f6")], "n")
    eq(Chess.square_name(session.last_move.to), "f6")
end)

test("a broken puzzle is left out", function()
    eq(Puzzles.prepare({}), nil)
    eq(Puzzles.prepare({ game = { pgn = "e4 Zz9" }, puzzle = { id = "a", solution = { "e7e5" } } }), nil)
end)

test("solving a puzzle at the first try counts as a win", function()
    local session = Puzzles.new_session(Puzzles.prepare(RAW_PUZZLE))
    eq(Puzzles.try_move(session, "h5f7"), "solved")
    eq(session.solved, true)
    local result = Puzzles.result(session)
    eq(result.id, "abc12"); eq(result.win, true)
end)

test("a wrong move does not change the board and costs the win", function()
    local session = Puzzles.new_session(Puzzles.prepare(RAW_PUZZLE))
    local before = session.position
    eq(Puzzles.try_move(session, "h5h6"), "wrong")
    eq(session.position, before)
    eq(Puzzles.try_move(session, "h5f7"), "solved")
    eq(Puzzles.result(session).win, false)
end)

test("showing the move costs the win too", function()
    local session = Puzzles.new_session(Puzzles.prepare(RAW_PUZZLE))
    eq(Puzzles.hint(session), "h5f7")
    session.revealed = true
    Puzzles.try_move(session, Puzzles.hint(session))
    eq(Puzzles.result(session).win, false)
end)

test("the replies come by themselves in a longer puzzle", function()
    local session = Puzzles.new_session({ id = "x", played = "e2e4 e7e5 g1f3 b8c6", solution = { "f1b5", "a7a6", "b5c6" } })
    eq(Puzzles.try_move(session, "f1b5"), "correct")
    eq(Puzzles.play_reply(session), true)
    eq(Chess.square_name(session.last_move.to), "a6")
    eq(Puzzles.try_move(session, "b5c6"), "solved")
end)

test("another mate counts, even if it is not the move expected", function()
    local session = Puzzles.new_session({ id = "x", played = "", solution = { "e2e4" } })
    session.position = pos("6k1/5ppp/8/8/8/8/8/RR4K1 w - - 0 1")
    session.puzzle.solution = { "a1a8" }
    eq(Puzzles.try_move(session, "b1b8"), "solved")
end)

test("the results go as JSON, and an odd id does not get through", function()
    local body = Puzzles.results_body({ { id = "abc", win = true, rated = true }, { id = 'x"}]', win = false }, { id = "def", win = false } })
    eq(body, '{"solutions":[{"id":"abc","win":true,"rated":true},{"id":"def","win":false,"rated":true}]}')
end)

local CODE, HOST, PHONE, OTHER = "abc123code", "192.168.0.5:8644", "192.168.0.20", "192.168.0.99"
local function new_access()
    local got = {}
    local access = TokenAccess.new{
        code = CODE, host = HOST, strings = I18n.en,
        on_new_client = function(ip) got.client = ip end,
        on_token = function(token) got.token = token end,
    }
    return access, got
end
local function request(method, target, extra)
    return string.format("%s %s HTTP/1.1\r\nHost: %s\r\n%s\r\n", method, target, HOST, extra or "")
end
-- As the server does: the body is read only when the first answer asks for it, and only as long as it says.
local function ask(access, head, body, ip)
    if body ~= "" and not head:lower():find("\ncontent%-length:") then
        head = head:gsub("\r\n\r\n$", "\r\nContent-Length: " .. #body .. "\r\n\r\n")
    end
    local result = access:handle(head, ip)
    if result.read_body then
        result = access:handle(head, ip, body:sub(1, result.read_body))
    end
    return result
end
local function approved()
    local access, got = new_access()
    ask(access, request("GET", "/" .. CODE .. "/"), "", PHONE)
    access:approve(PHONE)
    return access, got
end
local SAVE = "/" .. CODE .. "/save"

test("tokens have a known shape", function()
    eq(TokenAccess.is_valid_token("lip_abcDEF123_x"), true)
    for _, bad in ipairs({ "abc", "lip_", 'lip_a"b', "lip_a b", "lip_a\nb", "lip_a;rm", "lip_" .. string.rep("a", 130) }) do
        eq(TokenAccess.is_valid_token(bad), false)
    end
end)

test("the first device waits for approval and sees no form", function()
    local access, got = new_access()
    local result = ask(access, request("GET", "/" .. CODE .. "/"), "", PHONE)
    eq(got.client, PHONE)
    assert(result.body:find(I18n.en.confirm_heading, 1, true))
    assert(not result.body:find("<form", 1, true))
end)

test("no token is taken before approval", function()
    local access, got = new_access()
    ask(access, request("GET", "/" .. CODE .. "/"), "", PHONE)
    eq(ask(access, request("POST", SAVE), "token=lip_abcdefgh", PHONE).status, 404)
    eq(got.token, nil)
end)

test("a token goes through only from the approved device", function()
    local access, got = approved()
    eq(ask(access, request("POST", SAVE), "token=lip_abcdefgh", OTHER).status, 404)
    eq(got.token, nil)
    eq(ask(access, request("POST", SAVE), "token=lip_abcdefgh", PHONE).status, 200)
    eq(got.token, "lip_abcdefgh")
end)

test("spaces around a pasted token are dropped", function()
    local access, got = approved()
    ask(access, request("POST", SAVE), "token=%20lip_abcdefgh+", PHONE)
    eq(got.token, "lip_abcdefgh")
end)

test("a bad token shows the form again", function()
    local access, got = approved()
    local result = ask(access, request("POST", SAVE), "token=lip_a%22b", PHONE)
    eq(got.token, nil)
    assert(result.body:find(I18n.en.token_invalid, 1, true))
    assert(result.body:find("<form", 1, true))
end)

test("another site's page cannot post a token", function()
    local access, got = approved()
    eq(ask(access, request("POST", SAVE, "Origin: http://evil.example\r\n"), "token=lip_abcdefgh", PHONE).status, 404)
    eq(got.token, nil)
    eq(ask(access, request("POST", SAVE, "Origin: http://" .. HOST .. "\r\n"), "token=lip_abcdefgh", PHONE).status, 200)
end)

test("without the code, another host or outside the network, nothing is served", function()
    local access, got = new_access()
    eq(ask(access, request("GET", "/wrong/"), "", PHONE).status, 404)
    eq(got.client, nil)
    eq(ask(access, request("GET", "/" .. CODE .. "/"), "", "8.8.8.8").status, 404)
    eq(ask(access, string.format("GET /%s/ HTTP/1.1\r\nHost: evil.example\r\n\r\n", CODE), "", PHONE).status, 404)
end)

test("repeated bad requests lock out that address only, and a denied device is dropped", function()
    local access = approved()
    for _ = 1, TokenAccess.MAX_BAD_REQUESTS do
        ask(access, request("GET", "/guess/"), "", OTHER)
    end
    eq(access:is_denied(OTHER), true)
    eq(access:is_denied(PHONE), false)
    eq(ask(access, request("GET", "/" .. CODE .. "/"), "", OTHER).close_only, true)
end)

test("the page has no script, and the token field does not autofill", function()
    local access = approved()
    local body = ask(access, request("GET", "/" .. CODE .. "/"), "", PHONE).body
    assert(not body:find("<script", 1, true))
    assert(body:find('autocomplete="off"', 1, true))
    assert(body:find('type="password"', 1, true))
    local head = TokenAccess.response_head({ status = 200, content_type = "text/html" }, 1)
    assert(head:find("default-src 'none'", 1, true))
    assert(head:find("Cache-Control: no-store", 1, true))
end)

test("the body of a form is only read after the code, the approval and the origin are checked", function()
    local head = request("POST", SAVE, "Content-Length: 18\r\n")
    local access = new_access()
    eq(access:handle(head, PHONE).read_body, nil)
    access = approved()
    eq(access:handle(head, OTHER).read_body, nil)
    eq(access:handle(request("POST", SAVE, "Origin: http://evil.example\r\nContent-Length: 18\r\n"), PHONE).read_body, nil)
    eq(access:handle(head, PHONE).read_body, 18)
    eq(access:handle(request("POST", SAVE, "Content-Length: 99999\r\n"), PHONE).close_only, true)
end)

test("only the approved device keeps connections of its own", function()
    local access = new_access()
    eq(access:preferred_ip(), nil)
    access:handle(request("GET", "/" .. CODE .. "/"), PHONE)
    eq(access:preferred_ip(), nil)
    access:approve(PHONE)
    eq(access:preferred_ip(), PHONE)
end)

test("the token is never echoed in a page", function()
    local access = approved()
    local result = ask(access, request("POST", SAVE), "token=lip_secretvalue", PHONE)
    assert(not result.body:find("lip_secretvalue", 1, true))
    result = ask(access, request("POST", SAVE), "token=lip_secret%22value", PHONE)
    assert(not result.body:find("secret", 1, true))
end)

-- Permissions are given by the test, as a filesystem would report them, and the rest uses real files.
local function temp_dir()
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p '" .. dir .. "'")
    return dir
end
local function read_all(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end
local function new_store(opts)
    return TokenStore.new{
        settings_dir = opts.settings,
        private_dir = opts.private,
        permissions_of = function(path)
            if opts.shared and path:find(opts.shared, 1, true) == 1 then return "rwxrwxrwx" end
            return read_all(path) and "rw-------" or nil
        end,
    }
end
local TOKEN = "lip_abcdefgh123"

test("a token goes to the private place when it really is private", function()
    local settings, private = temp_dir(), temp_dir()
    local store = new_store{ settings = settings, private = private }
    local saved, protected = store:save(TOKEN)
    eq(saved, true); eq(protected, true)
    eq(read_all(private .. "/ink_knight_token"), TOKEN)
    eq(read_all(settings .. "/ink_knight_token"), nil)
    local token, is_protected = store:load()
    eq(token, TOKEN); eq(is_protected, true)
end)

test("a token that was opened up at boot is closed again when it is loaded", function()
    local settings, private = temp_dir(), temp_dir()
    new_store{ settings = settings, private = private }:save(TOKEN)
    local permissions = "rw-rw----"
    local commands = {}
    local store = TokenStore.new{
        settings_dir = settings, private_dir = private,
        permissions_of = function() return permissions end,
        shell = function(command)
            commands[#commands + 1] = command
            if command:find("chmod 600", 1, true) then permissions = "rw-------" end
        end,
    }
    local token, protected = store:load()
    eq(token, TOKEN); eq(protected, true)
    assert(commands[1]:find("chmod 700", 1, true))
end)

test("a token that cannot be closed again is reported as it is", function()
    local settings, private = temp_dir(), temp_dir()
    new_store{ settings = settings, private = private }:save(TOKEN)
    local store = TokenStore.new{
        settings_dir = settings, private_dir = private,
        permissions_of = function() return "rw-rw----" end,
        shell = function() end,
    }
    local token, protected = store:load()
    eq(token, TOKEN); eq(protected, false)
end)

test("a token already closed runs no command", function()
    local settings, private = temp_dir(), temp_dir()
    new_store{ settings = settings, private = private }:save(TOKEN)
    local ran = 0
    local store = TokenStore.new{
        settings_dir = settings, private_dir = private,
        permissions_of = function() return "rw-------" end,
        shell = function() ran = ran + 1 end,
    }
    store:load()
    eq(ran, 0)
end)

test("no temporary file stays behind", function()
    local settings, private = temp_dir(), temp_dir()
    new_store{ settings = settings, private = private }:save(TOKEN)
    eq(read_all(private .. "/ink_knight_token.new"), nil)
end)

test("a place that ignores permissions is not called protected", function()
    local settings = temp_dir()
    local store = new_store{ settings = settings, shared = settings }
    local saved, protected = store:save(TOKEN)
    eq(saved, true); eq(protected, false)
    local token, is_protected = store:load()
    eq(token, TOKEN); eq(is_protected, false)
end)

test("when the private place cannot be written, the settings folder is used and says so", function()
    local settings = temp_dir()
    local store = new_store{ settings = settings, private = "/nonexistent/no/way", shared = settings }
    local saved, protected = store:save(TOKEN)
    eq(saved, true); eq(protected, false)
    eq(read_all(settings .. "/ink_knight_token"), TOKEN)
end)

test("a private place that ignores permissions is abandoned, and leaves no copy", function()
    local settings, private = temp_dir(), temp_dir()
    local store = new_store{ settings = settings, private = private, shared = private }
    local _, protected = store:save(TOKEN)
    eq(protected, true)
    eq(read_all(private .. "/ink_knight_token"), nil)
    eq(read_all(settings .. "/ink_knight_token"), TOKEN)
end)

test("a token left in the settings folder moves to the private place", function()
    local settings, private = temp_dir(), temp_dir()
    local file = assert(io.open(settings .. "/ink_knight_token", "wb"))
    file:write(TOKEN .. "\n")
    file:close()
    local token, protected = new_store{ settings = settings, private = private }:load()
    eq(token, TOKEN); eq(protected, true)
    eq(read_all(settings .. "/ink_knight_token"), nil)
    eq(read_all(private .. "/ink_knight_token"), TOKEN)
end)

test("a file with something else in it is not a token", function()
    local settings = temp_dir()
    local file = assert(io.open(settings .. "/ink_knight_token", "wb"))
    file:write("not a token")
    file:close()
    eq(new_store{ settings = settings }:load(), nil)
end)

test("disconnecting removes the token from both places", function()
    local settings, private = temp_dir(), temp_dir()
    local store = new_store{ settings = settings, private = private }
    store:save(TOKEN)
    store:clear()
    eq(store:load(), nil)
    eq(read_all(private .. "/ink_knight_token"), nil)
end)

test("the private folder is only for a Kindle", function()
    eq(TokenStore.private_dir_for(true), "/var/local/ink_knight")
    eq(TokenStore.private_dir_for(false), nil)
end)

test("the language follows KOReader, and others use English", function()
    eq(I18n.language_from("pt_BR"), "pt"); eq(I18n.language_from("es"), "es"); eq(I18n.language_from("de"), "en"); eq(I18n.language_from(nil), "en")
end)

test("a new batch does not bring back puzzles already on the device", function()
    local pile = { { id = "a" }, { id = "b" } }
    local added = Puzzles.add_new(pile, { { id = "b" }, { id = "c" }, { id = "d" }, { id = "c" } }, { d = true })
    eq(added, 1)
    eq(#pile, 3)
    eq(pile[3].id, "c")
end)

test("a batch asks for the difficulty and color chosen, and nothing else", function()
    eq(Api.puzzle_batch(15).path, "/api/puzzle/batch/mix?nb=15")
    eq(Api.puzzle_batch(15, "fork", "harder", "black").path, "/api/puzzle/batch/fork?nb=15&difficulty=harder&color=black")
    eq(Api.puzzle_batch(15, nil, "normal", "any").path, "/api/puzzle/batch/mix?nb=15&difficulty=normal")
    eq(Api.puzzle_batch(15, nil, "impossible&x=1", "red").path, "/api/puzzle/batch/mix?nb=15")
end)

test("the next puzzle is one asked the way chosen, and the others wait for a batch to replace them", function()
    local hard_black = Puzzles.wanted("harder", "black")
    -- "a" was saved before the choice existed, so it counts as normal and either color.
    local pile = { { id = "a" }, { id = "b", wanted = hard_black }, { id = "c", wanted = Puzzles.wanted("easiest", "any") } }
    eq(Puzzles.count_wanted(pile, Puzzles.DEFAULT_WANTED), 1)
    eq(Puzzles.count_wanted(pile, hard_black), 1)
    eq(Puzzles.take(pile, hard_black).id, "b")
    eq(Puzzles.take(pile, hard_black).id, "a")
    Puzzles.drop_unwanted(pile, hard_black)
    eq(#pile, 0)
    pile = { { id = "a" }, { id = "b", wanted = hard_black } }
    Puzzles.drop_unwanted(pile, hard_black)
    eq(#pile, 1); eq(pile[1].id, "b")
end)

test("results of puzzles go to Lichess one theme at a time", function()
    local results = { { id = "a", win = true }, { id = "b", win = false }, { id = "c", angle = "fork", win = true }, { id = "d", win = true } }
    local angle, count = Puzzles.first_group(results)
    eq(angle, nil); eq(count, 2)
    eq(Puzzles.results_body(results, count), '{"solutions":[{"id":"a","win":true,"rated":true},{"id":"b","win":false,"rated":true}]}')
    table.remove(results, 1); table.remove(results, 1)
    angle, count = Puzzles.first_group(results)
    eq(angle, "fork"); eq(count, 1)
end)

test("a theme stays with the puzzle and with its result", function()
    local raw = { puzzle = { id = "p1", rating = 1500, solution = { "e2e4" } }, game = { pgn = "d4 d5" } }
    local puzzle = Puzzles.prepare(raw, "fork")
    eq(puzzle.angle, "fork")
    local session = Puzzles.new_session(puzzle)
    session.solved = true
    eq(Puzzles.result(session).angle, "fork")
end)

test("the rating series is found by its name, and months count from zero", function()
    local history = {
        { name = "Bullet", points = {} },
        { name = "King of the Hill", points = { { 2024, 0, 15, 1400 } } },
        { name = "Rapid", points = { { 2024, 0, 15, 1500 }, { 2024, 11, 15, 1620 } } },
        { name = "Puzzles", points = { { 2024, 5, 1, 1700 } } },
    }
    local rapid = RatingChart.points(history, "rapid")
    eq(#rapid, 2)
    eq(os.date("%m/%Y", rapid[1].time), "01/2024")
    eq(os.date("%m/%Y", rapid[2].time), "12/2024")
    eq(#RatingChart.points(history, "kingOfTheHill"), 1)
    eq(#RatingChart.points(history, "puzzle"), 1)
    eq(#RatingChart.points(history, "blitz"), 0)
    eq(#RatingChart.points(nil, "rapid"), 0)
end)

test("the chart fits its box, with round marks", function()
    local points = { { time = 1000, rating = 1480 }, { time = 2000, rating = 1620 }, { time = 3000, rating = 1550 } }
    local rect = { x = 50, y = 100, w = 400, h = 200 }
    local layout = RatingChart.layout(points, rect)
    eq(layout.lowest, 1480); eq(layout.highest, 1620); eq(layout.current, 1550)
    assert(#layout.ticks >= 2 and #layout.ticks <= 5, "ticks: " .. #layout.ticks)
    for _, tick in ipairs(layout.ticks) do
        assert(tick.y >= rect.y and tick.y <= rect.y + rect.h)
    end
    eq(layout.path[1].x, rect.x); eq(layout.path[3].x, rect.x + rect.w)
    for _, mark in ipairs(layout.path) do
        assert(mark.y >= rect.y and mark.y <= rect.y + rect.h)
    end
    eq(RatingChart.layout({}, rect), nil)
    local single = RatingChart.layout({ { time = 1000, rating = 1500 } }, rect)
    eq(single.path[1].x, rect.x + 200)
    assert(#single.ticks >= 2)
end)

test("the numbers below the chart skip what is missing", function()
    local s = I18n.en
    eq(#RatingChart.stat_lines(s, nil, nil), 0)
    local lines = RatingChart.stat_lines(s, {
        percentile = 72.5,
        stat = { count = { all = 20, win = 10, loss = 8, draw = 2 }, highest = { int = 1700 }, lowest = { int = 1400 }, resultStreak = { win = { max = { v = 5 } } } },
    }, nil)
    eq(#lines, 4)
    assert(lines[1]:find("20", 1, true))
    eq(#RatingChart.stat_lines(s, { stat = { count = { all = 0 } } }, { highest = 1600, lowest = 1500 }), 1)
end)

test("the analysis says what it knows, and what it does not", function()
    local s = I18n.en
    local position = Chess.parse_fen("r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3")
    local full = Analysis.text(s, position, {
        cloud = { depth = 55, pvs = { { moves = "g8f6 d2d3 f8c5 e1g1 d7d6 c2c3", cp = 7 } } },
        explorer = { opening = { name = "Italian Game" }, moves = { { san = "Nf6", white = 50, draws = 10, black = 40 } } },
    })
    assert(full:find("+0.07", 1, true)); assert(full:find("Nf6 d3 Bc5 O-O d6", 1, true))
    assert(not full:find("c3", 1, true), "the line should stop at five moves")
    assert(full:find("Italian Game", 1, true)); assert(full:find("50% / 10% / 40%", 1, true))
    local nothing = Analysis.text(s, position, {})
    assert(nothing:find(s.analysis_no_eval, 1, true)); assert(nothing:find(s.analysis_no_games, 1, true))
    local ending_position = Chess.parse_fen("4k3/6KP/8/8/8/8/7p/8 w - - 0 1")
    eq(Analysis.piece_count(ending_position), 4)
    local ending = Analysis.text(s, ending_position, { tablebase = { category = "win", moves = { { san = "h8=Q+" } } } })
    assert(ending:find(s.analysis_end_white, 1, true)); assert(ending:find("h8=Q+", 1, true))
end)

test("what a token may do comes from the scopes Lichess states", function()
    local scopes = TokenScopes.parse("board:play,puzzle:read")
    eq(TokenScopes.allows(scopes, "play"), true)
    eq(TokenScopes.allows(scopes, "challenge"), true)
    eq(TokenScopes.allows(scopes, "events"), true)
    eq(TokenScopes.allows(scopes, "puzzles"), true)
    eq(TokenScopes.allows(scopes, "puzzle_results"), false)
    eq(TokenScopes.allows(scopes, "give_time"), false)
    eq(TokenScopes.allows(scopes, "favorites"), false)
    local empty = TokenScopes.parse("")
    eq(TokenScopes.allows(empty, "play"), false)
    eq(TokenScopes.parse(nil), nil)
    eq(TokenScopes.allows(nil, "favorites"), true)
end)

test("favorites are the only thing not counted as missing", function()
    eq(TokenScopes.missing_count(TokenScopes.parse(table.concat(TokenScopes.SUGGESTED, ","))), 0)
    eq(TokenScopes.missing_count(TokenScopes.parse("board:play")), 5)
    eq(TokenScopes.missing_count(TokenScopes.parse("")), 6)
end)

test("the link for creating a token marks what the plugin needs, and no more", function()
    local url = TokenScopes.create_url()
    assert(url:find("https://lichess.org/account/oauth/token/create?", 1, true) == 1)
    assert(url:find("scopes[]=board:play", 1, true))
    assert(url:find("description=Ink+Knight", 1, true))
    assert(not url:find("preference:write", 1, true))
    assert(not url:find("challenge:read", 1, true))
    assert(not url:find("study:read", 1, true))
end)

test("every listed permission has a name in every language", function()
    for _, language in ipairs({ "pt", "en", "es" }) do
        for _, feature in ipairs(TokenScopes.LISTED) do
            assert(I18n[language].scope_names[feature], language .. " has no name for " .. feature)
        end
    end
end)

test("a move only touches the squares it changed", function()
    local start = Chess.parse_fen(Chess.START_FEN)
    local before = { position = start, status = "a", top = { name = "x", clock = "1:00" }, bottom = { name = "y", clock = "1:00" }, buttons = { { id = "back", label = "Back" } } }
    local first = BoardDiff.snapshot(before)
    eq(BoardDiff.changes(nil, first).whole, true)
    local after_position, move = Chess.apply_uci(start, "e2e4")
    local after = { position = after_position, last_move = move, status = "a", top = before.top, bottom = before.bottom, buttons = before.buttons }
    local changes = BoardDiff.changes(first, BoardDiff.snapshot(after))
    eq(#changes.squares, 2)
    eq(changes.squares[1], Chess.square_from_name("e2")); eq(changes.squares[2], Chess.square_from_name("e4"))
    eq(changes.top, false); eq(changes.status, false); eq(changes.buttons, false)
end)

test("the reply also clears the mark of the last move, and nothing else", function()
    local position, first_move = Chess.apply_uci(Chess.parse_fen(Chess.START_FEN), "e2e4")
    local reply_position, reply = Chess.apply_uci(position, "e7e5")
    local changes = BoardDiff.changes(
        BoardDiff.snapshot({ position = position, last_move = first_move }),
        BoardDiff.snapshot({ position = reply_position, last_move = reply }))
    eq(#changes.squares, 4)
end)

test("selecting a piece touches that square and its targets", function()
    local position = Chess.parse_fen(Chess.START_FEN)
    local square = Chess.square_from_name("g1")
    local changes = BoardDiff.changes(
        BoardDiff.snapshot({ position = position }),
        BoardDiff.snapshot({ position = position, selected = square, targets = Chess.targets_from(position, square) }))
    eq(#changes.squares, 3)
end)

test("captures by the pawn passing by and castling touch every square they change", function()
    local passing = Chess.parse_fen("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1")
    local after_passing, move = Chess.apply_uci(passing, "e5d6")
    eq(#BoardDiff.changes(BoardDiff.snapshot({ position = passing }), BoardDiff.snapshot({ position = after_passing, last_move = move })).squares, 3)
    local castle = Chess.parse_fen("4k3/8/8/8/8/8/8/4K2R w K - 0 1")
    local after_castle, castle_move = Chess.apply_uci(castle, "e1g1")
    eq(#BoardDiff.changes(BoardDiff.snapshot({ position = castle }), BoardDiff.snapshot({ position = after_castle, last_move = castle_move })).squares, 4)
end)

test("turning the board or changing the bars is seen", function()
    local position = Chess.parse_fen(Chess.START_FEN)
    local base = BoardDiff.snapshot({ position = position, top = { name = "x", clock = "1:00" } })
    eq(BoardDiff.changes(base, BoardDiff.snapshot({ position = position, flipped = true, top = { name = "x", clock = "1:00" } })).whole, true)
    eq(BoardDiff.changes(base, BoardDiff.snapshot({ position = position, top = { name = "x", clock = "0:59" } })).top, true)
end)

test("every way a game can end has a sentence of its own", function()
    for _, status in ipairs({ "mate", "resign", "outoftime", "timeout" }) do
        assert(I18n.pt[Game.ending_key("win", status)], "win " .. status)
        assert(I18n.pt[Game.ending_key("loss", status)], "loss " .. status)
        assert(Game.ending_key("win", status) ~= "outcome_win", status)
    end
    for _, status in ipairs({ "stalemate", "insufficient", "fifty", "repetition" }) do
        assert(I18n.pt[Game.ending_key("draw", status)], status)
    end
    eq(Game.ending_key("draw", "draw"), "outcome_draw")
    eq(Game.ending_key("aborted", "aborted"), "outcome_aborted")
    eq(I18n.pt[Game.ending_key("draw", "insufficient")], "Empate: ninguém tem peças para dar mate.")
end)

test("the token page lets a browser say where its form comes from", function()
    local head = TokenAccess.response_head({ status = 200, content_type = "text/html" }, 10)
    assert(head:find("Referrer-Policy: same-origin", 1, true), "no-referrer makes browsers send Origin: null")
    assert(not head:find("no-referrer", 1, true))
end)

test("a form posted from nowhere or from another site is still refused", function()
    local access = approved()
    for _, origin in ipairs({ "null", "http://evil.example" }) do
        eq(ask(access, request("POST", SAVE, "Origin: " .. origin .. "\r\n"), "token=lip_abcdefgh", PHONE).status, 404)
    end
end)

test("a JSON null does not count as a value, at any depth", function()
    local null = newproxy()
    local data = Api.without_nulls({ opening = null, moves = { { san = "e4", extra = null } }, white = 3 }, null)
    eq(data.opening, nil)
    eq(data.moves[1].extra, nil)
    eq(data.moves[1].san, "e4")
    eq(data.white, 3)
end)

test("the analysis of a position with no opening name still has its moves", function()
    local text = Analysis.text(I18n.en, pos(Chess.START_FEN), {
        explorer = { moves = { { san = "e4", white = 5, draws = 3, black = 2 } } },
    })
    assert(text:find("e4", 1, true))
end)

local function finished(white_id, black_id, winner)
    return {
        winner = winner,
        status = winner and "mate" or "draw",
        players = {
            white = { user = { id = white_id, name = white_id } },
            black = { user = { id = black_id, name = black_id } },
        },
    }
end

test("the reader's own games speak to the reader", function()
    local title, detail, on_black = Game.past_summary(I18n.en, finished("me", "ana", "white"), "me", "me")
    eq(title, "ana")
    eq(detail, "You won")
    eq(on_black, false)
    title, detail, on_black = Game.past_summary(I18n.en, finished("ana", "me", "white"), "me", "me")
    eq(title, "ana")
    eq(detail, "You lost")
    eq(on_black, true)
end)

test("someone else's games name who won, not the reader", function()
    local title, detail, on_black = Game.past_summary(I18n.en, finished("rui", "ana", "white"), "rui", "me")
    eq(title, "against ana")
    eq(detail, "rui won")
    eq(on_black, false)
    title, detail = Game.past_summary(I18n.en, finished("rui", "ana", "black"), "rui", "me")
    eq(detail, "ana won")
    title, detail = Game.past_summary(I18n.en, finished("rui", "ana"), "rui", "me")
    eq(detail, "Draw")
end)

test("in someone else's list, a game against the reader still says who won", function()
    local _, detail = Game.past_summary(I18n.en, finished("rui", "me", "black"), "rui", "me")
    eq(detail, "You won")
    _, detail = Game.past_summary(I18n.en, finished("rui", "me", "white"), "rui", "me")
    eq(detail, "rui won")
end)

test("a favorite the reader did not play names both players", function()
    local title, detail, on_black = Game.past_summary(I18n.en, finished("rui", "ana", "white"), "me", "me")
    eq(title, "rui x ana")
    eq(detail, "rui won")
    eq(on_black, false)
end)

test("a rating Lichess is not sure of has a question mark, and the computer has no rating", function()
    local game = Game.new("x", "me")
    game:on_event({ type = "gameFull", white = { id = "ana", name = "ana", rating = 1500, provisional = true },
        black = { id = "me", name = "me", rating = 1612 }, state = { moves = "", status = "started" } }, 0)
    eq(game:rating_text("w"), "1500?")
    eq(game:rating_text("b"), "1612")
    local against_computer = Game.new("y", "me")
    against_computer:on_event({ type = "gameFull", white = { aiLevel = 1 }, black = { id = "me", name = "me", rating = 1612 },
        state = { moves = "", status = "started" } }, 0)
    eq(against_computer:rating_text("w"), nil)
    eq(against_computer:rating_text("b"), "1612")
end)

test("the openings with puzzles keep the order of Lichess, without keys that cannot go into a path", function()
    local families = Puzzles.read_openings({ openings = {
        { family = { key = "Sicilian_Defense", name = "Sicilian Defense", count = 207281 },
            openings = { { key = "Sicilian_Defense_Najdorf_Variation", name = "Najdorf Variation", count = 11197 }, { key = "bad/key", name = "X", count = 1 } } },
        { family = { key = "Hippopotamus_Defense", name = "Hippopotamus Defense", count = 77 } },
        { family = { key = "../account", name = "Bad", count = 5 } },
        { family = { key = "No_Name", count = 5 } },
    } })
    assert(#families == 2, "two families: " .. #families)
    assert(families[1].key == "Sicilian_Defense" and families[1].count == 207281)
    assert(#families[1].openings == 1 and families[1].openings[1].name == "Najdorf Variation")
    assert(#families[2].openings == 0)
    assert(#Puzzles.read_openings(nil) == 0 and #Puzzles.read_openings({ openings = "x" }) == 0)
    -- The batch of an opening goes to its key, as a theme does.
    assert(Api.puzzle_batch(15, "Sicilian_Defense_Najdorf_Variation").path == "/api/puzzle/batch/Sicilian_Defense_Najdorf_Variation?nb=15")
end)

test("the recent openings keep the last five, the last first, and say which fell off", function()
    local recent = {}
    for index = 1, 5 do
        recent = Puzzles.remember_opening(recent, "O" .. index, "Opening " .. index)
    end
    assert(recent[1].key == "O5" and #recent == 5)
    local dropped
    recent, dropped = Puzzles.remember_opening(recent, "O3", "Opening 3")
    assert(recent[1].key == "O3" and #recent == 5 and #dropped == 0, "opening one again moves it up")
    recent, dropped = Puzzles.remember_opening(recent, "O6", "Opening 6")
    assert(recent[1].key == "O6" and #recent == 5 and #dropped == 1 and dropped[1] == "O1", "the oldest falls off: " .. tostring(dropped[1]))
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
