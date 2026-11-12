-- Puzzles and their results, kept so they work with no network. It knows nothing about the screen.
local Chess = require("ink_knight/chess")
local Pgn = require("ink_knight/pgn")

local Puzzles = {}

Puzzles.BATCH_SIZE = 15
-- When this few are left, a new batch is asked for.
Puzzles.LOW = 3

-- From what Lichess sends to what the screen needs: the position to solve and the moves expected.
-- The game goes up to the opponent's last move, and the first move of the solution belongs to the reader.
-- angle: the theme it came from, left out for the general mix.
function Puzzles.prepare(raw, angle)
    local puzzle, game = raw.puzzle, raw.game
    if not puzzle or not puzzle.id or not puzzle.solution or not game or not game.pgn then
        return nil
    end
    local moves = Pgn.san_list_to_moves(game.pgn)
    if #moves ~= select(2, tostring(game.pgn):gsub("%S+", "")) then
        return nil
    end
    return {
        id = puzzle.id,
        angle = angle,
        rating = puzzle.rating,
        themes = puzzle.themes,
        solution = puzzle.solution,
        played = table.concat((function()
            local list = {}
            for i, move in ipairs(moves) do
                list[i] = move.uci
            end
            return list
        end)(), " "),
    }
end

-- What a batch was asked with, kept in each puzzle, so a change of difficulty or color is followed without losing
-- the puzzles kept for when there is no connection. Puzzles from before the choice were asked with neither.
function Puzzles.wanted(difficulty, color)
    return difficulty .. " " .. color
end
Puzzles.DEFAULT_WANTED = Puzzles.wanted("normal", "any")

local function is_wanted(puzzle, wanted)
    return (puzzle.wanted or Puzzles.DEFAULT_WANTED) == wanted
end

function Puzzles.count_wanted(pile, wanted)
    local count = 0
    for _, puzzle in ipairs(pile) do
        if is_wanted(puzzle, wanted) then
            count = count + 1
        end
    end
    return count
end

-- Takes out the first puzzle asked as wanted. Without one, the first of the pile, so there is always something to
-- solve offline.
function Puzzles.take(pile, wanted)
    for index, puzzle in ipairs(pile) do
        if is_wanted(puzzle, wanted) then
            return table.remove(pile, index)
        end
    end
    return table.remove(pile, 1)
end

-- Leaves only the puzzles asked as wanted, once a batch asked that way has arrived to take the place of the rest.
function Puzzles.drop_unwanted(pile, wanted)
    for index = #pile, 1, -1 do
        if not is_wanted(pile[index], wanted) then
            table.remove(pile, index)
        end
    end
end

-- Adds to the pile the prepared puzzles it does not know yet. Puzzles still on the device have not been played as
-- far as Lichess knows, so a new batch can bring them again. known: ids to leave out, as { [id] = true }.
function Puzzles.add_new(pile, incoming, known)
    local seen = {}
    for id in pairs(known or {}) do
        seen[id] = true
    end
    for _, puzzle in ipairs(pile) do
        seen[puzzle.id] = true
    end
    local added = 0
    for _, puzzle in ipairs(incoming) do
        if not seen[puzzle.id] then
            seen[puzzle.id] = true
            pile[#pile + 1] = puzzle
            added = added + 1
        end
    end
    return added
end

-- The pile of missed puzzles to review, kept apart from the new ones. Their results go to Lichess as any other.
Puzzles.REVIEW = "review"
-- How many missed puzzles are fetched at a time, one request each.
Puzzles.REVIEW_FETCH = 10

-- Brings the review pile in line with what Lichess still lists as missed: what is no longer listed leaves, since it
-- was solved, perhaps on the site, and what is missing is to be fetched, apart from known ids, such as a result still
-- waiting to be sent. Returns the pile kept and the ids to fetch, at most limit of them.
function Puzzles.review_plan(pile, remaining, known, limit)
    local listed, kept, have = {}, {}, {}
    for _, id in ipairs(remaining or {}) do
        listed[id] = true
    end
    for _, puzzle in ipairs(pile or {}) do
        if listed[puzzle.id] then
            kept[#kept + 1] = puzzle
            have[puzzle.id] = true
        end
    end
    local fetch = {}
    for _, id in ipairs(remaining or {}) do
        if #fetch >= limit then
            break
        end
        if not have[id] and not (known or {})[id] and tostring(id):match("^%w+$") then
            fetch[#fetch + 1] = id
            have[id] = true
        end
    end
    return kept, fetch
end

-- A session walks through one puzzle: the reader plays, and the reply comes by itself.
-- A puzzle from Lichess starts from the game it came from; one of the package, from its FEN.
function Puzzles.new_session(puzzle)
    local position, last = Chess.from_moves(puzzle.fen, puzzle.played)
    if not position then
        return nil
    end
    return { puzzle = puzzle, position = position, last_move = last, my_color = position.turn, step = 1, mistakes = 0 }
end

-- Tries a move. Returns "correct", "solved" or "wrong". A mate counts even if it is not the expected move.
function Puzzles.try_move(session, uci)
    local expected = session.puzzle.solution[session.step]
    local position, move = Chess.apply_uci(session.position, uci)
    if not position then
        return "wrong"
    end
    local mates = Chess.ending(position) == "mate"
    if uci ~= expected and not mates then
        session.mistakes = session.mistakes + 1
        return "wrong"
    end
    session.position, session.last_move = position, move
    session.step = session.step + 1
    if mates or session.step > #session.puzzle.solution then
        session.solved = true
        return "solved"
    end
    return "correct"
end

-- The opponent's answer, played after a correct move.
function Puzzles.play_reply(session)
    local uci = session.puzzle.solution[session.step]
    if not uci then
        return false
    end
    local position, move = Chess.apply_uci(session.position, uci)
    if not position then
        return false
    end
    session.position, session.last_move = position, move
    session.step = session.step + 1
    return true
end

-- The move that comes next, for the Show button.
function Puzzles.hint(session)
    return session.puzzle.solution[session.step]
end

-- What Lichess records: solved at the first try, or not.
function Puzzles.result(session)
    return { id = session.puzzle.id, angle = session.puzzle.angle, win = session.solved == true and session.mistakes == 0 and not session.revealed, rated = true }
end

-- The body that sends the results, in JSON, with ids that came from Lichess itself checked again.
function Puzzles.results_body(results, count)
    local parts = {}
    for index, result in ipairs(results) do
        if count and index > count then
            break
        end
        if tostring(result.id):match("^[%w]+$") then
            parts[#parts + 1] = string.format('{"id":"%s","win":%s,"rated":%s}', result.id, result.win and "true" or "false", result.rated == false and "false" or "true")
        end
    end
    return '{"solutions":[' .. table.concat(parts, ",") .. "]}"
end

-- Results go to Lichess by theme: the theme of the first one, and how many in a row share it.
function Puzzles.first_group(results)
    local angle = results[1] and results[1].angle
    local count = 0
    for _, result in ipairs(results) do
        if result.angle ~= angle then
            break
        end
        count = count + 1
    end
    return angle, count
end

return Puzzles
