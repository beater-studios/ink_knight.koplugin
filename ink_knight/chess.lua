-- The rules of chess, with no KOReader dependency. Squares go from 1 (a1) to 64 (h8).
local Chess = {}

Chess.START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

local KNIGHT = { { 1, 2 }, { 2, 1 }, { 2, -1 }, { 1, -2 }, { -1, -2 }, { -2, -1 }, { -2, 1 }, { -1, 2 } }
local KING = { { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 } }
local ROOK = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local BISHOP = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local QUEEN = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local PROMOTIONS = { "q", "r", "b", "n" }

local function index(file, rank)
    return (rank - 1) * 8 + file
end

local function file_of(square)
    return (square - 1) % 8 + 1
end

local function rank_of(square)
    return math.floor((square - 1) / 8) + 1
end

local function on_board(file, rank)
    return file >= 1 and file <= 8 and rank >= 1 and rank <= 8
end

local function is_white(piece)
    return piece == piece:upper()
end

function Chess.square_name(square)
    return string.char(96 + file_of(square)) .. rank_of(square)
end

function Chess.square_from_name(name)
    local file, rank = tostring(name):match("^([a-h])([1-8])$")
    if not file then
        return nil
    end
    return index(file:byte() - 96, tonumber(rank))
end

function Chess.parse_fen(fen)
    local placement, turn, castling, passant = tostring(fen):match("^(%S+)%s+([wb])%s+(%S+)%s+(%S+)")
    if not placement then
        return nil, "invalid FEN"
    end
    local board, rank, file = {}, 8, 1
    for char in placement:gmatch(".") do
        if char == "/" then
            rank, file = rank - 1, 1
        elseif char:match("%d") then
            file = file + tonumber(char)
        elseif char:match("[prnbqkPRNBQK]") then
            if not on_board(file, rank) then
                return nil, "invalid FEN"
            end
            board[index(file, rank)] = char
            file = file + 1
        else
            return nil, "invalid FEN"
        end
    end
    return {
        board = board,
        turn = turn,
        castling = castling == "-" and "" or castling,
        passant = passant ~= "-" and Chess.square_from_name(passant) or nil,
        halfmove = tonumber(tostring(fen):match("^%S+%s+[wb]%s+%S+%s+%S+%s+(%d+)")) or 0,
    }
end

local function find_king(position, white)
    local king = white and "K" or "k"
    for square = 1, 64 do
        if position.board[square] == king then
            return square
        end
    end
end

-- Whether a slider of either kind sits at the end of one of these rays. It lives out here, and not inside
-- is_attacked, because making a function on each call allocates and keeps LuaJIT from compiling the hot path.
local function slides(board, file, rank, steps, first, second)
    for i = 1, #steps do
        local step = steps[i]
        local df, dr = step[1], step[2]
        local f, r = file + df, rank + dr
        while f >= 1 and f <= 8 and r >= 1 and r <= 8 do
            local piece = board[(r - 1) * 8 + f]
            if piece then
                if piece == first or piece == second then
                    return true
                end
                break
            end
            f, r = f + df, r + dr
        end
    end
    return false
end

local function jumps(board, file, rank, steps, piece)
    for i = 1, #steps do
        local step = steps[i]
        local f, r = file + step[1], rank + step[2]
        if f >= 1 and f <= 8 and r >= 1 and r <= 8 and board[(r - 1) * 8 + f] == piece then
            return true
        end
    end
    return false
end

-- Whether a side attacks a square, walking out from the square to where its pieces would have to be.
function Chess.is_attacked(position, square, by_white)
    local board = position.board
    local file, rank = file_of(square), rank_of(square)
    local from_rank = rank + (by_white and -1 or 1)
    if from_rank >= 1 and from_rank <= 8 then
        local pawn = by_white and "P" or "p"
        if (file > 1 and board[index(file - 1, from_rank)] == pawn) or (file < 8 and board[index(file + 1, from_rank)] == pawn) then
            return true
        end
    end
    if jumps(board, file, rank, KNIGHT, by_white and "N" or "n") or jumps(board, file, rank, KING, by_white and "K" or "k") then
        return true
    end
    local queen = by_white and "Q" or "q"
    return slides(board, file, rank, ROOK, by_white and "R" or "r", queen)
        or slides(board, file, rank, BISHOP, by_white and "B" or "b", queen)
