-- A small engine for games with no network. It runs in slices, so the screen never freezes while it thinks.
local Chess = require("ink_knight/chess")

local Engine = {}

local VALUE = { p = 100, n = 320, b = 330, r = 500, q = 900, k = 0 }
local MATE = 100000
Engine.MATE = MATE

-- Levels: how long it may think, how deep it may go, and how much it may stray from its best move.
Engine.LEVELS = {
    { seconds = 1, depth = 1, noise = 120 },
    { seconds = 2, depth = 2, noise = 40 },
    { seconds = 4, depth = 3, noise = 10 },
    { seconds = 8, depth = 4, noise = 0 },
}
-- A suggestion for the reader: no noise, so it is the best move found, and short enough to wait for.
Engine.HINT = { seconds = 3, depth = 3, noise = 0 }

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
-- opts: level (1 to 4) or limits (a table like those in LEVELS), now() for the time, random(n) for the noise,
-- nodes_per_slice. To look at a move played, opts.report gives { best, score, played, depth } instead of a move:
-- the best move and its score, and the exact score of the move opts.exact (in UCI), both for the side to move,
-- from the deepest search finished; nil scores when not even the first depth finished.
function Engine.search(position, opts)
    local level = opts.limits or Engine.LEVELS[opts.level] or Engine.LEVELS[1]
    local now = opts.now or os.time
    local random = opts.random or math.random
    local per_slice = opts.nodes_per_slice or 60
    return coroutine.create(function()
        local deadline = now() + level.seconds
        local nodes = 0
        local out_of_time = false
        local exact = opts.exact and Chess.parse_uci(position, opts.exact) or nil
        local function is_exact(move)
            return exact ~= nil and move.from == exact.from and move.to == exact.to and move.promotion == exact.promotion
        end
        local function tick()
            nodes = nodes + 1
            if nodes % per_slice == 0 then
                coroutine.yield()
                if now() >= deadline then
                    out_of_time = true
                end
            end
        end
        -- Past the depth, only captures, until the position is quiet, so a line does not end in the middle of an
        -- exchange and look better than it is. Only for the analysis (limits.quiescence): the levels of the
        -- games keep playing as they always did.
        local function quiesce(pos, alpha, beta, ply, left)
            tick()
            if out_of_time then
                return 0
            end
            local stand = pos.turn == "w" and evaluate(pos) or -evaluate(pos)
            if stand >= beta or left == 0 then
                return stand
            end
            alpha = math.max(alpha, stand)
            local white = pos.turn == "w"
            local captures = {}
            for _, move in ipairs(Chess.pseudo_legal_moves(pos)) do
                if pos.board[move.to] or (move.to == pos.passant and pos.board[move.from]:lower() == "p") then
                    captures[#captures + 1] = move
                end
            end
            for _, move in ipairs(ordered(pos, captures)) do
                local after = Chess.play(pos, move)
                if not Chess.in_check(after, white) then
                    local score = -quiesce(after, -beta, -alpha, ply + 1, left - 1)
                    if out_of_time then
                        return alpha
                    end
                    if score >= beta then
                        return score
                    end
                    alpha = math.max(alpha, score)
                end
            end
            return alpha
        end
        local function negamax(pos, depth, alpha, beta, ply)
            tick()
            if out_of_time then
                return 0
            end
            -- At the edge of the search only a check needs the list of moves, to tell a mate from a position
            -- that just looks bad. Building the list everywhere else would cost about as much as the evaluation thirty times.
            if depth == 0 then
                if Chess.in_check(pos) and #Chess.legal_moves(pos) == 0 then
                    return -(MATE - ply)
                end
                if level.quiescence then
                    return quiesce(pos, alpha, beta, ply, level.quiescence)
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
        local finished = 0
        root = ordered(position, root)
        for depth = 1, level.depth do
            local results = {}
            local best = -math.huge
            for _, move in ipairs(root) do
                -- Only moves that come within the noise of the best one so far can be chosen, so the others only
                -- need to be shown worse than that, which lets the search cut them short. The move looked at is
                -- searched in full, since its own score is what is wanted.
                local floor = (best > -math.huge and not is_exact(move)) and (best - level.noise - 1) or -MATE * 2
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
                finished = depth
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
            return opts.report and { best = root[1], depth = 0 } or root[1]
        end
        local top, top_move, played = -math.huge, nil, nil
        for _, entry in ipairs(scored) do
            if entry.score > top then
                top, top_move = entry.score, entry.move
            end
            if is_exact(entry.move) then
                played = entry.score
            end
        end
        if opts.report then
            return { best = top_move, score = top, played = played, depth = finished }
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
