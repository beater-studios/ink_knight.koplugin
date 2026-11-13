-- Works out king and pawn against king: whether each position is a win for the side with the pawn or a draw, by
-- going back from the positions whose result is known until nothing changes (the method of the bitbase of Stockfish,
-- GPL-3.0, written again here). The pawn is white and on files a to d; ink_knight/kpk.lua turns any other position
-- into one of these. Writes ink_knight/data/kpk.lua, one bit for each position, 1 for a win, in base64.
-- Usage, from the plugin folder: luajit tools/practice/kpk.lua
local OUT = "ink_knight/data/kpk.lua"

-- Squares 0 to 63, a1 = 0, h8 = 63. The index: white king, black king, side to move (0 white), and the pawn by its
-- file (a to d) and rank (2 to 7).
local SIZE = 64 * 64 * 2 * 24

local function file_of(sq) return sq % 8 end
local function rank_of(sq) return math.floor(sq / 8) end

local function index(wk, bk, side, pawn)
    return wk + 64 * bk + 4096 * side + 8192 * (file_of(pawn) * 6 + rank_of(pawn) - 1)
end

local function distance(a, b)
    return math.max(math.abs(file_of(a) - file_of(b)), math.abs(rank_of(a) - rank_of(b)))
end

local KING = {}
for sq = 0, 63 do
    KING[sq] = {}
    for _, d in ipairs({ { -1, -1 }, { -1, 0 }, { -1, 1 }, { 0, -1 }, { 0, 1 }, { 1, -1 }, { 1, 0 }, { 1, 1 } }) do
        local f, r = file_of(sq) + d[1], rank_of(sq) + d[2]
        if f >= 0 and f < 8 and r >= 0 and r < 8 then
            KING[sq][#KING[sq] + 1] = r * 8 + f
        end
    end
end

-- Whether the pawn attacks sq.
local function pawn_attacks(pawn, sq)
    return rank_of(sq) == rank_of(pawn) + 1 and math.abs(file_of(sq) - file_of(pawn)) == 1
end

local INVALID, UNKNOWN, DRAW, WIN = 0, 1, 2, 4
local result = {}

-- The first look at each position, as in Stockfish's KPKPosition: what is already known without going further.
local positions = {}
for idx = 0, SIZE - 1 do
    local wk, bk = idx % 64, math.floor(idx / 64) % 64
    local side = math.floor(idx / 4096) % 2
    local code = math.floor(idx / 8192)
    local pawn = (math.floor(code / 6)) + 8 * (code % 6 + 1)
    local r
    if distance(wk, bk) <= 1 or wk == pawn or bk == pawn or (side == 0 and pawn_attacks(pawn, bk)) then
        r = INVALID
    elseif side == 0 and rank_of(pawn) == 6 and wk ~= pawn + 8 and bk ~= pawn + 8
        and (distance(bk, pawn + 8) > 1 or distance(wk, pawn + 8) == 1) then
        -- The pawn promotes and the new queen cannot be taken.
        r = WIN
    elseif side == 1 then
        local moves = 0
        local takes = false
        for _, to in ipairs(KING[bk]) do
            if distance(to, wk) > 1 and not pawn_attacks(pawn, to) then
                moves = moves + 1
                if to == pawn then
                    takes = true
                end
            end
        end
        if moves == 0 or takes then
            -- Stalemate, or the pawn is taken.
            r = DRAW
        else
            r = UNKNOWN
        end
    else
        r = UNKNOWN
    end
    result[idx] = r
    positions[idx] = { wk, bk, side, pawn }
end

local band, bor = bit.band, bit.bor

local function classify(idx)
    local wk, bk, side, pawn = positions[idx][1], positions[idx][2], positions[idx][3], positions[idx][4]
    local good, bad = side == 0 and WIN or DRAW, side == 0 and DRAW or WIN
    local found = INVALID
    if side == 0 then
        for _, to in ipairs(KING[wk]) do
            if to ~= pawn then
                found = bor(found, result[index(to, bk, 1, pawn)])
            end
        end
        if rank_of(pawn) < 6 then
            local push = pawn + 8
            if push ~= wk and push ~= bk then
                found = bor(found, result[index(wk, bk, 1, push)])
                if rank_of(pawn) == 1 and push + 8 ~= wk and push + 8 ~= bk then
                    found = bor(found, result[index(wk, bk, 1, push + 8)])
                end
            end
        end
    else
        for _, to in ipairs(KING[bk]) do
            if to ~= pawn then
                found = bor(found, result[index(wk, to, 0, pawn)])
            end
        end
    end
    if band(found, good) ~= 0 then
        return good
    elseif band(found, UNKNOWN) ~= 0 then
        return UNKNOWN
    end
    return bad
end

local passes = 0
repeat
    local changed = false
    passes = passes + 1
    for idx = 0, SIZE - 1 do
        if result[idx] == UNKNOWN then
            local r = classify(idx)
            if r ~= UNKNOWN then
                result[idx] = r
                changed = true
            end
        end
    end
until not changed

local bytes, wins = {}, 0
for byte = 0, SIZE / 8 - 1 do
    local value = 0
    for b = 0, 7 do
        if result[byte * 8 + b] == WIN then
            value = value + 2 ^ b
            wins = wins + 1
        end
    end
    bytes[#bytes + 1] = string.char(value)
end
local raw = table.concat(bytes)

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local encoded = {}
for i = 1, #raw, 3 do
    local a, b, c = raw:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local chars = {}
    for k = 3, 0, -1 do
        local v = math.floor(n / 64 ^ k) % 64
        chars[#chars + 1] = ALPHABET:sub(v + 1, v + 1)
    end
    encoded[#encoded + 1] = table.concat(chars)
end
local text = table.concat(encoded)

local lines = {}
for i = 1, #text, 100 do
    lines[#lines + 1] = text:sub(i, i + 99)
end
local file = assert(io.open(OUT, "wb"))
file:write("-- Generated by tools/practice/kpk.lua: king and pawn against king, one bit for each position, 1 for a win of\n")
file:write("-- the side with the pawn, in base64. Read by ink_knight/kpk.lua. Do not edit by hand.\n")
file:write("return [[\n", table.concat(lines, "\n"), "\n]]\n")
file:close()
print(string.format("%s: %d positions, %d wins, %d passes", OUT, SIZE, wins, passes))
