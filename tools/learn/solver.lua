-- A breadth-first search over the moves of a level of "Learn chess", with the opponent's scripted moves played as
-- the screen plays them, up to the par of the level. It proves a level can be done in its par, which catches a
-- position, a star or a condition ported wrong. Every promotion counts: one pawn level needs a knight.
local Chess = require("ink_knight/chess")
local Learn = require("ink_knight/learn")

local Solver = {}

local function clone(state)
    local copy = {}
    for key, value in pairs(state) do
        copy[key] = value
    end
    copy.position = Chess.copy_position(state.position)
    copy.apples = {}
    for square in pairs(state.apples) do
        copy.apples[square] = true
    end
    return copy
end

local function key(state)
    local apples = {}
    for square in pairs(state.apples) do
        apples[#apples + 1] = square
    end
    table.sort(apples)
    -- The position without its move counters, which do not change what can still happen.
    return Chess.epd(state.position) .. "|" .. table.concat(apples, ",") .. "|" .. state.scenario_index
end

local function player_moves(state)
    local list = {}
    for from = 1, 64 do
        for _, moves in pairs(Learn.targets(state, from)) do
            for _, move in ipairs(moves) do
                list[#list + 1] = move
            end
        end
    end
    return list
end

-- true when the level can be done in its par, false when it cannot, nil when budget moves were tried first.
function Solver.solvable(level, budget)
    local start = Learn.start(level)
    if Learn.is_opponent_scenario_turn(start) then
        Learn.opponent_scenario_move(start)
    end
    local frontier, seen, nodes = { start }, { [key(start)] = true }, 0
    for _ = 1, level.nb_moves do
        local next_frontier = {}
        for _, state in ipairs(frontier) do
            for _, move in ipairs(player_moves(state)) do
                nodes = nodes + 1
                if nodes > budget then
                    return nil
                end
                local child = clone(state)
                local follow = Learn.player_move(child, move)
                if child.completed then
                    return true
                end
                if follow == "scenario" then
                    Learn.opponent_scenario_move(child)
                end
                if not child.failed then
                    local id = key(child)
                    if not seen[id] then
                        seen[id] = true
                        next_frontier[#next_frontier + 1] = child
                    end
                end
            end
        end
        frontier = next_frontier
    end
    return false
end

return Solver