end

function Chess.in_check(position, white)
    if white == nil then
        white = position.turn == "w"
    end
    local king = find_king(position, white)
    return king ~= nil and Chess.is_attacked(position, king, not white)
end

local function copy(position)
    local board = {}
    for square, piece in pairs(position.board) do
        board[square] = piece
    end
    return { board = board, turn = position.turn, castling = position.castling, passant = position.passant, halfmove = position.halfmove }
end

local function drop_castling(castling, letters)
    return (castling:gsub("[" .. letters .. "]", ""))
end

-- Plays a move on a copy, without checking that it is legal.
local function play(position, move)
    local next_position = copy(position)
    local board = next_position.board
    local piece = board[move.from]
    local white = is_white(piece)
    local kind = piece:lower()
    next_position.halfmove = (kind == "p" or board[move.to]) and 0 or (position.halfmove or 0) + 1
    board[move.from] = nil
    if kind == "p" and move.to == position.passant then
        board[index(file_of(move.to), rank_of(move.from))] = nil
    end
    board[move.to] = move.promotion and (white and move.promotion:upper() or move.promotion) or piece
    -- The square passed over only counts when an enemy pawn stands beside the one that moved, as in a FEN
    -- from Lichess. Otherwise the same position would look different the first time, and repetitions would be missed.
    next_position.passant = nil
    if kind == "p" and math.abs(rank_of(move.to) - rank_of(move.from)) == 2 then
        local file, rank = file_of(move.to), rank_of(move.to)
        local enemy = white and "p" or "P"
        if (file > 1 and board[index(file - 1, rank)] == enemy) or (file < 8 and board[index(file + 1, rank)] == enemy) then
            next_position.passant = index(file, (rank_of(move.from) + rank) / 2)
        end
    end
    if kind == "k" then
        local rank = rank_of(move.from)
        local distance = file_of(move.to) - file_of(move.from)
        if distance == 2 then
            board[index(6, rank)], board[index(8, rank)] = board[index(8, rank)], nil
        elseif distance == -2 then
            board[index(4, rank)], board[index(1, rank)] = board[index(1, rank)], nil
        end
        next_position.castling = drop_castling(next_position.castling, white and "KQ" or "kq")
    end
    -- A rook that moves or is taken ends the castling on its side.
    for _, square in ipairs({ move.from, move.to }) do
        if square == 1 then next_position.castling = drop_castling(next_position.castling, "Q") end
        if square == 8 then next_position.castling = drop_castling(next_position.castling, "K") end
        if square == 57 then next_position.castling = drop_castling(next_position.castling, "q") end
        if square == 64 then next_position.castling = drop_castling(next_position.castling, "k") end
    end
    next_position.turn = white and "b" or "w"
    return next_position
end

