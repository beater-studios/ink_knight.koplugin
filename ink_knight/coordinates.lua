-- Coordinate training, as on Lichess: find the square named, or name the square marked, as many as possible in 30
-- seconds or with no limit. A wrong answer keeps the same square. No KOReader here, so the tests can use it.
local Chess = require("ink_knight/chess")

local Coordinates = {}

Coordinates.SECONDS = 30
Coordinates.CHOICES = 4

local function random_square(random, previous)
    while true do
        local square = random(1, 64)
        if square ~= previous then
            return square
        end
    end
end

-- mode: "find" or "name". color: "w" or "b", the side at the bottom. random(a, b): math.random by default.
function Coordinates.new(mode, color, random)
    random = random or math.random
    local session = { mode = mode, color = color, score = 0, misses = 0, random = random }
    session.target = random_square(random)
    Coordinates.deal(session)
    return session
end

-- For naming, the target and other squares to choose from, in the order of their names, so the place of the right
-- one says nothing.
function Coordinates.deal(session)
    session.choices = nil
    if session.mode ~= "name" then
        return
    end
    local picked, names = { [session.target] = true }, { Chess.square_name(session.target) }
    while #names < Coordinates.CHOICES do
        local square = random_square(session.random)
        if not picked[square] then
            picked[square] = true
            names[#names + 1] = Chess.square_name(square)
        end
    end
    table.sort(names)
    session.choices = names
end

-- answer: the square tapped, to find, or the name chosen, to name. Returns whether it was right.
function Coordinates.answer(session, answer)
    local right
    if session.mode == "name" then
        right = answer == Chess.square_name(session.target)
    else
        right = answer == session.target
    end
    if right then
        session.score = session.score + 1
        session.target = random_square(session.random, session.target)
        Coordinates.deal(session)
    else
        session.misses = session.misses + 1
    end
    return right
end

function Coordinates.record_key(mode, color)
    return mode .. "_" .. color
end

return Coordinates
