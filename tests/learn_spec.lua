package.path = "./?.lua;" .. package.path
local Chess = require("ink_knight/chess")
local Learn = require("ink_knight/learn")
local categories = require("ink_knight/data/learn_stages")
local texts = require("ink_knight/data/learn_texts")

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

local function stages()
    local list = {}
    for _, category in ipairs(categories) do
        for _, stage in ipairs(category.stages) do
            list[#list + 1] = stage
        end
    end
    return list
end

test("there are the 18 stages of the app, with every text in the three languages", function()
    eq(#categories, 4)
    local all = stages()
    eq(#all, 18)
    local levels = 0
    for _, language in ipairs({ "en", "pt", "es" }) do
        for _, category in ipairs(categories) do
            assert(texts[language][category.name], language .. ": " .. category.name)
        end
        for _, stage in ipairs(all) do
            for _, field in ipairs({ "title", "subtitle", "intro", "complete" }) do
                assert(texts[language][stage[field]], language .. ": " .. stage.key .. "." .. field)
            end
            for index, level in ipairs(stage.levels) do
                assert(texts[language][level.goal], language .. ": " .. stage.key .. " level " .. index)
            end
        end
    end
    for _, stage in ipairs(all) do
        levels = levels + #stage.levels
    end
    eq(levels, 110)
end)

local Solver = require("tools/learn/solver")

test("every level can be done within its par, as on the site", function()
    local unproven = {}
    for _, stage in ipairs(stages()) do
        for index, level in ipairs(stage.levels) do
            local result = Solver.solvable(level, 4000)
            if result == false then
                error(stage.key .. " level " .. index .. " cannot be done in " .. level.nb_moves .. " moves")
            elseif result == nil then
                unproven[#unproven + 1] = stage.key .. " " .. index
            end
        end
    end
    -- The big levels need tools/learn/prove_levels.lua, with a larger budget.
    assert(#unproven <= 24, "too many levels left unproven: " .. table.concat(unproven, ", "))
end)

test("a star taken scores, and all of them finish the level with the bonus", function()
    local level = categories[1].stages[1].levels[2]
    local state = Learn.start(level)
    eq(Learn.display_position(state).board[Chess.square_from_name("c5")], nil)
    eq(state.position.board[Chess.square_from_name("c5")], "p")
    Learn.player_move(state, { from = Chess.square_from_name("c7"), to = Chess.square_from_name("c5") })
    eq(state.score, 50); eq(state.completed, false); eq(state.position.turn, "w")
    Learn.player_move(state, { from = Chess.square_from_name("c5"), to = Chess.square_from_name("g5") })
    eq(state.completed, true); eq(state.score, 600)
    eq(Learn.level_rank(level, state.score), 1)
end)

test("a piece left where the enemy can take it for free fails the level, and the capture is shown", function()
    -- Capture, level 2: the queen must take the rook first, since taking the pawn leaves her to the rook.
    local level = categories[2].stages[1].levels[2]
    local state = Learn.start(level)
    local follow = Learn.player_move(state, { from = Chess.square_from_name("f4"), to = Chess.square_from_name("f7") })
    eq(state.failed, true); eq(follow, "capture")
    Learn.opponent_capture(state)
    eq(state.position.board[Chess.square_from_name("f7")], "r")
end)

test("a move into check is offered and fails where the level lets the player blunder", function()
    local level = categories[2].stages[5].levels[1]
    local state = Learn.start(level)
    local into_check = Learn.targets(state, Chess.square_from_name("e1"))[Chess.square_from_name("e2")]
    assert(into_check, "the king may step into the queen's line")
    Learn.player_move(state, into_check[1])
    eq(state.failed, true)
    assert(#state.shapes > 0, "the attack should be drawn")
end)

test("the opponent's scripted move comes after the player's, and en passant takes", function()
    local level = categories[3].stages[3].levels[1]
    local state = Learn.start(level)
    eq(Learn.is_opponent_scenario_turn(state), true)
    Learn.opponent_scenario_move(state)
    eq(Learn.is_player_turn(state), true)
    Learn.player_move(state, { from = Chess.square_from_name("c5"), to = Chess.square_from_name("d6") })
    eq(state.completed, true)
    eq(state.position.board[Chess.square_from_name("d5")], nil)
end)

test("the ranks follow the score, and a stage has a rank only with every level done", function()
    local stage = categories[1].stages[1]
    local scores = {}
    eq(Learn.stage_rank(stage, scores), nil)
    for index, level in ipairs(stage.levels) do
        scores[index] = level.apple_count * 50 + 500
    end
    eq(Learn.stage_rank(stage, scores), 1)
    scores[1] = scores[1] - 400
    eq(Learn.stage_rank(stage, scores), 2)
end)

test("after the move that shows why a mate failed, the check mark follows the king", function()
    -- Mate in one, level 1: Bxf7+ is check but not mate, and a random reply follows.
    local level = categories[2].stages[6].levels[1]
    local state = Learn.start(level)
    local follow = Learn.player_move(state, { from = Chess.square_from_name("c4"), to = Chess.square_from_name("f7") })
    eq(state.failed, true); eq(follow, "random")
    Learn.random_opponent_move(state, function() return 1 end)
    local king = Chess.king_square(state.position, "b")
    eq(state.check_square, Chess.in_check(state.position) and king or nil)
end)

test("the progress counts each stage started by its stars, as on the site", function()
    eq(Learn.percent(categories, {}), 0)
    -- Only the first rook level, with three stars: the stage ranks one star, 5 points of 180.
    eq(Learn.percent(categories, { rook = { [1] = 550 } }), 3)
    local all = {}
    for _, category in ipairs(categories) do
        for _, stage in ipairs(category.stages) do
            all[stage.key] = {}
            for index, level in ipairs(stage.levels) do
                all[stage.key][index] = level.apple_count * 50 + (level.points_for_capture and level.captures * 50 or 0) + 500
            end
        end
    end
    eq(Learn.percent(categories, all), 100)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
