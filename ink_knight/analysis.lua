-- What Lichess knows about a position, read from its answers into what the analysis page shows. It knows nothing
-- about the screen or the network.
local Api = require("ink_knight/api")
local Chess = require("ink_knight/chess")

local Analysis = {}

-- Tablebases cover positions with up to this many pieces.
Analysis.TABLEBASE_PIECES = 7
local LINE_MOVES = 5
local EXPLORER_MOVES = 5

function Analysis.piece_count(position)
    local count = 0
    for _ in pairs(position.board) do
        count = count + 1
    end
    return count
end

-- The start of a line in UCI, in the usual notation. It stops at the first move it cannot read.
local function line_text(position, uci_line)
    local parts = {}
    for uci in tostring(uci_line):gmatch("%S+") do
        local next_position, move = Chess.apply_uci(position, uci)
        if not next_position or #parts >= LINE_MOVES then
            break
        end
        parts[#parts + 1] = Chess.to_san(position, move)
        position = next_position
    end
    return table.concat(parts, " ")
end

-- The cloud evaluation: { score, depth, line }, the score as Lichess writes it; nil without one.
function Analysis.eval(position, cloud)
    local line = type(cloud) == "table" and type(cloud.pvs) == "table" and cloud.pvs[1]
    if type(line) ~= "table" then
        return nil
    end
    return { score = Api.eval_text(line.cp, line.mate), depth = tonumber(cloud.depth) or 0, line = line_text(position, line.moves) }
end

-- An answer of the explorer, of any of its databases: { opening, moves = { { san, white, draws, black, total } } },
-- the most played first; nil without a game.
function Analysis.games(data)
    local list = type(data) == "table" and type(data.moves) == "table" and data.moves or {}
    local moves = {}
    for _, move in ipairs(list) do
        if #moves >= EXPLORER_MOVES then
            break
        end
        local white, draws, black = tonumber(move.white) or 0, tonumber(move.draws) or 0, tonumber(move.black) or 0
        local total = white + draws + black
        if total > 0 then
            moves[#moves + 1] = { san = move.san or move.uci or "?", white = white, draws = draws, black = black, total = total }
        end
    end
    if #moves == 0 then
        return nil
    end
    local opening = type(data.opening) == "table" and type(data.opening.name) == "string" and data.opening.name or nil
    return { opening = opening, moves = moves }
end

-- The result with perfect play, from the tablebase, as a sentence; nil when it does not know.
function Analysis.ending(s, position, data)
    local winner = type(data) == "table" and Api.tablebase_winner(data.category, position.turn)
    if not winner then
        return nil
    end
    local outcome = winner == "draw" and s.analysis_end_draw or (winner == "white" and s.analysis_end_white or s.analysis_end_black)
    local best = type(data.moves) == "table" and data.moves[1] and data.moves[1].san
    return best and string.format(s.analysis_end_best, outcome, best) or outcome
end

return Analysis