-- Out here rather than inside pseudo_moves, for the same reason as slides.
local function add_move(board, list, from, to)
    local piece = board[from]
    if (piece == "p" or piece == "P") and (to <= 8 or to > 56) then
        for _, promotion in ipairs(PROMOTIONS) do
            list[#list + 1] = { from = from, to = to, promotion = promotion }
        end
    else
        list[#list + 1] = { from = from, to = to }
    end
end

local function pseudo_moves(position, list)
    local board = position.board
    local white = position.turn == "w"
    for square = 1, 64 do
        local piece = board[square]
        if piece and is_white(piece) == white then
            local file, rank = file_of(square), rank_of(square)
            local kind = piece:lower()
            if kind == "p" then
                local forward = white and 1 or -1
                local one = rank + forward
                if on_board(file, one) and not board[index(file, one)] then
                    add_move(board, list, square, index(file, one))
                    local start = white and 2 or 7
                    if rank == start and not board[index(file, one + forward)] then
                        add_move(board, list, square, index(file, one + forward))
                    end
                end
                for df = -1, 1, 2 do
                    if on_board(file + df, one) then
                        local target = index(file + df, one)
                        local other = board[target]
                        if (other and is_white(other) ~= white) or target == position.passant then
                            add_move(board, list, square, target)
                        end
                    end
                end
            elseif kind == "n" or kind == "k" then
                for _, step in ipairs(kind == "n" and KNIGHT or KING) do
                    if on_board(file + step[1], rank + step[2]) then
                        local target = index(file + step[1], rank + step[2])
                        local other = board[target]
                        if not other or is_white(other) ~= white then
                            add_move(board, list, square, target)
                        end
                    end
                end
            else
                local steps = kind == "q" and QUEEN or (kind == "r" and ROOK or BISHOP)
                for _, step in ipairs(steps) do
                    local f, r = file + step[1], rank + step[2]
                    while on_board(f, r) do
                        local target = index(f, r)
                        local other = board[target]
                        if not other then
                            add_move(board, list, square, target)
                        else
                            if is_white(other) ~= white then
                                add_move(board, list, square, target)
                            end
                            break
                        end
                        f, r = f + step[1], r + step[2]
                    end
                end
            end
        end
    end
    -- Castling: the squares between are empty, and the king does not start, cross or land under attack.
    local rank = white and 1 or 8
    local king_square = index(5, rank)
    if board[king_square] == (white and "K" or "k") and not Chess.is_attacked(position, king_square, not white) then
        local rook = white and "R" or "r"
        if position.castling:find(white and "K" or "k", 1, true) and board[index(8, rank)] == rook
            and not board[index(6, rank)] and not board[index(7, rank)]
            and not Chess.is_attacked(position, index(6, rank), not white) then
            add_move(board, list, king_square, index(7, rank))
        end
        if position.castling:find(white and "Q" or "q", 1, true) and board[index(1, rank)] == rook
            and not board[index(2, rank)] and not board[index(3, rank)] and not board[index(4, rank)]
            and not Chess.is_attacked(position, index(4, rank), not white) then
            add_move(board, list, king_square, index(3, rank))
        end
    end
    return list
end

function Chess.legal_moves(position)
    local legal = {}
    local white = position.turn == "w"
    for _, move in ipairs(pseudo_moves(position, {})) do
        if not Chess.in_check(play(position, move), white) then
            legal[#legal + 1] = move
        end
    end
    return legal
end

-- Where the piece on a square can go, as { [target] = { moves } }, with several moves for a promotion.
function Chess.targets_from(position, from)
    local targets = {}
    for _, move in ipairs(Chess.legal_moves(position)) do
        if move.from == from then
            targets[move.to] = targets[move.to] or {}
            table.insert(targets[move.to], move)
        end
    end
    return targets
end

-- The moves of a game in the usual notation, with the number of the first move and whose move it was, read from
-- the starting position. A move that does not fit the position ends the list there.
-- Writing a move means listing the legal moves, slow on a Kindle, so cache, a table kept by the caller, holds what
-- was written: a game that only grew since then costs only its new moves.
function Chess.san_list(initial_fen, moves, cache)
    cache = cache or {}
    moves = tostring(moves or "")
    local fen = (initial_fen == nil or initial_fen == "startpos") and Chess.START_FEN or initial_fen
    local grew = cache.fen == fen and cache.position ~= nil
        and (cache.moves == "" or moves == cache.moves or moves:sub(1, #cache.moves + 1) == cache.moves .. " ")
    if not grew then
        local position = Chess.parse_fen(fen)
        if not position then
            return {}, 1, "w"
        end
        cache.fen, cache.moves, cache.list, cache.position, cache.stopped = fen, "", {}, position, false
        cache.first_number = tonumber(tostring(fen):match("%s(%d+)%s*$")) or 1
        cache.first_turn = position.turn
    end
    if not cache.stopped then
        for uci in moves:sub(#cache.moves + 1):gmatch("%S+") do
            local position = cache.position
            local move = Chess.parse_uci(position, uci)
            if not move or not position.board[move.from] then
                cache.stopped = true
                break
            end
            cache.list[#cache.list + 1] = Chess.to_san(position, move)
            cache.position = Chess.play(position, move)
        end
    end
    cache.moves = moves
    return cache.list, cache.first_number, cache.first_turn
end

-- The moves of a game from the start, without the last move color played and those after it, so it is color's
-- turn again. nil when color has not played yet.
function Chess.take_back(moves, color)
    local list = {}
    for uci in moves:gmatch("%S+") do
        list[#list + 1] = uci
    end
    local parity = color == "w" and 1 or 0
    for index = #list, 1, -1 do
        if index % 2 == parity then
            return table.concat(list, " ", 1, index - 1)
        end
    end
    return nil
end

function Chess.move_to_uci(move)
    return Chess.square_name(move.from) .. Chess.square_name(move.to) .. (move.promotion or "")
end

-- Reads a move in UCI. Lichess can also write castling as the king taking its own rook.
function Chess.parse_uci(position, uci)
    local from, to, promotion = tostring(uci):match("^([a-h][1-8])([a-h][1-8])([qrbn]?)$")
    if not from then
        return nil
    end
    from, to = Chess.square_from_name(from), Chess.square_from_name(to)
    local piece = position.board[from]
    if piece and piece:lower() == "k" and position.board[to] and is_white(position.board[to]) == is_white(piece) then
        to = index(file_of(to) > file_of(from) and 7 or 3, rank_of(from))
    end
    return { from = from, to = to, promotion = promotion ~= "" and promotion or nil }
end

function Chess.apply_uci(position, uci)
    local move = Chess.parse_uci(position, uci)
    if not move or not position.board[move.from] then
        return nil, "invalid move: " .. tostring(uci)
    end
    return play(position, move), move
end

-- The position after a list of moves separated by spaces, with the last move played.
function Chess.from_moves(initial_fen, moves)
    local position, err = Chess.parse_fen((initial_fen == nil or initial_fen == "startpos") and Chess.START_FEN or initial_fen)
    if not position then
        return nil, err
    end
    local last
    for uci in tostring(moves or ""):gmatch("%S+") do
        position, last = Chess.apply_uci(position, uci)
        if not position then
            return nil, last
        end
    end
    return position, last
end

-- Reads a move in the usual notation, such as Nf3, exd5, O-O or e8=Q+, against the legal moves of the position.
function Chess.parse_san(position, san)
    local text = tostring(san):gsub("[+#!?]", "")
    if text == "O-O" or text == "0-0" or text == "O-O-O" or text == "0-0-0" then
        local rank = position.turn == "w" and 1 or 8
        local file = #text > 3 and 3 or 7
        for _, move in ipairs(Chess.legal_moves(position)) do
            if move.from == index(5, rank) and move.to == index(file, rank) and position.board[move.from]:lower() == "k" then
                return move
            end
        end
        return nil
    end
    local promotion = text:match("=?([QRBNqrbn])$")
    if promotion and text:match("[1-8]=?[QRBNqrbn]$") then
        text = text:gsub("=?[QRBNqrbn]$", "")
        promotion = promotion:lower()
    else
        promotion = nil
    end
    local kind, from_file, from_rank, to = text:match("^([KQRBN]?)([a-h]?)([1-8]?)x?([a-h][1-8])$")
    if not to then
        return nil
    end
    local target = Chess.square_from_name(to)
    local wanted = kind == "" and "p" or kind:lower()
    for _, move in ipairs(Chess.legal_moves(position)) do
        if move.to == target and position.board[move.from]:lower() == wanted and move.promotion == promotion
            and (from_file == "" or file_of(move.from) == from_file:byte() - 96)
            and (from_rank == "" or rank_of(move.from) == tonumber(from_rank)) then
            return move
        end
    end
    return nil
end

function Chess.play(position, move)
    return play(position, move)
end

local function insufficient_material(position)
    local minors, others = 0, 0
    for _, piece in pairs(position.board) do
        local kind = piece:lower()
        if kind == "b" or kind == "n" then
            minors = minors + 1
        elseif kind ~= "k" then
            others = others + 1
        end
    end
    return others == 0 and minors <= 1
end

-- What the rules say about a position, for games with no server to tell: nil while it goes on,
-- otherwise "mate", "stalemate", "insufficient" or "fifty".
function Chess.ending(position)
    if #Chess.legal_moves(position) == 0 then
        return Chess.in_check(position) and "mate" or "stalemate"
    end
    if insufficient_material(position) then
        return "insufficient"
    end
    if (position.halfmove or 0) >= 100 then
        return "fifty"
    end
    return nil
end

-- How many times the current position has happened, which is what a draw by repetition asks about.
function Chess.repetitions(initial_fen, moves)
    local position = Chess.parse_fen((initial_fen == nil or initial_fen == "startpos") and Chess.START_FEN or initial_fen)
    if not position then
        return 0
    end
    local seen = { [Chess.position_key(position)] = 1 }
    local count = 1
    for uci in tostring(moves or ""):gmatch("%S+") do
        position = Chess.apply_uci(position, uci)
        if not position then
            return 0
        end
        local key = Chess.position_key(position)
        seen[key] = (seen[key] or 0) + 1
        count = seen[key]
    end
    return count
end

function Chess.to_fen(position)
    local rows = {}
    for rank = 8, 1, -1 do
        local row, empty = {}, 0
        for file = 1, 8 do
            local piece = position.board[index(file, rank)]
            if piece then
                if empty > 0 then
                    row[#row + 1] = tostring(empty)
                    empty = 0
                end
                row[#row + 1] = piece
            else
                empty = empty + 1
            end
        end
        if empty > 0 then
            row[#row + 1] = tostring(empty)
        end
        rows[#rows + 1] = table.concat(row)
    end
    return string.format("%s %s %s %s %d 1", table.concat(rows, "/"), position.turn,
        position.castling ~= "" and position.castling or "-",
        position.passant and Chess.square_name(position.passant) or "-", position.halfmove or 0)
end

-- A legal move in the usual notation, such as Nf3, exd5, O-O or e8=Q+.
function Chess.to_san(position, move)
    local piece = position.board[move.from]
    local kind = piece:lower()
    local text
    if kind == "k" and math.abs(file_of(move.to) - file_of(move.from)) == 2 then
        text = file_of(move.to) > file_of(move.from) and "O-O" or "O-O-O"
    else
        local to = Chess.square_name(move.to)
        local takes = position.board[move.to] ~= nil or (kind == "p" and move.to == position.passant)
        if kind == "p" then
            text = (takes and (Chess.square_name(move.from):sub(1, 1) .. "x") or "") .. to
            if move.promotion then
                text = text .. "=" .. move.promotion:upper()
            end
        else
            local same_file, same_rank, other = false, false, false
            for _, candidate in ipairs(Chess.legal_moves(position)) do
                if candidate.to == move.to and candidate.from ~= move.from and position.board[candidate.from] == piece then
                    other = true
                    same_file = same_file or file_of(candidate.from) == file_of(move.from)
                    same_rank = same_rank or rank_of(candidate.from) == rank_of(move.from)
                end
            end
            local origin = Chess.square_name(move.from)
            local hint = ""
            if other then
                if not same_file then
                    hint = origin:sub(1, 1)
                elseif not same_rank then
                    hint = origin:sub(2, 2)
                else
                    hint = origin
                end
            end
            text = kind:upper() .. hint .. (takes and "x" or "") .. to
        end
    end
    local after = Chess.play(position, move)
    if Chess.in_check(after) then
        text = text .. (Chess.ending(after) == "mate" and "#" or "+")
    end
    return text
end

-- The square passed over is part of the position only when taking on it is really possible.
local function takeable_passant(position)
    if position.passant then
        for _, move in ipairs(Chess.legal_moves(position)) do
            if move.to == position.passant and position.board[move.from]:lower() == "p" then
                return position.passant
            end
        end
    end
    return nil
end

-- The position as the first four fields of a FEN, with the square passed over only when taking on it is
-- possible, as Lichess writes the positions of its list of openings.
function Chess.epd(position)
    local passant = takeable_passant(position)
    return Chess.to_fen(position):match("^(%S+ %S+ %S+) ") .. " " .. (passant and Chess.square_name(passant) or "-")
end

-- A text that is the same for the same position, to count repetitions.
Chess.position_key = Chess.epd

-- For testing against known counts of positions.
function Chess.perft(position, depth)
    if depth == 0 then
        return 1
    end
    local moves = Chess.legal_moves(position)
    if depth == 1 then
        return #moves
    end
    local total = 0
    for _, move in ipairs(moves) do
        total = total + Chess.perft(play(position, move), depth - 1)
    end
    return total
end

return Chess
