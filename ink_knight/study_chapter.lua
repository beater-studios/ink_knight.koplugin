-- A chapter of a Lichess study, read from its PGN into what the practice screen shows: a commented game (the main
-- line, with the comment and drawings after each move) or, for an interactive chapter (ChapterMode "gamebook"), a
-- guided one (the moves to find, and the reader's wrong moves the author foresaw, with their comments). Only the main
-- line and the first move of each variation are read with the rules: the rest of the variations is skipped, since
-- reading every move of a long study would take seconds on a Kindle. No KOReader here, so the tests can use it.
local Broadcast = require("ink_knight/broadcast")
local Chess = require("ink_knight/chess")

local StudyChapter = {}

local BRUSHES = { G = true, R = true, Y = true, B = true }

-- The drawings of a comment as the practice writes them: "Gb2h8,Rf6".
local function shapes_of(comment)
    local list = {}
    for kind, body in comment:gmatch("%[%%(c[as]l) ([^%]]*)%]") do
        for item in body:gmatch("[^,%s]+") do
            local brush, from, to = item:match("^([GRYB])([a-h][1-8])([a-h]?[1-8]?)$")
            if brush and BRUSHES[brush] and (kind == "cal") == (to ~= "") then
                list[#list + 1] = brush .. from .. to
            end
        end
    end
    return list
end

-- The text of a comment as the reader sees it: no commands ([%clk], [%cal], [%anno]...), no addresses (nothing
-- opens them on the device), no spaces left at the ends.
function StudyChapter.clean(comment)
    -- An address in parentheses goes with them, and a bare one up to the next space.
    local text = comment:gsub("%[%%[^%]]*%]", ""):gsub("%s*%(https?://[^%s%)]*%)", ""):gsub("https?://%S+", "")
    text = text:gsub("[ \t]+\n", "\n"):gsub("[ \t]+([%.,;:])", "%1"):gsub("\n\n\n+", "\n\n")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text ~= "" and text or nil
end

local function is_move(token)
    return not (token:match("^%d+%.+$") or token:match("^%$%d+$") or token == "*" or token == "1-0" or token == "0-1" or token == "1/2-1/2")
end

-- id: what the texts of the chapter are keyed by. Returns the chapter ({ id, kind, fen, color, line, shapes, wrong })
-- and its texts ({ [id .. ".c" .. ply] = text, ... }), or nil with a reason.
function StudyChapter.read(text, id)
    local tags, body = Broadcast.tags(text)
    local fen = tags.FEN or Chess.START_FEN
    local start = Chess.parse_fen(fen)
    if not start then
        return nil, "fen"
    end
    local guided = tags.ChapterMode == "gamebook"
    local color = tags.Orientation == "black" and "b" or "w"
    local chapter = { id = id, kind = guided and "guided" or "lesson", fen = fen, color = color, line = {}, shapes = {}, wrong = {} }
    local texts = {}
    local comments, drawings = { [0] = {} }, { [0] = {} }
    local positions = { [0] = start }
    local ply = 0
    -- Inside a variation: depth, the ply of the main move it replaces and, once read, its first move.
    local depth, variation = 0, nil
    local pos = 1
    local function keep(list, value)
        list[#list + 1] = value
    end
    while pos <= #body do
        local c = body:sub(pos, pos)
        if c == "{" then
            local stop = body:find("}", pos, true) or #body + 1
            local comment = body:sub(pos + 1, stop - 1)
            if depth == 0 then
                keep(comments[ply], comment)
                for _, shape in ipairs(shapes_of(comment)) do
                    keep(drawings[ply], shape)
                end
            elseif depth == 1 and variation and variation.uci and variation.moves == 1 then
                -- Only what the author says right after the wrong move; later moves of the variation are another story.
                keep(variation.comments, comment)
                for _, shape in ipairs(shapes_of(comment)) do
                    keep(variation.shapes, shape)
                end
            end
            pos = stop + 1
        elseif c == "(" then
            depth = depth + 1
            if depth == 1 then
                variation = { ply = ply, comments = {}, shapes = {}, moves = 0 }
            end
            pos = pos + 1
        elseif c == ")" then
            if depth == 1 and variation and variation.uci and guided and positions[variation.ply - 1] and positions[variation.ply - 1].turn == color then
                -- An alternative to a move of the reader is a wrong move, with what the author says about it.
                local at = variation.ply
                chapter.wrong[at] = chapter.wrong[at] or {}
                if variation.uci ~= chapter.line[at] then
                    chapter.wrong[at][variation.uci] = table.concat(variation.shapes, ",")
                    texts[id .. ".w" .. at .. "." .. variation.uci] = StudyChapter.clean(table.concat(variation.comments, "\n"))
                end
            end
            depth = math.max(0, depth - 1)
            if depth == 0 then
                variation = nil
            end
            pos = pos + 1
        elseif c:match("%s") then
            pos = pos + 1
        else
            local token = body:match("^[^%s{}()]+", pos)
            -- A stray brace says nothing.
            pos = pos + (token and #token or 1)
            if token and is_move(token) then
                local san = (token:match("^%d+%.+(.+)$") or token):gsub("[!?]+$", "")
                if depth == 0 then
                    local move = positions[ply] and Chess.parse_san(positions[ply], san)
                    if not move then
                        break
                    end
                    ply = ply + 1
                    chapter.line[ply] = Chess.move_to_uci(move)
                    positions[ply] = Chess.play(positions[ply - 1], move)
                    comments[ply], drawings[ply] = {}, {}
                elseif depth == 1 and variation then
                    variation.moves = variation.moves + 1
                    if variation.moves == 1 and variation.ply >= 1 then
                        -- The first move of a variation replaces the main move of its ply, from the position before it.
                        local move = Chess.parse_san(positions[variation.ply - 1], san)
                        variation.uci = move and Chess.move_to_uci(move) or false
                    end
                end
            end
        end
    end
    for at = 0, ply do
        texts[id .. ".c" .. at] = StudyChapter.clean(table.concat(comments[at], "\n"))
        chapter.shapes[at] = #drawings[at] > 0 and table.concat(drawings[at], ",") or nil
    end
    texts[id .. ".n"] = tags.ChapterName or tags.Event
    if guided and ply == 0 then
        -- An interactive chapter with nothing to find is shown as it is.
        chapter.kind = "lesson"
    end
    -- What the screen shows before the first move: the comment that opens the chapter, as the practice keeps it.
    texts[id .. ".d"] = texts[id .. ".c0"]
    texts[id .. ".c0"] = nil
    return chapter, texts
end

return StudyChapter
