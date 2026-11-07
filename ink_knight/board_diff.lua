-- What changed on the board between two states, so only that part of an e-ink screen gets redrawn.
local BoardDiff = {}

local function bar_text(info)
    if not info then
        return ""
    end
    return table.concat({ tostring(info.name), tostring(info.clock), tostring(info.active) }, "|")
end

local function buttons_text(buttons)
    local parts = {}
    for index, button in ipairs(buttons or {}) do
        parts[index] = tostring(button.id) .. "=" .. tostring(button.label)
    end
    return table.concat(parts, "|")
end

-- A square is what is on it and every mark over it.
local function square_text(state, square)
    local board = state.position and state.position.board
    local last = state.last_move
    return table.concat({
        board and board[square] or ".",
        state.selected == square and "s" or "",
        state.targets and state.targets[square] and "t" or "",
        last and (last.from == square or last.to == square) and "l" or "",
    })
end

function BoardDiff.snapshot(state)
    local squares = {}
    for square = 1, 64 do
        squares[square] = square_text(state, square)
    end
    return {
        squares = squares,
        flipped = state.flipped == true,
        has_position = state.position ~= nil,
        top = bar_text(state.top),
        bottom = bar_text(state.bottom),
        status = tostring(state.status),
        buttons = buttons_text(state.buttons),
    }
end

-- Returns squares, the list that changed, plus top, bottom, status and buttons. whole means everything moved.
function BoardDiff.changes(old, new)
    if not old or old.flipped ~= new.flipped or old.has_position ~= new.has_position then
        return { whole = true, squares = {} }
    end
    local squares = {}
    for square = 1, 64 do
        if old.squares[square] ~= new.squares[square] then
            squares[#squares + 1] = square
        end
    end
    return {
        squares = squares,
        top = old.top ~= new.top,
        bottom = old.bottom ~= new.bottom,
        status = old.status ~= new.status,
        buttons = old.buttons ~= new.buttons,
    }
end

return BoardDiff
