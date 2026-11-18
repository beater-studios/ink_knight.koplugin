-- What each side has more than the other on the board, as Lichess shows it beside the players: the pieces a side has in excess once the equal ones cancel, and by how many points the side ahead leads (pawn 1, knight and bishop 3, rook 5, queen 9). Counted from the board, so a promotion counts as the piece it became. No KOReader here.
local Material = {}

local VALUES = { q = 9, r = 5, b = 3, n = 3, p = 1 }
-- The most valuable first, as they are shown.
local ORDER = { "q", "r", "b", "n", "p" }

-- nil with the same material on both sides. Otherwise { w = { pieces, lead }, b = { pieces, lead } }: pieces, the letters of what the side has more of ("np": a knight and a pawn), and lead, its points ahead, only for the side ahead.
function Material.difference(position)
    if not position or not position.board then
        return nil
    end
    local counts = {}
    for _, piece in pairs(position.board) do
        local kind = piece:lower()
        if VALUES[kind] then
            counts[kind] = (counts[kind] or 0) + (piece == kind and -1 or 1)
        end
    end
    local sides = { w = { pieces = "" }, b = { pieces = "" } }
    local points = 0
    for _, kind in ipairs(ORDER) do
        local more = counts[kind] or 0
        points = points + more * VALUES[kind]
        local side = more > 0 and sides.w or sides.b
        side.pieces = side.pieces .. kind:rep(math.abs(more))
    end
    if sides.w.pieces == "" and sides.b.pieces == "" then
        return nil
    end
    if points > 0 then
        sides.w.lead = points
    elseif points < 0 then
        sides.b.lead = -points
    end
    return sides
end

-- What a side ("w" or "b") shows of the difference, as a text, to tell when it changed: "n+2", or "" with nothing to show.
function Material.text(difference, side)
    local shown = difference and difference[side]
    if not shown or shown.pieces == "" then
        return ""
    end
    return shown.pieces .. "+" .. (shown.lead or 0)
end

return Material
