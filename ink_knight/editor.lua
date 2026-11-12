-- Setting up a position: pieces put and taken away, the side to move, the castling that the pieces still allow, and
-- whether the position can be played. No KOReader here, so the tests can use it.
local Chess = require("ink_knight/chess")

local Editor = {}

Editor.EMPTY = "8/8/8/8/8/8/8/8 w - - 0 1"
Editor.PIECES = { "K", "Q", "R", "B", "N", "P", "k", "q", "r", "b", "n", "p" }

-- Each right needs the king and that rook on their first squares.
local CASTLING = {
    { letter = "K", king = 5, king_piece = "K", rook = 8, rook_piece = "R" },
    { letter = "Q", king = 5, king_piece = "K", rook = 1, rook_piece = "R" },
    { letter = "k", king = 61, king_piece = "k", rook = 64, rook_piece = "r" },
    { letter = "q", king = 61, king_piece = "k", rook = 57, rook_piece = "r" },
}

function Editor.new(fen)
    local position = Chess.parse_fen(fen or Chess.START_FEN) or Chess.parse_fen(Chess.START_FEN)
    position.passant, position.halfmove = nil, 0
    return position
end

-- The castling letters the pieces allow now.
function Editor.possible_castling(position)
    local letters = {}
    for _, right in ipairs(CASTLING) do
        if position.board[right.king] == right.king_piece and position.board[right.rook] == right.rook_piece then
            letters[#letters + 1] = right.letter
        end
    end
    return table.concat(letters)
end

-- Keeps only the rights the pieces still allow, so moving a king or a rook away takes them back.
local function trim_castling(position)
    local possible = Editor.possible_castling(position)
    position.castling = position.castling:gsub(".", function(letter)
        return possible:find(letter, 1, true) and letter or ""
    end)
end

-- Puts piece on square, or takes it away when the same piece is already there; nil takes away whatever is there.
function Editor.place(position, square, piece)
    if piece == nil or position.board[square] == piece then
        position.board[square] = nil
    else
        position.board[square] = piece
    end
    position.passant = nil
    trim_castling(position)
end

function Editor.toggle_castling(position, letter)
    if position.castling:find(letter, 1, true) then
        position.castling = position.castling:gsub(letter, "")
    elseif Editor.possible_castling(position):find(letter, 1, true) then
        local ordered = {}
        for _, right in ipairs(CASTLING) do
            if right.letter == letter or position.castling:find(right.letter, 1, true) then
                ordered[#ordered + 1] = right.letter
            end
        end
        position.castling = table.concat(ordered)
    end
end

function Editor.set_turn(position, turn)
    position.turn = turn
    position.passant = nil
end

function Editor.clear(position)
    position.board, position.castling, position.passant = {}, "", nil
end

function Editor.fen(position)
    return Chess.to_fen(position)
end

-- Reads a FEN typed or pasted by the reader: the position, or nil and the reason.
function Editor.read_fen(text)
    local position = Chess.parse_fen((tostring(text):gsub("^%s+", ""):gsub("%s+$", "")))
    if not position then
        return nil, "fen"
    end
    position.halfmove = 0
    trim_castling(position)
    return position
end

-- nil when the position can be played; otherwise why not: "kings" (one king a side), "pawn_rank" (a pawn on the
-- first or last rank), "too_many" (more than 16 pieces or 8 pawns a side), "check" (the side that just moved is in
-- check) or "over" (the side to move has no move: mate or stalemate already).
function Editor.problem(position)
    local count = { K = 0, k = 0 }
    local pieces, pawns = { w = 0, b = 0 }, { w = 0, b = 0 }
    for square, piece in pairs(position.board) do
        local side = piece == piece:upper() and "w" or "b"
        pieces[side] = pieces[side] + 1
        if piece == "K" or piece == "k" then
            count[piece] = count[piece] + 1
        elseif piece:lower() == "p" then
            pawns[side] = pawns[side] + 1
            if square <= 8 or square > 56 then
                return "pawn_rank"
            end
        end
    end
    if count.K ~= 1 or count.k ~= 1 then
        return "kings"
    end
    if pieces.w > 16 or pieces.b > 16 or pawns.w > 8 or pawns.b > 8 then
        return "too_many"
    end
    if Chess.in_check(position, position.turn ~= "w") then
        return "check"
    end
    if #Chess.legal_moves(position) == 0 then
        return "over"
    end
    return nil
end

return Editor
