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
    eq(kinds.goal, 165)
    eq(kinds.guided, 36)
    eq(kinds.lesson, 1)
    -- The tactics studies judged only by evaluation are left out whole: 27 of the 32.
    eq(studies, 27)
end)

test("every position, line, wrong move and drawing can be played and drawn", function()
    each_chapter(function(chapter)
        local position = assert(Chess.parse_fen(chapter.fen), chapter.id)
        assert(Chess.ending(position) == nil, chapter.id .. " starts over")
        assert(english[chapter.id .. ".n"], chapter.id .. " has no name")
        if chapter.kind == "goal" then
            assert(chapter.goal == "mate" or chapter.goal == "mate_in" or chapter.goal == "promotion", chapter.id)
            assert((chapter.goal == "mate_in") == (chapter.moves ~= nil) and (chapter.goal == "promotion") == (chapter.cp ~= nil), chapter.id)
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
