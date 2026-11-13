-- Puts together what Lichess knows about a position, as text. It knows nothing about the screen or the network.
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

local function eval_section(s, position, cloud)
    local line = cloud and cloud.pvs and cloud.pvs[1]
    if not line then
        return s.analysis_no_eval
    end
    return string.format(s.analysis_eval, Api.eval_text(line.cp, line.mate), cloud.depth or 0, line_text(position, line.moves))
end

-- The most played moves of an answer of the explorer, of any of its databases; empty_text without games.
function Analysis.games_text(s, data, empty_text)
    local moves = type(data) == "table" and data.moves
    if type(moves) ~= "table" or #moves == 0 then
        return empty_text
    end
    local lines = {}
    if data.opening and data.opening.name then
        lines[#lines + 1] = data.opening.name
    end
    lines[#lines + 1] = s.analysis_games_title
    for index, move in ipairs(moves) do
        if index > EXPLORER_MOVES then
            break
        end
        local white, draws, black = move.white or 0, move.draws or 0, move.black or 0
        local total = white + draws + black
        if total > 0 then
            lines[#lines + 1] = string.format("%s: %d%% / %d%% / %d%% (%s)", move.san or move.uci or "?",
                math.floor(white / total * 100 + 0.5), math.floor(draws / total * 100 + 0.5), math.floor(black / total * 100 + 0.5),
                Api.format_count(total))
        end
    end
    return table.concat(lines, "\n")
end

local function tablebase_section(s, position, data)
    local winner = data and Api.tablebase_winner(data.category, position.turn)
    if not winner then
        return nil
    end
    local outcome = winner == "draw" and s.analysis_end_draw or (winner == "white" and s.analysis_end_white or s.analysis_end_black)
    local best = data.moves and data.moves[1] and data.moves[1].san
    return best and string.format(s.analysis_end_best, outcome, best) or outcome
end

-- answers: cloud, explorer and tablebase, each one nil when it did not come.
function Analysis.text(s, position, answers)
    local sections = { eval_section(s, position, answers.cloud), Analysis.games_text(s, answers.explorer, s.analysis_no_games) }
    local ending = tablebase_section(s, position, answers.tablebase)
    if ending then
        table.insert(sections, 1, ending)
    end
    return table.concat(sections, "\n\n")
end

return Analysis
