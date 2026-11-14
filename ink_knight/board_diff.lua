-- What changed on the board between two states, so only that part of an e-ink screen gets redrawn.
local BoardDiff = {}

local function bar_text(info)
    if not info then
        return ""
    end
    return table.concat({ tostring(info.name), tostring(info.clock), tostring(info.active), tostring(info.tag) }, "|")
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
        state.stars and state.stars[square] and "*" or "",
        state.check_square == square and "c" or "",
    })
end

-- Arrows cross many squares, and a highlighted rank borders eight: any change of them redraws the whole board.
local function overlay_text(state)
    local parts = { tostring(state.highlighted_rank) }
    for _, shape in ipairs(state.shapes or {}) do
        parts[#parts + 1] = table.concat({ tostring(shape.from), tostring(shape.to), tostring(shape.brush) }, ":")
    end
    return table.concat(parts, "|")
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
        top = bar_text(state.top) .. "|" .. tostring(state.banner),
        overlay = overlay_text(state),
        bottom = bar_text(state.bottom),
        status = tostring(state.status) .. "|" .. (state.progress and (tostring(state.progress.done) .. "/" .. tostring(state.progress.total)) or "")
            .. "|" .. (state.panel and table.concat({ tostring(state.panel.move), tostring(state.panel.tag), tostring(state.panel.detail), tostring(state.panel.evaluation) }, "|") or ""),
        buttons = buttons_text(state.buttons),
        -- A card over the board changes much of it at once.
        card = state.card and table.concat({ tostring(state.card.title), tostring(state.card.text), tostring(state.card.detail), buttons_text(state.card.buttons) }, "|") or "",
    }
end

-- Returns squares, the list that changed, plus top, bottom, status and buttons. whole means everything moved.
function BoardDiff.changes(old, new)
    if not old or old.flipped ~= new.flipped or old.has_position ~= new.has_position or old.card ~= new.card then
        return { whole = true, squares = {} }
    end
    local squares = {}
    -- Arrows or a highlighted rank that changed: every square counts as changed, which redraws the board.
    local overlay = old.overlay ~= new.overlay
    for square = 1, 64 do
        if overlay or old.squares[square] ~= new.squares[square] then
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
