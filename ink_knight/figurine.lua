-- Moves written with the pieces as symbols (figurine notation, one of the two of Lichess), the same in every language:
-- "Nxe5" becomes a knight and "xe5", "e8=Q" a pawn move promoting to a queen. The symbols come from the font of the
-- pieces, drawn larger than the text around them so they read at its size. No KOReader here, so the tests can use it.
local Figurine = {}

-- The solid pieces read better on e-ink than the hollow ones, and stand for either color, as on Lichess.
local SYMBOLS = { K = "\226\153\154", Q = "\226\153\155", R = "\226\153\156", B = "\226\153\157", N = "\226\153\158" }
Figurine.FONT = "freefont/FreeSerif.ttf"
-- How much larger than the text a symbol is drawn, so its piece is as tall as the letters.
Figurine.SCALE = 1.3

-- A word that is a move in the usual notation, with what may follow it (check, mate, the signs of a judgment and the
-- punctuation of a sentence): where its piece letter is, or nil.
local MOVE_SHAPES = { "^[KQRBN]x?[a-h][1-8]$", "^[KQRBN][a-h1-8]x?[a-h][1-8]$", "^[KQRBN][a-h][1-8]x?[a-h][1-8]$" }
local function piece_letters(word)
    local core = word:gsub("[%+#!%?,%.;:%)]+$", "")
    for _, shape in ipairs(MOVE_SHAPES) do
        if core:match(shape) then
            return 1
        end
    end
    -- A pawn promoting: e8=Q, exd8=N.
    if core:match("^[a-h]x?[a-h]?[1-8]=[QRBN]$") then
        return #core
    end
    return nil
end

-- The parts of a text, in order: { text, symbol = true } for a piece, { text } for the rest. Only words shaped as
-- moves get symbols, so the words around them keep their capitals.
function Figurine.parts(text)
    local parts = {}
    local plain = {}
    local function flush()
        if #plain > 0 then
            parts[#parts + 1] = { text = table.concat(plain) }
            plain = {}
        end
    end
    local position = 1
    while position <= #text do
        local word_start, word_end = text:find("[^%s]+", position)
        if not word_start then
            plain[#plain + 1] = text:sub(position)
            break
        end
        plain[#plain + 1] = text:sub(position, word_start - 1)
        local word = text:sub(word_start, word_end)
        -- "5...Bxd1": the move after the dots of its number.
        local number, move = word:match("^(%d+%.+)(.+)$")
        if not number then
            number, move = "", word
        end
        local at = piece_letters(move)
        if at then
            plain[#plain + 1] = number
            plain[#plain + 1] = move:sub(1, at - 1)
            flush()
            parts[#parts + 1] = { text = SYMBOLS[move:sub(at, at)], symbol = true }
            plain[#plain + 1] = move:sub(at + 1)
        else
            plain[#plain + 1] = word
        end
        position = word_end + 1
    end
    flush()
    return parts
end

-- Draws text with its pieces as symbols. measure(text, font, size) gives the width a text takes, paint(text, font,
-- size, x, w, align) draws it in the row; both from the screen that draws, which knows its fonts and scale. A text
-- without moves, or one too long for w, is drawn whole, as before, so it is still cut where it ends.
function Figurine.paint(text, font, size, x, w, align, measure, paint)
    local parts = Figurine.parts(text)
    local has_symbol = false
    for _, part in ipairs(parts) do
        has_symbol = has_symbol or part.symbol == true
    end
    if not has_symbol then
        paint(text, font, size, x, w, align)
        return
    end
    local widths, total = {}, 0
    for index, part in ipairs(parts) do
        local part_font, part_size = font, size
        if part.symbol then
            part_font, part_size = Figurine.FONT, size * Figurine.SCALE
        end
        widths[index] = measure(part.text, part_font, part_size)
        total = total + widths[index]
    end
    if total > w then
        paint(text, font, size, x, w, align)
        return
    end
    local cursor = x
    if align == "center" then
        cursor = x + math.floor((w - total) / 2)
    elseif align == "right" then
        cursor = x + w - total
    end
    for index, part in ipairs(parts) do
        if part.symbol then
            paint(part.text, Figurine.FONT, size * Figurine.SCALE, cursor, widths[index] + 1, "left")
        else
            paint(part.text, font, size, cursor, widths[index] + 1, "left")
        end
        cursor = cursor + widths[index]
    end
end

return Figurine
