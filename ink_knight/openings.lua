-- The name of the opening of a game, without internet, from the list Lichess publishes (chess-openings, CC0), in
-- ink_knight/data/openings.lua. Lichess names a game after the last position of its list the game went through,
-- whatever the order of the moves, and so does this. The list is only read the first time a name is asked for.
local Chess = require("ink_knight/chess")

local Openings = {}

local list

local function names()
    list = list or require("ink_knight/data/openings")
    return list
end

-- initial_fen: nil or "startpos" for the usual start; any other start has no opening name. moves: in UCI,
-- separated by spaces. nil when the game has not reached a position of the list.
function Openings.name(initial_fen, moves)
    if initial_fen ~= nil and initial_fen ~= "startpos" and initial_fen ~= Chess.START_FEN then
        return nil
    end
    local data = names()
    local position = Chess.parse_fen(Chess.START_FEN)
    local name, plies = nil, 0
    for uci in tostring(moves or ""):gmatch("%S+") do
        plies = plies + 1
        if plies > data.max_plies then
            break
        end
        position = Chess.apply_uci(position, uci)
        if not position then
            break
        end
        name = data.names[Chess.epd(position)] or name
    end
    return name
end

return Openings
