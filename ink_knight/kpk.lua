-- King and pawn against king, exactly: whether a position is a win for the side with the pawn, from the table
-- tools/practice/kpk.lua works out (ink_knight/data/kpk.lua). Any position of the three pieces is turned into one
-- with a white pawn on files a to d. No KOReader here, so the tests can use it.
local Kpk = {}

local table_bytes

local function bytes()
    if not table_bytes then
        local text = require("ink_knight/data/kpk"):gsub("%s", "")
        local values = {}
        local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        for i = 1, #alphabet do
            values[alphabet:byte(i)] = i - 1
        end
        local out = {}
        for i = 1, #text, 4 do
            local a, b, c, d = text:byte(i, i + 3)
            local n = values[a] * 262144 + values[b] * 4096 + values[c] * 64 + values[d]
            out[#out + 1] = string.char(math.floor(n / 65536), math.floor(n / 256) % 256, n % 256)
        end
        table_bytes = table.concat(out)
    end
    return table_bytes
end

-- The pieces of a position of king and pawn against king, as squares 0 to 63 (a1 = 0), or nil for any other.
local function pieces(position)
    local found = {}
    local count = 0
    for square = 1, 64 do
        local piece = position.board[square]
        if piece then
            count = count + 1
            if count > 3 or found[piece] then
                return nil
            end
            found[piece] = square - 1
        end
    end
    if count ~= 3 or not found.K or not found.k or not (found.P or found.p) then
        return nil
    end
    return found
end

-- "win" when the side with the pawn wins, "draw" otherwise, or nil when the position is not king and pawn against
-- king.
function Kpk.result(position)
    local found = pieces(position)
    if not found then
        return nil
    end
    local strong_white = found.P ~= nil
    local wk, bk, pawn = found.K, found.k, found.P
    local side = position.turn == "w" and 0 or 1
    if not strong_white then
        -- Turned over, so the pawn is white and goes up the board.
        wk, bk, pawn = found.k, found.K, found.p
        wk, bk, pawn = bit.bxor(wk, 56), bit.bxor(bk, 56), bit.bxor(pawn, 56)
        side = 1 - side
    end
    if pawn % 8 > 3 then
        wk, bk, pawn = bit.bxor(wk, 7), bit.bxor(bk, 7), bit.bxor(pawn, 7)
    end
    local index = wk + 64 * bk + 4096 * side + 8192 * ((pawn % 8) * 6 + math.floor(pawn / 8) - 1)
    local byte = bytes():byte(math.floor(index / 8) + 1)
    return bit.band(byte, bit.lshift(1, index % 8)) ~= 0 and "win" or "draw"
end

return Kpk
