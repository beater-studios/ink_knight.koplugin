-- Reads the moves of a game in the usual notation.
local Chess = require("ink_knight/chess")

local Pgn = {}

-- A list of moves in the usual notation, separated by spaces, as UCI moves.
function Pgn.san_list_to_moves(sans, fen)
    local position = Chess.parse_fen(fen or Chess.START_FEN)
    local moves = {}
    for san in tostring(sans):gmatch("%S+") do
        local move = position and Chess.parse_san(position, san)
        if not move then
            break
        end
        moves[#moves + 1] = { uci = Chess.move_to_uci(move), san = san }
        position = Chess.play(position, move)
    end
    return moves
end

return Pgn
