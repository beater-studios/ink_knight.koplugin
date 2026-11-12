-- The practice lessons of Lichess (lichess.org/practice, by way of the official app): sections of studies of
-- chapters, in ink_knight/data/practice.lua. A chapter with a goal is played against the engine of the plugin until
-- it mates, mates in so many moves or promotes, as the app judges them, apart from what needs a strong engine; a
-- guided chapter is a line to find move by move, with the author's comments; the commented game is only shown. No
-- KOReader here, so the tests can use it.
local Chess = require("ink_knight/chess")

local Practice = {}

-- The opponent of a chapter with a goal: the engine at its best, without noise, with the captures searched past its
-- depth, short enough to wait for on a Kindle.
Practice.ENGINE = { seconds = 2, depth = 3, noise = 0, quiescence = 4 }

local BRUSHES = { G = "green", R = "red", Y = "yellow", B = "blue" }

-- "Gb2h8,Rf6" as the board draws them: arrows and circles.
function Practice.shapes(text)
    local list = {}
    for brush, from, to in tostring(text or ""):gmatch("(%u)(%l%d)(%l?%d?)") do
        list[#list + 1] = { brush = BRUSHES[brush], from = Chess.square_from_name(from), to = to ~= "" and Chess.square_from_name(to) or nil }
    end
    return list
end

-- The chapter with this id, its study and its place in it.
function Practice.find(sections, id)
    for _, section in ipairs(sections) do
        for _, study in ipairs(section.studies) do
            for index, chapter in ipairs(study.chapters) do
                if chapter.id == id then
                    return chapter, study, index
                end
            end
        end
    end
end

-- progress: the fewest moves each chapter was done in, by id, as the app keeps it.
function Practice.count_done(study, progress)
    local done = 0
    for _, chapter in ipairs(study.chapters) do
        done = done + (progress[chapter.id] and 1 or 0)
    end
    return done
end

-- From 0 to 100, rounded down as on lichess.org.
function Practice.percent(sections, progress)
    local done, total = 0, 0
    for _, section in ipairs(sections) do
        for _, study in ipairs(section.studies) do
            done, total = done + Practice.count_done(study, progress), total + #study.chapters
        end
    end
    return total > 0 and math.floor(done * 100 / total) or 0
end

-- Where a study opens: its first chapter not done, or the first.
function Practice.first_open(study, progress)
    for index, chapter in ipairs(study.chapters) do
        if not progress[chapter.id] then
            return index
        end
    end
    return 1
end

-- Keeps the fewest moves a chapter was done in; returns whether that changed anything.
function Practice.record(progress, id, moves)
    if progress[id] and progress[id] <= moves then
        return false
    end
    progress[id] = moves
    return true
end

-- A chapter with a goal ------------------------------------------------------------------------------------------

function Practice.start_goal(chapter)
    local position = Chess.parse_fen(chapter.fen)
    return {
        position = position,
        player = chapter.color,
        played = 0,
        status = "playing",
        seen = { [Chess.epd(position)] = 1 },
    }
end

function Practice.is_player_turn(state)
    return state.status == "playing" and state.position.turn == state.player
end

-- Plays a move, by the reader or the engine, and judges what it led to as far as the rules can tell. Returns what
-- comes next: "judge" when the reader promoted and the engine must say whether the position is still won, "reply"
-- for the engine's move, "move" for the reader's, or "over".
function Practice.play(state, chapter, move)
    local by_player = state.position.turn == state.player
    local san = Chess.to_san(state.position, move)
    state.position = Chess.play(state.position, move)
    state.last_move = move
    state.last_san = san
    if by_player then
        state.played = state.played + 1
    end
    local key = Chess.epd(state.position)
    state.seen[key] = (state.seen[key] or 0) + 1
    -- As in the app: no fifty-move rule, since a long mate may need more, and the same position a third time only
    -- ends the goals of mate, the one of promotion going on.
    local ending = Chess.ending(state.position)
    if ending == "fifty" then
        ending = nil
    end
    if ending == "mate" then
        if by_player then
            state.status = "solved"
        else
            state.status, state.reason = "failed", "lost"
        end
        return "over"
    elseif ending or (state.seen[key] >= 3 and chapter.goal ~= "promotion") then
        state.status, state.reason = "failed", "draw"
        return "over"
    end
    if by_player then
        if chapter.goal == "mate_in" and state.played >= chapter.moves then
            state.status, state.reason = "failed", "slow"
            return "over"
        elseif chapter.goal == "promotion" and move.promotion then
            return "judge"
        end
        return "reply"
    end
    return "move"
end

-- After a promotion: score is the engine's for the side to move, nil when its search found nothing, which is let
-- pass. The target is for white, as on Lichess, so negative for a chapter played as black.
function Practice.judge_promotion(state, chapter, score)
    if score == nil then
        state.status = "solved"
        return
    end
    local white = state.position.turn == "w" and score or -score
    local won = state.player == "w" and white >= chapter.cp or state.player == "b" and white <= chapter.cp
    if won then
        state.status = "solved"
    else
        state.status, state.reason = "failed", "promotion"
    end
end

-- A guided chapter, or the commented game -------------------------------------------------------------------------

function Practice.start_guided(chapter)
    local positions, last_moves = { [0] = Chess.parse_fen(chapter.fen) }, {}
    for ply, uci in ipairs(chapter.line) do
        positions[ply], last_moves[ply] = Chess.apply_uci(positions[ply - 1], uci)
    end
    return { ply = 0, positions = positions, last_moves = last_moves }
end

-- "play" for the reader to find a move, "good" for the opponent's move to come (or a move found, to read about),
-- "bad" for a wrong move to take back, "end" when the line is over.
function Practice.feedback(state, chapter)
    if state.wrong then
        return "bad"
    elseif state.ply == #chapter.line then
        return "end"
    end
    return state.positions[state.ply].turn == chapter.color and "play" or "good"
end

function Practice.guided_position(state)
    if state.wrong then
        return state.wrong.position, state.wrong.move
    end
    return state.positions[state.ply], state.last_moves[state.ply]
end

-- The author's comment on what is on the board: on the move just played, or on a wrong move, the one they wrote for
-- it or, failing that, the one for any move played instead of theirs.
function Practice.comment(state, chapter, texts)
    if state.wrong then
        local ply = state.ply + 1
        return texts[chapter.id .. ".w" .. ply .. "." .. state.wrong.uci] or texts[chapter.id .. ".v" .. ply]
    end
    return texts[chapter.id .. ".c" .. state.ply]
end

function Practice.hint(state, chapter, texts)
    if Practice.feedback(state, chapter) ~= "play" then
        return nil
    end
    return texts[chapter.id .. ".h" .. state.ply]
end

function Practice.guided_shapes(state, chapter)
    if state.wrong then
        local wrong = chapter.wrong and chapter.wrong[state.ply + 1]
        return Practice.shapes(wrong and wrong[state.wrong.uci])
    end
    return Practice.shapes(chapter.shapes and chapter.shapes[state.ply])
end

-- The move to find, for the solution.
function Practice.solution(state, chapter)
    if Practice.feedback(state, chapter) ~= "play" then
        return nil
    end
    return Chess.parse_uci(state.positions[state.ply], chapter.line[state.ply + 1])
end

-- The reader's move: the next one of the line, or a wrong one to take back.
function Practice.guided_move(state, chapter, move)
    local uci = Chess.move_to_uci(move)
    if uci == chapter.line[state.ply + 1] then
        state.ply = state.ply + 1
    else
        state.wrong = { uci = uci, move = move, position = Chess.play(state.positions[state.ply], move) }
    end
end

-- Moves on: the opponent's move of the line, or back from a wrong move.
function Practice.guided_next(state, chapter)
    local feedback = Practice.feedback(state, chapter)
    if feedback == "good" then
        state.ply = state.ply + 1
    elseif feedback == "bad" then
        state.wrong = nil
    end
end

-- How many of the reader's moves of the line were found.
function Practice.guided_moves(state, chapter)
    local count = 0
    for ply = 1, state.ply do
        if state.positions[ply - 1].turn == chapter.color then
            count = count + 1
        end
    end
    return count
end

return Practice
