-- A small engine for games with no network. It runs in slices, so the screen never freezes while it thinks.
local Chess = require("ink_knight/chess")

local Engine = {}

local VALUE = { p = 100, n = 320, b = 330, r = 500, q = 900, k = 0 }
local MATE = 100000

-- Levels: how long it may think, how deep it may go, and how much it may stray from its best move.
Engine.LEVELS = {
    { seconds = 1, depth = 1, noise = 120 },
    { seconds = 2, depth = 2, noise = 40 },
    { seconds = 4, depth = 3, noise = 10 },
    { seconds = 8, depth = 4, noise = 0 },
}

local function file_rank(square)
    return (square - 1) % 8 + 1, math.floor((square - 1) / 8) + 1
end

-- Material, plus small rewards for the center and for pawns that advance. Positive is good for white.
local function evaluate(position)
    local score = 0
    for square, piece in pairs(position.board) do
        local kind = piece:lower()
        local white = piece ~= kind
        local file, rank = file_rank(square)
        local value = VALUE[kind]
        local center = 7 - (math.abs(2 * file - 9) + math.abs(2 * rank - 9))
        if kind == "n" or kind == "b" then
            value = value + center * 3
        elseif kind == "p" then
            value = value + (white and rank or 9 - rank) * 4 + center
        end
        score = score + (white and value or -value)
    end
    return score
end

-- The board being sorted, kept out here so that sorting does not make a new function at every node.
local sort_board

local function by_capture(a, b)
    local va = sort_board[a.to] and VALUE[sort_board[a.to]:lower()] or 0
    local vb = sort_board[b.to] and VALUE[sort_board[b.to]:lower()] or 0
    if va ~= vb then
        return va > vb
    end
    return a.to < b.to
end

local function ordered(position, moves)
    sort_board = position.board
    table.sort(moves, by_capture)
    sort_board = nil
    return moves
end

-- Returns a search that advances a little at each resume, and gives the move at the end.
-- opts: level (1 to 4), now() for the time, random(n) for the noise, nodes_per_slice.
function Engine.search(position, opts)
    local level = Engine.LEVELS[opts.level] or Engine.LEVELS[1]
    local now = opts.now or os.time
    local random = opts.random or math.random
    local per_slice = opts.nodes_per_slice or 60
    return coroutine.create(function()
        local deadline = now() + level.seconds
        local nodes = 0
        local out_of_time = false
        local function negamax(pos, depth, alpha, beta, ply)
            nodes = nodes + 1
            if nodes % per_slice == 0 then
                coroutine.yield()
                if now() >= deadline then
                    out_of_time = true
                end
            end
            if out_of_time then
                return 0
            end
            -- At the edge of the search only a check needs the list of moves, to tell a mate from a position
            -- that just looks bad. Building the list everywhere else would cost about as much as the evaluation thirty times.
            if depth == 0 then
                if Chess.in_check(pos) and #Chess.legal_moves(pos) == 0 then
                    return -(MATE - ply)
                end
                return pos.turn == "w" and evaluate(pos) or -evaluate(pos)
            end
            local moves = Chess.legal_moves(pos)
            if #moves == 0 then
                return Chess.in_check(pos) and -(MATE - ply) or 0
            end
            local best = -math.huge
            for _, move in ipairs(ordered(pos, moves)) do
                local score = -negamax(Chess.play(pos, move), depth - 1, -beta, -alpha, ply + 1)
                if out_of_time then
                    return best
                end
                if score > best then
                    best = score
                end
                alpha = math.max(alpha, score)
                if alpha >= beta then
                    break
                end
            end
            return best
        end
        local root = Chess.legal_moves(position)
        if #root == 0 then
            return nil
        end
        local scored = {}
        root = ordered(position, root)
        for depth = 1, level.depth do
            local results = {}
            local best = -math.huge
            for _, move in ipairs(root) do
                -- Only moves that come within the noise of the best one so far can be chosen, so the others only
                -- need to be shown worse than that, which lets the search cut them short.
                local floor = best > -math.huge and (best - level.noise - 1) or -MATE * 2
                local score = -negamax(Chess.play(position, move), depth - 1, -MATE * 2, -floor, 1)
                if out_of_time then
                    break
                end
                best = math.max(best, score)
                results[#results + 1] = { move = move, score = score }
            end
            -- A depth cut short by the clock is thrown away, because its scores cannot be compared.
            if #results == #root then
                scored = results
                -- The next depth looks first at what was best at this one, so it finds a good bound sooner.
                local sorted = {}
                for i, entry in ipairs(results) do
                    sorted[i] = { move = entry.move, score = entry.score, order = i }
                end
                table.sort(sorted, function(a, b)
                    if a.score ~= b.score then
                        return a.score > b.score
                    end
                    return a.order < b.order
                end)
                for i, entry in ipairs(sorted) do
                    root[i] = entry.move
                end
            end
            if out_of_time then
                break
            end
        end
        if #scored == 0 then
            return root[1]
        end
        local top = -math.huge
        for _, entry in ipairs(scored) do
            top = math.max(top, entry.score)
        end
        -- Lower levels take any move close enough to the best one. A forced mate is never thrown away.
        local noise = top >= MATE - 100 and 0 or level.noise
        local choices = {}
        for _, entry in ipairs(scored) do
            if entry.score >= top - noise then
                choices[#choices + 1] = entry.move
            end
        end
        return choices[random(#choices)]
    end)
end

return Engine
