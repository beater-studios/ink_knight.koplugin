-- The moves of a game on a page of their own, two to a row, as on a score sheet, under the name of the opening
-- when the game has one. It opens on the sheet with the move to look at, the last one by default.
local Openings = require("ink_knight/openings")

local MoveList = {}

-- sans: the moves in the usual notation. first_number and first_turn: where the game started.
-- opts.current: the half move to mark, 1 for the first one, or 0 at the start, where the list opens on its first sheet.
-- Without it, nothing is marked and the list opens on the last move. opts.on_pick(index): what a tap on a move does.
-- opts.marks: { [half move] = text }, a heading before the row of that move, such as where the endgame begins.
function MoveList.rows(sans, first_number, first_turn, opts)
    opts = opts or {}
    local rows = {}
    local offset = first_turn == "b" and 1 or 0
    local count = math.ceil((#sans + offset) / 2)
    for row_index = 1, count do
        local white_index = (row_index - 1) * 2 + 1 - offset
        local black_index = white_index + 1
        local row = { kind = "moves", number = string.format("%d.", first_number + row_index - 1) }
        for side, index in pairs({ white = white_index, black = black_index }) do
            if index >= 1 and sans[index] then
                row[side] = sans[index]
                row[side .. "_current"] = opts.current == index
                if opts.on_pick then
                    row[side .. "_callback"] = function() opts.on_pick(index) end
                end
            elseif index < 1 then
                row[side] = "…"
            end
        end
        row.focus = row.white_current or row.black_current
        for _, index in ipairs({ white_index, black_index }) do
            local mark = opts.marks and opts.marks[index]
            if mark and sans[index] then
                rows[#rows + 1] = { kind = "section", text = mark }
            end
        end
        rows[#rows + 1] = row
    end
    if #rows > 0 and opts.current == 0 then
        rows[1].focus = true
    elseif #rows > 0 and not opts.current then
        rows[#rows].focus = true
    end
    return rows
end

-- The rows with the name of the opening first. opts.opening: the name, when Lichess already gave it; otherwise
-- opts.initial_fen and opts.moves, in UCI: the game, to look the name up. Without either there is no name.
function MoveList.page_rows(sans, first_number, first_turn, opts)
    opts = opts or {}
    local rows = MoveList.rows(sans, first_number, first_turn, opts)
    local opening = opts.opening or (opts.moves and Openings.name(opts.initial_fen, opts.moves))
    if opening then
        table.insert(rows, 1, { kind = "text", text = opening, center = true })
    end
    return rows
end

function MoveList.show(app, sans, first_number, first_turn, opts)
    local s = app.strings
    opts = opts or {}
    if #sans == 0 then
        app:info(s.no_moves_yet)
        return
    end
    app:open_page{
        title = s.move_list_title,
        rows = MoveList.page_rows(sans, first_number, first_turn, opts),
        close_on_tap = opts.on_pick ~= nil,
    }
end

return MoveList
