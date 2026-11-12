-- Builds ink_knight/data/practice.lua and ink_knight/data/practice_texts_en.lua from the practice lessons of the
-- official Lichess app (lichess-org/mobile, GPL-3.0), which the app generates from lichess.org/practice. Only the
-- chapters the plugin can judge come in: the ones to mate, to mate in so many moves or to promote, played against
-- the engine, and the guided ones and the commented game, which need no engine. The moves of the guided chapters are
-- read with the rules of the plugin itself, so a move it cannot read stops the build.
-- Usage, from the plugin folder: luajit tools/practice/build.lua <folder with practice.json>
package.path = "./?.lua;" .. package.path
local Chess = require("ink_knight/chess")

local sources = assert(arg[1], "usage: luajit tools/practice/build.lua <folder with practice.json>")
local OUT = "ink_knight/data/practice.lua"
local OUT_TEXTS = "ink_knight/data/practice_texts_en.lua"

local function fail(text)
    io.stderr:write(text, "\n")
    os.exit(1)
end

-- A small JSON reader, enough for a file whose checksum is known.
local function decode_json(text)
    local pos = 1
    local value
    local function skip()
        pos = text:find("[^ \t\r\n]", pos) or #text + 1
    end
    local function read_string()
        local parts = {}
        pos = pos + 1
        while true do
            local c = text:sub(pos, pos)
            if c == "" then
                fail("json: unfinished string")
            elseif c == '"' then
                pos = pos + 1
                return table.concat(parts)
            elseif c == "\\" then
                local e = text:sub(pos + 1, pos + 1)
                local simple = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if simple[e] then
                    parts[#parts + 1] = simple[e]
                    pos = pos + 2
                elseif e == "u" then
                    local code = tonumber(text:sub(pos + 2, pos + 5), 16)
                    pos = pos + 6
                    if code >= 0xD800 and code <= 0xDBFF and text:sub(pos, pos + 1) == "\\u" then
                        local low = tonumber(text:sub(pos + 2, pos + 5), 16)
                        code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                        pos = pos + 6
                    end
                    if code < 0x80 then
                        parts[#parts + 1] = string.char(code)
                    elseif code < 0x800 then
                        parts[#parts + 1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
                    elseif code < 0x10000 then
                        parts[#parts + 1] = string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
                    else
                        parts[#parts + 1] = string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
                            0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
                    end
                else
                    fail("json: unknown escape \\" .. e)
                end
            else
                local stop = text:find('["\\]', pos) or #text + 1
                parts[#parts + 1] = text:sub(pos, stop - 1)
                pos = stop
            end
        end
    end
    function value()
        skip()
        local c = text:sub(pos, pos)
        if c == "{" then
            local object = {}
            pos = pos + 1
            skip()
            if text:sub(pos, pos) == "}" then
                pos = pos + 1
                return object
            end
            while true do
                skip()
                local key = read_string()
                skip()
                if text:sub(pos, pos) ~= ":" then
                    fail("json: expected :")
                end
                pos = pos + 1
                object[key] = value()
                skip()
                local sep = text:sub(pos, pos)
                pos = pos + 1
                if sep == "}" then
                    return object
                elseif sep ~= "," then
                    fail("json: expected , or }")
                end
            end
        elseif c == "[" then
            local list = {}
            pos = pos + 1
            skip()
            if text:sub(pos, pos) == "]" then
                pos = pos + 1
                return list
            end
            -- Counted by hand, so a null keeps its place and what follows keeps its index.
            local count = 0
            while true do
                count = count + 1
                list[count] = value()
                skip()
                local sep = text:sub(pos, pos)
                pos = pos + 1
                if sep == "]" then
                    return list
                elseif sep ~= "," then
                    fail("json: expected , or ]")
                end
            end
        elseif c == '"' then
            return read_string()
        elseif text:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif text:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif text:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        end
        local number = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
        if not number or number == "" then
            fail("json: unexpected " .. text:sub(pos, pos + 20))
        end
        pos = pos + #number
        return tonumber(number)
    end
    local result = value()
    skip()
    if pos <= #text then
        fail("json: text after the value")
    end
    return result
end

-- The texts of the app for the sections and studies, by id, as the app names them (practice_structure.dart).
local SECTIONS = {
    ["checkmates"] = "practiceSecHeadCheckmates",
    ["fundamental-tactics"] = "practiceSecHeadFundamentalTactics",
    ["advanced-tactics"] = "practiceSecHeadAdvancedTactics",
    ["pawn-endgames"] = "practiceSecHeadPawnEndgames",
    ["rook-endgames"] = "practiceSecHeadRookEndgames",
}
local STUDIES = {
    BJy6fEDf = { "practiceStNamPieceCheckmatesI", "practiceStDesBasicCheckmates" },
    fE4k21MW = { "practiceStNamCheckmatePatternsI", "practiceStDesRecognizeThePatterns" },
    ["8yadFPpU"] = { "practiceStNamCheckmatePatternsII", "practiceStDesRecognizeThePatterns" },
    PDkQDt6u = { "practiceStNamCheckmatePatternsIII", "practiceStDesRecognizeThePatterns" },
    ["96Lij7wH"] = { "practiceStNamCheckmatePatternsIV", "practiceStDesRecognizeThePatterns" },
    Rg2cMBZ6 = { "practiceStNamPieceCheckmatesII", "practiceStDesChallengingCheckmates" },
    ByhlXnmM = { "practiceStNamKnightAndBishopMate", "practiceStDesInteractiveLesson" },
    ["9ogFv8Ac"] = { "practiceStNamThePin", "practiceStDesPinItToWinIt" },
    tuoBxVE5 = { "practiceStNamTheSkewer", "practiceStDesYumSkewers" },
    Qj281y1p = { "practiceStNamTheFork", "practiceStDesUseTheForkLuke" },
    MnsJEWnI = { "practiceStNamDiscoveredAttacks", "practiceStDesIncludingDiscoveredChecks" },
    RUQASaZm = { "practiceStNamDoubleCheck", "practiceStDesAVeryPowerfulTactic" },
    o734CNqp = { "practiceStNamOverloadedPieces", "practiceStDesTheyHaveTooMuchWork" },
    ITWY4GN2 = { "practiceStNamZwischenzug", "practiceStDesInBetweenMoves" },
    lyVYjhPG = { "practiceStNamXRay", "practiceStDesAttackingThroughAnEnemyPiece" },
    ["9cKgYrHb"] = { "practiceStNamZugzwang", "practiceStDesBeingForcedToMove" },
    g1fxVZu9 = { "practiceStNamInterference", "practiceStDesInterposeAPieceToGreatEffect" },
    s5pLU7Of = { "practiceStNamGreekGift", "practiceStDesStudyTheGreekGiftSacrifice" },
    kdKpaYLW = { "practiceStNamDeflection", "practiceStDesDistractingADefender" },
    jOZejFWk = { "practiceStNamAttraction", "practiceStDesLureAPieceToABadSquare" },
    ["49fDW0wP"] = { "practiceStNamUnderpromotion", "practiceStDesPromoteButNotToAQueen" },
    ["0YcGiH4Y"] = { "practiceStNamDesperado", "practiceStDesAPieceIsLostButItCanStillHelp" },
    CgjKPvxQ = { "practiceStNamCounterCheck", "practiceStDesRespondToACheckWithACheck" },
    udx042D6 = { "practiceStNamUndermining", "practiceStDesRemoveTheDefendingPiece" },
    Grmtwuft = { "practiceStNamClearance", "practiceStDesGetOutOfTheWay" },
    xebrDvFe = { "practiceStNamKeySquares", "practiceStDesReachAKeySquare" },
    A4ujYOer = { "practiceStNamOpposition", "practiceStDesTakeTheOpposition" },
    pt20yRkT = { "practiceStNam7thRankRookPawn", "practiceStDesVersusAQueen" },
    MkDViieT = { "practiceStNam7thRankRookPawn", "practiceStDesAndPassiveRookVsRook" },
    pqUSUw8Y = { "practiceStNamBasicRookEndgames", "practiceStDesLucenaAndPhilidor" },
    heQDnvq7 = { "practiceStNamIntermediateRookEndings", "practiceStDesBroadenYourKnowledge" },
    wS23j5Tm = { "practiceStNamPracticalRookEndings", "practiceStDesRookEndingsWithSeveralPawns" },
}
local GOALS = { mate = "mate", mateIn = "mate_in", promotion = "promotion" }
local BRUSHES = { G = true, R = true, Y = true, B = true }

-- The text of a comment or description as the reader sees it: no drawing commands, no links (nothing opens them
-- on the device), no soft hyphens, no spaces left at the ends.
-- The only dashes of the source, said another way, since the texts of the plugin never have one. A new one stops the
-- build, to be added here.
local REWORDS = {
    { "three key squares \226\128\147 the square", "three key squares: the square" },
    { "e6+ \226\128\147 e7", "e6+ and e7" },
}

local function clean(text)
    text = tostring(text or ""):gsub("%[%%[^%]]*%]", ""):gsub("\194\173", "")
    -- A link written [text](address) keeps its text; a bare address goes, without the stop after it, and so does a
    -- colon that led to it.
    text = text:gsub("%[([^%]]*)%]%(https?://[^%)%s]*%)", "%1")
        :gsub(":%s*https?://[^%s%)]*[^%s%)%.,;]%.?", ".")
        :gsub("%s*https?://[^%s%)]*[^%s%)%.,;]", "")
    for _, reword in ipairs(REWORDS) do
        local from = reword[1]:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
        text = text:gsub(from, (reword[2]:gsub("%%", "%%%%")))
    end
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s%s+", " ")
    end
    text = table.concat(lines, "\n"):gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if text:find("\226\128\148", 1, true) or text:find("\226\128\147", 1, true) then
        fail("a text has a dash, which the texts of the plugin never have: " .. text)
    end
    return text ~= "" and text or nil
end

local function check_square(name, where)
    if not Chess.square_from_name(name) then
        fail(where .. ": not a square: " .. name)
    end
end

-- "Gb2h8,Rf6": arrows and circles, as the PGN writes them.
local function shapes_of(comment, where)
    local list = {}
    for kind, body in tostring(comment):gmatch("%[%%(c[as]l) ([^%]]*)%]") do
        for item in body:gmatch("[^,%s]+") do
            local brush, from, to = item:match("^(%u)(%l%d)(%l?%d?)$")
            if not brush or not BRUSHES[brush] or (kind == "cal") ~= (to ~= "") then
                fail(where .. ": unexpected shape " .. item)
            end
            check_square(from, where)
            if to ~= "" then
                check_square(to, where)
            end
            list[#list + 1] = item
        end
    end
    return list
end

-- The moves of a PGN as a tree: each node has the move that led to it (uci), the comments after it, and its
-- children, the first one being the main line.
local function parse_pgn(pgn, fen, where)
    local body = pgn
    while body:match("^%s*%[[^\n]*%]%s*\n") do
        body = body:gsub("^%s*%[[^\n]*%]%s*\n", "", 1)
    end
    local root = { position = Chess.parse_fen(fen), children = {}, comments = {} }
    if not root.position then
        fail(where .. ": cannot read the FEN")
    end
    local last, stack = root, {}
    -- Where the next move goes: after last, or, at the start of a variation, beside the move it replaces.
    local parent = root
    local pos = 1
    while pos <= #body do
        local c = body:sub(pos, pos)
        if c:match("%s") then
            pos = pos + 1
        elseif c == "{" then
            local stop = body:find("}", pos, true) or fail(where .. ": unfinished comment")
            local comment = body:sub(pos + 1, stop - 1)
            last.comments[#last.comments + 1] = comment
            pos = stop + 1
        elseif c == "(" then
            if last == root then
                fail(where .. ": a variation before any move")
            end
            stack[#stack + 1] = { last = last, parent = parent }
            parent = last.parent
            -- A comment before the first move of the variation waits for that move.
            last = { comments = {}, waiting = true }
            pos = pos + 1
        elseif c == ")" then
            local saved = table.remove(stack) or fail(where .. ": unbalanced )")
            last, parent = saved.last, saved.parent
            pos = pos + 1
        else
            local token = body:match("^[^%s{}()]+", pos)
            pos = pos + #token
            if token:match("^%d+%.+$") or token:match("^%$%d+$") or token == "*" or token == "1-0" or token == "0-1" or token == "1/2-1/2" then
                -- Move numbers, the marks of a move ($7) and the result say nothing the tree needs.
            else
                local number_and_move = token:match("^%d+%.+(.+)$")
                local san = (number_and_move or token):gsub("[!?]+$", "")
                local move = Chess.parse_san(parent.position, san)
                if not move then
                    fail(where .. ": cannot read the move " .. token)
                end
                local node = { uci = Chess.move_to_uci(move), position = Chess.play(parent.position, move), children = {}, comments = last.waiting and last.comments or {}, parent = parent }
                parent.children[#parent.children + 1] = node
                last, parent = node, node
            end
        end
    end
    if #stack > 0 then
        fail(where .. ": unbalanced (")
    end
    return root
end

local function comment_text(node)
    local parts = {}
    for _, comment in ipairs(node.comments) do
        parts[#parts + 1] = clean(comment)
    end
    return clean(table.concat(parts, "\n"))
end

local function comment_shapes(node, where)
    local list = {}
    for _, comment in ipairs(node.comments) do
        for _, item in ipairs(shapes_of(comment, where)) do
            list[#list + 1] = item
        end
    end
    return #list > 0 and table.concat(list, ",") or nil
end

local texts, text_keys = {}, {}
local function add_text(key, text)
    if text then
        if texts[key] then
            fail("two texts for " .. key)
        end
        texts[key] = text
        text_keys[#text_keys + 1] = key
    end
end

-- A guided chapter, or the commented game: the main line, and for each move the comment and shapes after it (ply
-- 0 is the start); for a guided one, the reader's moves off the line the author foresaw, with their comments, and the hints
-- and the comments for a move off the line, by ply as the app has them.
local function guided(chapter, kind, where)
    local root = parse_pgn(chapter.pgn, chapter.fen, where)
    local out = { kind = kind, line = {}, shapes = {}, wrong = {} }
    local node, ply = root, 0
    while true do
        local id = chapter.id
        add_text(id .. ".c" .. ply, comment_text(node))
        out.shapes[ply] = comment_shapes(node, where)
        local main = node.children[1]
        if not main then
            break
        end
        ply = ply + 1
        out.line[ply] = main.uci
        -- Only the reader's moves off the line are wrong moves; the opponent's are lines the author shows.
        if kind == "guided" and node.position.turn == (chapter.orientation == "white" and "w" or "b") then
            for i = 2, #node.children do
                local other = node.children[i]
                out.wrong[ply] = out.wrong[ply] or {}
                out.wrong[ply][other.uci] = comment_shapes(other, where) or ""
                add_text(id .. ".w" .. ply .. "." .. other.uci, comment_text(other))
            end
        end
        node = main
    end
    if ply == 0 then
        fail(where .. ": no moves")
    end
    for index, hint in pairs(chapter.hints or {}) do
        if index - 1 > ply then
            fail(where .. ": a hint past the end")
        end
        add_text(chapter.id .. ".h" .. (index - 1), clean(hint))
    end
    for index, deviation in pairs(chapter.deviations or {}) do
        if index - 1 > ply then
            fail(where .. ": a deviation past the end")
        end
        add_text(chapter.id .. ".v" .. (index - 1), clean(deviation))
    end
    return out
end

local file = assert(io.open(sources .. "/practice.json", "rb"))
local data = decode_json(file:read("*a"))
file:close()

local sections, counts, seen = {}, { goal = 0, guided = 0, lesson = 0, left = 0 }, {}
for _, section in ipairs(data.sections or fail("no sections")) do
    local section_key = SECTIONS[section.id] or fail("unknown section " .. tostring(section.id))
    local out_section = { id = section.id, name = section_key, studies = {} }
    for _, study in ipairs(section.studies) do
        local study_keys = STUDIES[study.id] or fail("unknown study " .. tostring(study.id))
        local out_study = { id = study.id, name = study_keys[1], subtitle = study_keys[2], chapters = {} }
        for _, chapter in ipairs(study.chapters) do
            local where = study.id .. "/" .. tostring(chapter.id)
            if not tostring(chapter.id):match("^%w+$") or seen[chapter.id] then
                fail(where .. ": unexpected or repeated id")
            end
            seen[chapter.id] = true
            if chapter.orientation ~= "white" and chapter.orientation ~= "black" then
                fail(where .. ": unexpected orientation")
            end
            local position = Chess.parse_fen(chapter.fen)
            if not position or Chess.ending(position) then
                fail(where .. ": not a position to play")
            end
            local out
            if chapter.kind == "practice" then
                local goal = chapter.goal or {}
                if GOALS[goal.result] then
                    out = { kind = "goal", goal = GOALS[goal.result], moves = goal.moves, cp = goal.cp }
                    if (goal.result == "mateIn") ~= (type(goal.moves) == "number") or (goal.result == "promotion") ~= (type(goal.cp) == "number") then
                        fail(where .. ": goal without its number")
                    end
                    local list = {}
                    for _, item in ipairs(chapter.shapes or {}) do
                        for _, shape in ipairs(shapes_of((#tostring(item) == 3 and "[%csl " or "[%cal ") .. tostring(item) .. "]", where)) do
                            list[#list + 1] = shape
                        end
                    end
                    out.shapes = #list > 0 and table.concat(list, ",") or nil
                    counts.goal = counts.goal + 1
                else
                    counts.left = counts.left + 1
                end
            elseif chapter.kind == "gamebook" then
                out = guided(chapter, "guided", where)
                counts.guided = counts.guided + 1
            elseif chapter.kind == "lesson" then
                out = guided(chapter, "lesson", where)
                counts.lesson = counts.lesson + 1
            else
                fail(where .. ": unknown kind " .. tostring(chapter.kind))
            end
            if out then
                out.id, out.fen, out.color = chapter.id, chapter.fen, chapter.orientation == "white" and "w" or "b"
                add_text(chapter.id .. ".n", clean(chapter.name) or fail(where .. ": no name"))
                add_text(chapter.id .. ".d", clean(chapter.description))
                out_study.chapters[#out_study.chapters + 1] = out
            end
        end
        if #out_study.chapters > 0 then
            out_section.studies[#out_section.studies + 1] = out_study
        end
    end
    sections[#sections + 1] = out_section
end

local function quote(text)
    return '"' .. text:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
end

local function ply_map(map)
    local keys = {}
    for ply in pairs(map) do
        keys[#keys + 1] = ply
    end
    table.sort(keys)
    local parts = {}
    for _, ply in ipairs(keys) do
        parts[#parts + 1] = string.format("[%d] = %s", ply, quote(map[ply]))
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

local out = {
    "-- Generated by tools/practice/build.lua from lichess-org/mobile (GPL-3.0), which takes the lessons from",
    "-- lichess.org/practice. Do not edit by hand.",
    "return {",
}
for _, section in ipairs(sections) do
    out[#out + 1] = string.format("    { id = %s, name = %s, studies = {", quote(section.id), quote(section.name))
    for _, study in ipairs(section.studies) do
        out[#out + 1] = string.format("        { id = %s, name = %s, subtitle = %s, chapters = {", quote(study.id), quote(study.name), quote(study.subtitle))
        for _, chapter in ipairs(study.chapters) do
            local fields = { "id = " .. quote(chapter.id), "kind = " .. quote(chapter.kind), "fen = " .. quote(chapter.fen), "color = " .. quote(chapter.color) }
            if chapter.kind == "goal" then
                fields[#fields + 1] = "goal = " .. quote(chapter.goal)
                if chapter.moves then
                    fields[#fields + 1] = "moves = " .. chapter.moves
                end
                if chapter.cp then
                    fields[#fields + 1] = "cp = " .. chapter.cp
                end
                if chapter.shapes then
                    fields[#fields + 1] = "shapes = " .. quote(chapter.shapes)
                end
            else
                local moves = {}
                for _, uci in ipairs(chapter.line) do
                    moves[#moves + 1] = quote(uci)
                end
                fields[#fields + 1] = "line = { " .. table.concat(moves, ", ") .. " }"
                if next(chapter.shapes) then
                    fields[#fields + 1] = "shapes = " .. ply_map(chapter.shapes)
                end
                if next(chapter.wrong) then
                    local plies = {}
                    for ply in pairs(chapter.wrong) do
                        plies[#plies + 1] = ply
                    end
                    table.sort(plies)
                    local parts = {}
                    for _, ply in ipairs(plies) do
                        local ucis = {}
                        for uci in pairs(chapter.wrong[ply]) do
                            ucis[#ucis + 1] = uci
                        end
                        table.sort(ucis)
                        local items = {}
                        for _, uci in ipairs(ucis) do
                            items[#items + 1] = string.format("[%s] = %s", quote(uci), quote(chapter.wrong[ply][uci]))
                        end
                        parts[#parts + 1] = string.format("[%d] = { %s }", ply, table.concat(items, ", "))
                    end
                    fields[#fields + 1] = "wrong = { " .. table.concat(parts, ", ") .. " }"
                end
            end
            out[#out + 1] = "            { " .. table.concat(fields, ", ") .. " },"
        end
        out[#out + 1] = "        } },"
    end
    out[#out + 1] = "    } },"
end
out[#out + 1] = "}"
out[#out + 1] = ""
file = assert(io.open(OUT, "wb"))
file:write(table.concat(out, "\n"))
file:close()

table.sort(text_keys)
local text_out = {
    "-- Generated by tools/practice/build.lua from lichess-org/mobile (GPL-3.0), which takes the lessons from",
    "-- lichess.org/practice. Do not edit by hand; the other languages are translated from these, by hand, in",
    "-- practice_texts_pt.lua and practice_texts_es.lua.",
    "return {",
}
for _, key in ipairs(text_keys) do
    text_out[#text_out + 1] = string.format("    [%s] = %s,", quote(key), quote(texts[key]))
end
text_out[#text_out + 1] = "}"
text_out[#text_out + 1] = ""
file = assert(io.open(OUT_TEXTS, "wb"))
file:write(table.concat(text_out, "\n"))
file:close()
print(string.format("%s: %d chapters with a goal, %d guided, %d commented game; %d left out (judged by evaluation)",
    OUT, counts.goal, counts.guided, counts.lesson, counts.left))
print(string.format("%s: %d texts", OUT_TEXTS, #text_keys))
