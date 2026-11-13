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

-- The castling of a position is "KQkq" in standard chess. In Chess960 each right is the file of its rook, upper
-- case for white ("HFhf", as Shredder writes it), and the position has chess960 set, which every move keeps.
-- chess960: read the FEN as Chess960, where "KQkq" (X-FEN, as Lichess writes it) means the outermost rook on each side
-- of the king, and a right with no king or rook to stand for is dropped. Without it only a FEN with files is
-- Chess960, so a standard FEN written loosely keeps the rights it had.
local function chess960_castling(board, castling, chess960)
    local letters = {}
    for letter in castling:gmatch(".") do
        local white = letter == letter:upper()
        local rank = white and 1 or 8
        local upper = letter:upper()
        if (upper == "K" or upper == "Q") and not chess960 then
            letters[#letters + 1] = letter
        elseif upper == "K" or upper == "Q" then
            local king_file
            for file = 1, 8 do
                if board[(rank - 1) * 8 + file] == (white and "K" or "k") then
                    king_file = file
                end
            end
            local rook = white and "R" or "r"
            local step = upper == "K" and -1 or 1
            for file = upper == "K" and 8 or 1, king_file or (upper == "K" and 9 or 0), step do
                if board[(rank - 1) * 8 + file] == rook then
                    local name = string.char(64 + file)
                    letters[#letters + 1] = white and name or name:lower()
                    break
                end
            end
        elseif upper:match("[A-H]") then
            letters[#letters + 1] = letter
        end
    end
    local result = table.concat(letters)
    return result, chess960 or result:find("[A-Ha-h]") ~= nil
end

function Chess.parse_fen(fen, chess960)
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
    local rights, is_960 = chess960_castling(board, castling == "-" and "" or castling, chess960)
    return {
        board = board,
        turn = turn,
        castling = rights,
        chess960 = is_960 or nil,
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
    return { board = board, turn = position.turn, castling = position.castling, chess960 = position.chess960, passant = position.passant, halfmove = position.halfmove }
end

-- A copy to change, optionally with the turn handed to another side, which drops the square passed over: it is
-- only good for the reply of the side that did not just move.
function Chess.copy_position(position, turn)
    local result = copy(position)
    if turn and turn ~= position.turn then
        result.turn, result.passant = turn, nil
    end
    return result
end

function Chess.king_square(position, color)
    return find_king(position, color == "w")
end

local function drop_castling(castling, letters)
    return (castling:gsub("[" .. letters .. "]", ""))
end

-- The square of the rook a castling right is for.
local function rook_square_of(letter)
    local white = letter == letter:upper()
    local rank = white and 1 or 8
    local upper = letter:upper()
    local file = upper == "K" and 8 or (upper == "Q" and 1 or upper:byte() - 64)
    return index(file, rank)
end

-- Plays a move on a copy, without checking that it is legal.
local function play(position, move)
    local next_position = copy(position)
    local board = next_position.board
    local piece = board[move.from]
    local white = is_white(piece)
    local kind = piece:lower()
    next_position.halfmove = (kind == "p" or board[move.to]) and 0 or (position.halfmove or 0) + 1
    if move.castle then
        -- The king and the rook leave, then land on their squares, which may be where the other one stood.
        local rank = rank_of(move.from)
        local rook = board[move.castle]
        board[move.from], board[move.castle] = nil, nil
        board[move.to] = piece
        board[index(file_of(move.to) == 7 and 6 or 4, rank)] = rook
        next_position.halfmove = (position.halfmove or 0) + 1
    else
        board[move.from] = nil
        if kind == "p" and move.to == position.passant then
            board[index(file_of(move.to), rank_of(move.from))] = nil
        end
        board[move.to] = move.promotion and (white and move.promotion:upper() or move.promotion) or piece
    end
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
        -- A castling of standard chess written as the king going two squares, as UCI and old saves have it.
        if not move.castle and not position.chess960 and math.abs(distance) == 2 then
            if distance == 2 then
                board[index(6, rank)], board[index(8, rank)] = board[index(8, rank)], nil
            else
                board[index(4, rank)], board[index(1, rank)] = board[index(1, rank)], nil
            end
        end
        next_position.castling = drop_castling(next_position.castling, white and "KQA-H" or "kqa-h")
    end
    -- A rook that moves or is taken ends the castling with it.
    for letter in next_position.castling:gmatch(".") do
        local square = rook_square_of(letter)
        if square == move.from or square == move.to then
            next_position.castling = drop_castling(next_position.castling, letter)
        end
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
    -- Castling, from wherever king and rook stand, as Chess960 has it: the king lands on g or c and the rook on f or
    -- d, every square they cross or land on is empty but for the two of them, and the king does not start, cross or
    -- land under attack (landing is checked with the other moves). Standard chess is the case of e, a and h.
    local rank = white and 1 or 8
    local king, rook = white and "K" or "k", white and "R" or "r"
    local king_square
    for file = 1, 8 do
        if board[index(file, rank)] == king then
            king_square = index(file, rank)
        end
    end
    if king_square and position.castling ~= "" and not Chess.is_attacked(position, king_square, not white) then
        for letter in position.castling:gmatch(".") do
            if (letter == letter:upper()) == white then
                local rook_square = rook_square_of(letter)
                if board[rook_square] == rook then
                    local king_side = file_of(rook_square) > file_of(king_square)
                    local king_to, rook_to = index(king_side and 7 or 3, rank), index(king_side and 6 or 4, rank)
                    local low = math.min(file_of(king_square), file_of(rook_square), file_of(king_to), file_of(rook_to))
                    local high = math.max(file_of(king_square), file_of(rook_square), file_of(king_to), file_of(rook_to))
                    local free = true
                    for file = low, high do
                        local square = index(file, rank)
                        if board[square] and square ~= king_square and square ~= rook_square then
                            free = false
                        end
                    end
                    local step = file_of(king_to) >= file_of(king_square) and 1 or -1
                    for file = file_of(king_square) + step, file_of(king_to) - step, step do
                        if free and Chess.is_attacked(position, index(file, rank), not white) then
                            free = false
                        end
                    end
                    if free then
                        list[#list + 1] = { from = king_square, to = king_to, castle = rook_square, chess960 = position.chess960 }
                    end
                end
            end
        end
    end
    return list
end

-- The moves of the side to move, also the ones that leave its own king attacked: for the lessons that let the
-- reader blunder, and to find what attacks a king.
function Chess.pseudo_legal_moves(position)
    return pseudo_moves(position, {})
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

-- Whether two moves are the same one. In Chess960 a castling and a plain king move may share both squares.
function Chess.same_move(a, b)
    return a.from == b.from and a.to == b.to and a.promotion == b.promotion and (a.castle ~= nil) == (b.castle ~= nil)
end

-- The square tapped to play a move: in Chess960 a castling is tapped on its rook, as on Lichess, since the king may
-- also go to g or c by a plain move.
function Chess.target_square(position, move)
    return (move.castle and position.chess960) and move.castle or move.to
end

-- Where the piece on a square can go, as { [target] = { moves } }, with several moves for a promotion.
-- moves: the moves to look among, the legal ones by default.
function Chess.targets_from(position, from, moves)
    local targets = {}
    for _, move in ipairs(moves or Chess.legal_moves(position)) do
        if move.from == from then
            local target = Chess.target_square(position, move)
            targets[target] = targets[target] or {}
            table.insert(targets[target], move)
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
-- first_turn: who played the first move, "w" unless the game started from a position with black to move.
function Chess.take_back(moves, color, first_turn)
    local list = {}
    for uci in moves:gmatch("%S+") do
        list[#list + 1] = uci
    end
    local parity = (color == (first_turn or "w")) and 1 or 0
    for index = #list, 1, -1 do
        if index % 2 == parity then
            return table.concat(list, " ", 1, index - 1)
        end
    end
    return nil
end

-- A castling of Chess960 goes as the king taking its own rook, the only way Lichess reads it there.
function Chess.move_to_uci(move)
    local to = (move.castle and move.chess960) and move.castle or move.to
    return Chess.square_name(move.from) .. Chess.square_name(to) .. (move.promotion or "")
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
        return { from = from, to = index(file_of(to) > file_of(from) and 7 or 3, rank_of(from)), castle = to, chess960 = position.chess960 }
    end
    -- A castling of standard chess as the king going two squares, the way UCI writes it.
    if piece and piece:lower() == "k" and not position.chess960 and math.abs(file_of(to) - file_of(from)) == 2 and rank_of(to) == rank_of(from) then
        return { from = from, to = to, castle = index(file_of(to) > file_of(from) and 8 or 1, rank_of(from)) }
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

-- The position a game starts at: the usual one for nil or "startpos", as Lichess writes it, or the FEN given.
function Chess.start_position(initial_fen)
    return Chess.parse_fen((initial_fen == nil or initial_fen == "startpos") and Chess.START_FEN or initial_fen)
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
        local file = #text > 3 and 3 or 7
        for _, move in ipairs(Chess.legal_moves(position)) do
            if move.castle and file_of(move.to) == file then
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

-- The pieces other than the king of each side: minors (bishops and knights) and others.
local function material(position)
    local count = { w = { minors = 0, others = 0 }, b = { minors = 0, others = 0 } }
    for _, piece in pairs(position.board) do
        local kind = piece:lower()
        if kind ~= "k" then
            local side = count[is_white(piece) and "w" or "b"]
            if kind == "b" or kind == "n" then
                side.minors = side.minors + 1
            else
                side.others = side.others + 1
            end
        end
    end
    return count
end

local function insufficient_material(position)
    local count = material(position)
    return count.w.others + count.b.others == 0 and count.w.minors + count.b.minors <= 1
end

-- Whether color has pieces enough to give mate at all, for a flag: running out of time against a side that
-- cannot mate is a draw. A lone king cannot, and neither can a king with one bishop or knight against a lone king.
function Chess.can_mate(position, color)
    local count = material(position)
    local mine, theirs = count[color], count[color == "w" and "b" or "w"]
    if mine.others > 0 or mine.minors >= 2 then
        return true
    end
    return mine.minors == 1 and theirs.minors + theirs.others > 0
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
    if move.castle or (kind == "k" and not position.chess960 and math.abs(file_of(move.to) - file_of(move.from)) == 2) then
        text = file_of(move.to) == 7 and "O-O" or "O-O-O"
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

-- The starting positions of Chess960, by their number from 0 to 959 as Lichess and the usual numbering give it (518 is
-- the one of standard chess): the light bishop, the dark bishop, the queen, the knights, then rook, king and rook.
local KNIGHTS = { { 1, 2 }, { 1, 3 }, { 1, 4 }, { 1, 5 }, { 2, 3 }, { 2, 4 }, { 2, 5 }, { 3, 4 }, { 3, 5 }, { 4, 5 } }

local function chess960_rank(number)
    local rank = {}
    local n = number
    rank[2 * (n % 4) + 2] = "B"
    n = math.floor(n / 4)
    rank[2 * (n % 4) + 1] = "B"
    n = math.floor(n / 4)
    local function empty(count)
        local seen = 0
        for file = 1, 8 do
            if not rank[file] then
                seen = seen + 1
                if seen == count then
                    return file
                end
            end
        end
    end
    rank[empty(n % 6 + 1)] = "Q"
    n = math.floor(n / 6)
    local knights = KNIGHTS[n + 1]
    local first, second = empty(knights[1]), empty(knights[2])
    rank[first], rank[second] = "N", "N"
    for _, piece in ipairs({ "R", "K", "R" }) do
        rank[empty(1)] = piece
    end
    return table.concat(rank)
end

-- The FEN of a starting position of Chess960, with castling as the files of the rooks, so it reads as Chess960.
function Chess.chess960_fen(number)
    local rank = chess960_rank(number)
    local rooks = {}
    for file = 8, 1, -1 do
        if rank:sub(file, file) == "R" then
            rooks[#rooks + 1] = string.char(64 + file)
        end
    end
    local castling = table.concat(rooks)
    return string.format("%s/pppppppp/8/8/8/8/PPPPPPPP/%s w %s%s - 0 1", rank:lower(), rank, castling, castling:lower())
end

-- The number of the starting position of Chess960 a FEN is, or nil.
function Chess.chess960_number(fen)
    local first, last = tostring(fen or ""):match("^(%a+)/pppppppp/8/8/8/8/PPPPPPPP/(%a+) w ")
    if not first or first ~= last:lower() then
        return nil
    end
    for number = 0, 959 do
        if chess960_rank(number) == last then
            return number
        end
    end
    return nil
end

-- A FEN of a Chess960 game as Lichess writes it (X-FEN, "KQkq") with castling as the files of the rooks, so it reads as
-- Chess960 wherever it goes, even in the positions whose king and rooks stand as in standard chess. The rest stays.
function Chess.as_chess960(fen)
    local position = Chess.parse_fen(fen, true)
    if not position then
        return fen
    end
    local placement, turn, _, rest = tostring(fen):match("^(%S+)%s+(%S+)%s+(%S+)%s*(.*)$")
    local castling = position.castling ~= "" and position.castling or "-"
    return string.format("%s %s %s%s", placement, turn, castling, rest ~= "" and (" " .. rest) or "")
end

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
