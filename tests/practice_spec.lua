package.path = "./?.lua;" .. package.path
local Chess = require("ink_knight/chess")
local Practice = require("ink_knight/practice")
local sections = require("ink_knight/data/practice")
local english = require("ink_knight/data/practice_texts_en")

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

local function each_chapter(fn)
    for _, section in ipairs(sections) do
        for _, study in ipairs(section.studies) do
            for index, chapter in ipairs(study.chapters) do
                fn(chapter, study, index)
            end
        end
    end
end

local function move(position, uci)
    return assert(Chess.parse_uci(position, uci), "not a legal move: " .. uci)
end

test("the lessons: the chapters the plugin can judge, in their studies", function()
    local kinds, studies = {}, 0
    for _, section in ipairs(sections) do
        studies = studies + #section.studies
    end
    each_chapter(function(chapter)
        kinds[chapter.kind] = (kinds[chapter.kind] or 0) + 1
    end)
    eq(#sections, 5)
    -- 165 judged by the engine or the rules, 103 by a tree of moves and 3 by the table of king and pawn.
    eq(kinds.goal, 271)
    eq(kinds.guided, 36)
    eq(kinds.lesson, 1)
    -- Every study has chapters the plugin can judge.
    eq(studies, 32)
end)

test("every position, line, wrong move and drawing can be played and drawn", function()
    each_chapter(function(chapter)
        local position = assert(Chess.parse_fen(chapter.fen), chapter.id)
        assert(Chess.ending(position) == nil, chapter.id .. " starts over")
        assert(english[chapter.id .. ".n"], chapter.id .. " has no name")
        if chapter.kind == "goal" then
            local scripted = Practice.SCRIPTED_GOALS[chapter.goal] == true
            assert(chapter.goal == "mate" or chapter.goal == "mate_in" or chapter.goal == "promotion" or scripted, chapter.id)
            assert((chapter.goal == "mate_in" or scripted) == (chapter.moves ~= nil), chapter.id)
            assert((chapter.goal == "promotion" or chapter.goal == "eval_in") == (chapter.cp ~= nil), chapter.id)
            for _, shape in ipairs(Practice.shapes(chapter.shapes)) do
                assert(shape.brush and shape.from, chapter.id .. " has a shape it cannot draw")
            end
        else
            local state = Practice.start_guided(chapter)
            for ply = 1, #chapter.line do
                assert(state.positions[ply], chapter.id .. ": move " .. ply .. " is not legal")
            end
            for ply, wrong in pairs(chapter.wrong or {}) do
                assert(state.positions[ply - 1].turn == chapter.color, chapter.id .. ": a wrong move of the opponent")
                for uci in pairs(wrong) do
                    move(state.positions[ply - 1], uci)
                    assert(uci ~= chapter.line[ply], chapter.id .. ": the right move marked wrong")
                end
            end
            for ply, text in pairs(chapter.shapes or {}) do
                assert(ply >= 0 and ply <= #chapter.line, chapter.id)
                assert(#Practice.shapes(text) > 0, chapter.id)
            end
        end
    end)
end)

-- A forced mate in n moves for the side to move, the plain way.
local function mates_in(position, n)
    for _, candidate in ipairs(Chess.legal_moves(position)) do
        local after = Chess.play(position, candidate)
        local replies = Chess.legal_moves(after)
        if #replies == 0 then
            if Chess.in_check(after) then
                return true
            end
        elseif n > 1 then
            local all = true
            for _, reply in ipairs(replies) do
                if not mates_in(Chess.play(after, reply), n - 1) then
                    all = false
                    break
                end
            end
            if all then
                return true
            end
        end
    end
    return false
end

test("the mates in one and two can be given, by the side the reader plays", function()
    local checked = 0
    each_chapter(function(chapter)
        if chapter.goal == "mate_in" and chapter.moves <= 2 then
            local position = Chess.parse_fen(chapter.fen)
            eq(position.turn, chapter.color)
            assert(mates_in(position, chapter.moves), chapter.id .. " has no mate in " .. chapter.moves)
            checked = checked + 1
        end
    end)
    assert(checked > 40, "too few mates checked: " .. checked)
end)

test("every text belongs to a chapter, and the translations have the same ones", function()
    local ids = {}
    each_chapter(function(chapter)
        ids[chapter.id] = chapter
    end)
    for key in pairs(english) do
        assert(ids[key:match("^(%w+)%.")], "a text of no chapter: " .. key)
    end
    for _, language in ipairs({ "pt", "es" }) do
        local translated = require("ink_knight/data/practice_texts_" .. language)
        for key, text in pairs(english) do
            local other = translated[key]
            assert(other, language .. ": missing " .. key)
            assert(not other:find("\226\128\148", 1, true) and not other:find("\226\128\147", 1, true), language .. ": a dash in " .. key)
            -- The squares named stay the same.
            local function squares(value)
                local list = {}
                for square in value:gmatch("%f[%w][a-h][1-8]%f[%W]") do
                    list[#list + 1] = square
                end
                table.sort(list)
                return table.concat(list, " ")
            end
            if squares(other) ~= squares(text) then
                error(string.format("%s: %s names other squares: %s / %s", language, key, squares(text), squares(other)))
            end
        end
        for key in pairs(translated) do
            assert(english[key], language .. ": a text English does not have: " .. key)
        end
    end
end)

test("progress keeps the fewest moves, and a study opens at its first chapter not done", function()
    local study = sections[1].studies[1]
    local progress = {}
    eq(Practice.first_open(study, progress), 1)
    assert(Practice.record(progress, study.chapters[1].id, 9))
    assert(Practice.record(progress, study.chapters[1].id, 7))
    assert(not Practice.record(progress, study.chapters[1].id, 8))
    eq(progress[study.chapters[1].id], 7)
    eq(Practice.first_open(study, progress), 2)
    eq(Practice.count_done(study, progress), 1)
    eq(Practice.percent(sections, progress), 0)
    each_chapter(function(chapter)
        progress[chapter.id] = 1
    end)
    eq(Practice.percent(sections, progress), 100)
    eq(Practice.first_open(study, progress), 1)
end)

local function goal_chapter(fields)
    local chapter = { kind = "goal", color = "w", goal = "mate" }
    for key, value in pairs(fields) do
        chapter[key] = value
    end
    return chapter
end

test("a mate solves the chapter, and the moves are counted", function()
    local chapter = goal_chapter({ fen = "7k/8/6K1/8/8/8/8/R7 w - - 0 1", goal = "mate_in", moves = 1 })
    local state = Practice.start_goal(chapter)
    eq(Practice.play(state, chapter, move(state.position, "a1a8")), "over")
    eq(state.status, "solved")
    eq(state.played, 1)
end)

test("a mate in so many moves fails once the moves are spent", function()
    local chapter = goal_chapter({ fen = "7k/8/6K1/8/8/8/8/R7 w - - 0 1", goal = "mate_in", moves = 1 })
    local state = Practice.start_goal(chapter)
    eq(Practice.play(state, chapter, move(state.position, "a1a2")), "over")
    eq(state.status, "failed")
    eq(state.reason, "slow")
end)

test("a stalemate, a dead draw or a mate by the opponent fails it", function()
    local chapter = goal_chapter({ fen = "7k/8/8/6Q1/8/8/8/K7 w - - 0 1" })
    local state = Practice.start_goal(chapter)
    eq(Practice.play(state, chapter, move(state.position, "g5g6")), "over")
    eq(state.reason, "draw")
    -- The queen left to be taken: no mate left.
    chapter = goal_chapter({ fen = "7k/6Q1/8/8/8/8/8/K7 b - - 0 1" })
    state = Practice.start_goal(chapter)
    eq(Practice.play(state, chapter, move(state.position, "h8g7")), "over")
    eq(state.reason, "draw")
    chapter = goal_chapter({ fen = "6k1/8/8/8/8/8/5PPP/r5K1 w - - 0 1" })
    state = Practice.start_goal(chapter)
    eq(Practice.play(state, chapter, move(state.position, "h2h3")), "reply")
    eq(state.status, "playing")
    chapter = goal_chapter({ fen = "6k1/8/8/8/8/8/5PPP/1r4K1 b - - 0 1", color = "w" })
    state = Practice.start_goal(chapter)
    eq(Practice.play(state, chapter, move(state.position, "b1e1")), "over")
    eq(state.reason, "lost")
end)

test("fifty moves without a capture do not end a goal, as in the app", function()
    local chapter = goal_chapter({ fen = "7k/8/8/8/8/8/R7/K7 w - - 99 60" })
    local state = Practice.start_goal(chapter)
    eq(Practice.play(state, chapter, move(state.position, "a2b2")), "reply")
    eq(state.status, "playing")
end)

test("the same position a third time ends a mate, not a promotion", function()
    local chapter = goal_chapter({ fen = "7k/8/8/8/8/8/R7/K7 w - - 0 1", goal = "promotion", cp = 100 })
    local state = Practice.start_goal(chapter)
    for _, uci in ipairs({ "a2b2", "h8g8", "b2a2", "g8h8", "a2b2", "h8g8", "b2a2", "g8h8" }) do
        Practice.play(state, chapter, move(state.position, uci))
    end
    eq(state.status, "playing")
end)

test("the same position a third time is a draw", function()
    local chapter = goal_chapter({ fen = "7k/8/8/8/8/8/R7/K7 w - - 0 1" })
    local state = Practice.start_goal(chapter)
    local steps = { "a2b2", "h8g8", "b2a2", "g8h8", "a2b2", "h8g8", "b2a2", "g8h8" }
    local last
    for _, uci in ipairs(steps) do
        last = Practice.play(state, chapter, move(state.position, uci))
    end
    eq(last, "over")
    eq(state.reason, "draw")
end)

test("a promotion is judged on the score the engine gives, for white as on Lichess", function()
    local chapter = goal_chapter({ fen = "8/4P1k1/8/8/8/8/8/4K3 w - - 0 1", goal = "promotion", cp = 100 })
    local state = Practice.start_goal(chapter)
    eq(Practice.play(state, chapter, move(state.position, "e7e8q")), "judge")
    -- The score is for black, to move: -800 means +800 for white.
    Practice.judge_promotion(state, chapter, -800)
    eq(state.status, "solved")
    state = Practice.start_goal(chapter)
    Practice.play(state, chapter, move(state.position, "e7e8q"))
    Practice.judge_promotion(state, chapter, 50)
    eq(state.status, "failed")
    eq(state.reason, "promotion")
    -- Played as black, the target is negative.
    chapter = goal_chapter({ fen = "4k3/8/8/8/8/8/1p4K1/8 b - - 0 1", color = "b", goal = "promotion", cp = -500 })
    state = Practice.start_goal(chapter)
    eq(Practice.play(state, chapter, move(state.position, "b2b1q")), "judge")
    Practice.judge_promotion(state, chapter, -850)
    eq(state.status, "solved")
end)

-- The chapters judged without the engine ---------------------------------------------------------------------------

local trees = require("ink_knight/data/practice_trees")
local Kpk = require("ink_knight/kpk")

local legal_named = Chess.legal_uci

test("every tree: legal moves, the reader to move, a way to the goal from every position", function()
    local count = 0
    local function walk(node, position, where)
        local solvable = false
        for _, entry in ipairs(node) do
            local reader = assert(legal_named(position, entry[1]), where .. ": " .. entry[1])
            if entry[2] == true then
                solvable = true
            elseif entry[3] then
                local after = Chess.play(position, reader)
                local reply = assert(legal_named(after, entry[2]), where .. ": reply " .. entry[2])
                walk(entry[3], Chess.play(after, reply), where .. " " .. entry[1])
                solvable = true
            else
                eq(entry[2], false)
            end
        end
        assert(solvable, where .. ": no way to the goal")
        for uci in tostring(node.o or ""):gmatch("%S+") do
            assert(legal_named(position, uci), where .. ": other " .. uci)
        end
    end
    each_chapter(function(chapter)
        if Practice.TREE_GOALS[chapter.goal] then
            local tree = assert(trees[chapter.id], chapter.id .. " has no tree")
            local position = Chess.parse_fen(chapter.fen)
            if tree.first then
                position = Chess.play(position, assert(legal_named(position, tree.first), chapter.id))
            end
            eq(position.turn, chapter.color)
            walk(tree.tree, position, chapter.id)
            count = count + 1
        end
    end)
    for id in pairs(trees) do
        assert(Practice.find(sections, id), "a tree of no chapter: " .. id)
    end
    assert(count > 90, "too few trees: " .. count)
end)

-- Plays a chapter judged without the engine: the reader's moves from pick(state), the opponent's from the script.
local function play_scripted(chapter, pick)
    local state = Practice.start_goal(chapter)
    if not Practice.is_player_turn(state) then
        Practice.play(state, chapter, Practice.scripted_reply(state, chapter))
    end
    local guard = 0
    while state.status == "playing" do
        guard = guard + 1
        assert(guard < 100, chapter.id .. " never ends")
        local step = Practice.play(state, chapter, pick(state))
        if step == "reply" then
            Practice.play(state, chapter, assert(Practice.scripted_reply(state, chapter), chapter.id .. ": no reply"))
        end
    end
    return state
end

test("the best moves of every tree solve its chapter, within its moves", function()
    each_chapter(function(chapter)
        if Practice.TREE_GOALS[chapter.goal] then
            local state = play_scripted(chapter, function(s) return Practice.best_move(s, chapter) end)
            if state.status ~= "solved" then
                error(chapter.id .. ": " .. tostring(state.reason))
            end
            assert(state.played <= chapter.moves, chapter.id .. " took " .. state.played)
        end
    end)
end)

test("a move the tree calls a mistake fails it, naming a better one; a fair one it did not follow is tried again", function()
    local mistakes, others = 0, 0
    each_chapter(function(chapter)
        local tree = Practice.TREE_GOALS[chapter.goal] and trees[chapter.id]
        if not tree then
            return
        end
        local state = Practice.start_goal(chapter)
        if not Practice.is_player_turn(state) then
            Practice.play(state, chapter, Practice.scripted_reply(state, chapter))
        end
        local known = {}
        for _, entry in ipairs(state.node) do
            known[entry[1]] = true
        end
        for uci in tostring(state.node.o or ""):gmatch("%S+") do
            known[uci] = true
            if others == 0 then
                local before = Chess.epd(state.position)
                eq(Practice.play(state, chapter, legal_named(state.position, uci)), "move")
                eq(state.notice, "other")
                eq(Chess.epd(state.position), before)
                eq(state.status, "playing")
                others = others + 1
            end
        end
        for _, legal in ipairs(Chess.legal_moves(state.position)) do
            if not known[Chess.move_to_uci(legal)] then
                local copy = Practice.start_goal(chapter)
                if not Practice.is_player_turn(copy) then
                    Practice.play(copy, chapter, Practice.scripted_reply(copy, chapter))
                end
                Practice.play(copy, chapter, legal)
                if copy.status ~= "solved" then
                    eq(copy.status, "failed")
                    assert(copy.reason == "mistake" or copy.reason == "draw" or copy.reason == "lost", chapter.id .. ": " .. tostring(copy.reason))
                    if copy.reason == "mistake" then
                        assert(copy.better, chapter.id .. ": no better move named")
                        mistakes = mistakes + 1
                    end
                end
                break
            end
        end
    end)
    assert(mistakes > 50 and others > 0, string.format("mistakes %d, others %d", mistakes, others))
end)

test("a mistake fails even when it draws, as in the app", function()
    -- A made-up chapter to equalize, whose tree knows only the mate; the stalemate is not in it.
    trees.test_stalemate = { tree = { { "c1c8", true } } }
    local chapter = goal_chapter({ id = "test_stalemate", fen = "k7/8/1K6/8/8/8/8/2Q5 w - - 0 1", goal = "equal_in", moves = 1 })
    local state = Practice.start_goal(chapter)
    Practice.play(state, chapter, move(state.position, "c1c7"))
    eq(state.status, "failed")
    eq(state.reason, "mistake")
    eq(state.better, "Qc8#")
    state = Practice.start_goal(chapter)
    Practice.play(state, chapter, move(state.position, "c1c8"))
    eq(state.status, "solved")
    trees.test_stalemate = nil
end)

test("king and pawn against king: the table knows the opposition, both ways and on both wings", function()
    -- Checked against Stockfish: the king ahead of its pawn wins with the move, and the other king holds with it.
    eq(Kpk.result(Chess.parse_fen("4k3/8/8/4K3/4P3/8/8/8 w - - 0 1")), "win")
    eq(Kpk.result(Chess.parse_fen("4k3/8/8/4K3/4P3/8/8/8 b - - 0 1")), "draw")
    -- The same for black, and a pawn on the other wing with the defending king in front of it.
    eq(Kpk.result(Chess.parse_fen("8/8/8/4p3/4k3/8/8/4K3 b - - 0 1")), "win")
    eq(Kpk.result(Chess.parse_fen("8/8/8/4p3/4k3/8/8/4K3 w - - 0 1")), "draw")
    eq(Kpk.result(Chess.parse_fen("8/8/8/8/2k5/2p5/8/2K5 b - - 0 1")), "draw")
    -- A rook pawn with the other king in the corner is a draw whoever moves.
    eq(Kpk.result(Chess.parse_fen("k7/8/K7/P7/8/8/8/8 w - - 0 1")), "draw")
    eq(Kpk.result(Chess.parse_fen("k7/8/K7/P7/8/8/8/8 b - - 0 1")), "draw")
    eq(Kpk.result(Chess.parse_fen("4k3/8/4K3/4P3/8/8/8/7Q w - - 0 1")), nil)
end)

test("holding the draw in king and pawn: the drawing moves solve it, a losing one fails it", function()
    local count = 0
    each_chapter(function(chapter)
        if chapter.goal == "draw_in" then
            count = count + 1
            local state = play_scripted(chapter, function(s) return Practice.best_move(s, chapter) end)
            eq(state.status, "solved")
            -- Any move that lets the pawn through fails at once.
            local lost = Practice.start_goal(chapter)
            local losing
            for _, legal in ipairs(Chess.legal_moves(lost.position)) do
                if Kpk.result(Chess.play(lost.position, legal)) == "win" then
                    losing = legal
                    break
                end
            end
            if losing then
                Practice.play(lost, chapter, losing)
                eq(lost.status, "failed")
                eq(lost.reason, "mistake")
                assert(lost.better, "a better move is named")
            end
        end
    end)
    eq(count, 3)
end)

local function find(id)
    return (Practice.find(sections, id))
end

test("a guided chapter: the author's moves, the opponent's, a wrong one taken back, the end", function()
    local chapter = find("5OqFMeoY")
    local state = Practice.start_guided(chapter)
    eq(Practice.feedback(state, chapter), "play")
    eq(Practice.comment(state, chapter, english), english["5OqFMeoY.c0"])
    assert(#Practice.guided_shapes(state, chapter) > 0, "the drawing of the start")
    eq(Chess.move_to_uci(Practice.solution(state, chapter)), "e1e2")
    Practice.guided_move(state, chapter, move(state.positions[0], "e1d2"))
    eq(Practice.feedback(state, chapter), "bad")
    eq(Chess.move_to_uci(select(2, Practice.guided_position(state))), "e1d2")
    Practice.guided_next(state, chapter)
    eq(Practice.feedback(state, chapter), "play")
    Practice.guided_move(state, chapter, move(state.positions[0], "e1e2"))
    eq(state.ply, 1)
    eq(Practice.feedback(state, chapter), "good")
    Practice.guided_next(state, chapter)
    eq(Practice.comment(state, chapter, english), english["5OqFMeoY.c2"])
    while Practice.feedback(state, chapter) ~= "end" do
        if Practice.feedback(state, chapter) == "play" then
            Practice.guided_move(state, chapter, Practice.solution(state, chapter))
        else
            Practice.guided_next(state, chapter)
        end
    end
    eq(Practice.guided_moves(state, chapter), 15)
end)

test("a wrong move has the author's comment for it, or the one for any move", function()
    local chapter = find("mXNCYwCt")
    local state = Practice.start_guided(chapter)
    assert(english["mXNCYwCt.h0"], "the hint of the first move")
    eq(Practice.hint(state, chapter, english), english["mXNCYwCt.h0"])
    local right = chapter.line[1]
    local wrong
    for _, candidate in ipairs(Chess.legal_moves(state.positions[0])) do
        local uci = Chess.move_to_uci(candidate)
        if uci ~= right and not (chapter.wrong and chapter.wrong[1] and chapter.wrong[1][uci]) then
            wrong = candidate
            break
        end
    end
    Practice.guided_move(state, chapter, wrong)
    assert(english["mXNCYwCt.v1"], "the comment for any wrong move of the first move")
    eq(Practice.comment(state, chapter, english), english["mXNCYwCt.v1"])
    eq(Practice.hint(state, chapter, english), nil)
    -- A move off the line the author wrote a comment for.
    local found = false
    each_chapter(function(other)
        for ply, list in pairs(other.wrong or {}) do
            for uci in pairs(list) do
                local key = other.id .. ".w" .. ply .. "." .. uci
                if english[key] and not found then
                    found = true
                    local guided = Practice.start_guided(other)
                    while guided.ply < ply - 1 do
                        if Practice.feedback(guided, other) == "play" then
                            Practice.guided_move(guided, other, Practice.solution(guided, other))
                        else
                            Practice.guided_next(guided, other)
                        end
                    end
                    Practice.guided_move(guided, other, move(guided.positions[guided.ply], uci))
                    eq(Practice.comment(guided, other, english), english[key])
                end
            end
        end
    end)
    assert(found, "no wrong move with a comment")
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
