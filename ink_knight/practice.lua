-- The practice lessons of Lichess (lichess.org/practice, by way of the official app): sections of studies of
-- chapters, in ink_knight/data/practice.lua. A chapter with a goal is played against the engine of the plugin until
-- it mates, mates in so many moves or promotes, as the app judges them, apart from what needs a strong engine. One
-- judged by an evaluation (reach an advantage or equalize in so many moves) follows a tree worked out with Stockfish
-- when the data is built (ink_knight/data/practice_trees.lua): the reader's moves it accepts, with the opponent's
-- answer to each. One to hold the draw in king and pawn against king is judged exactly, with the table of that
-- ending (ink_knight/kpk.lua). The long endgames to hold the draw or equalize (engine = true) are judged move by move by the plugin's Stockfish, as the app judges them, and only where it runs. A guided chapter is a line to find move by move, with the author's comments; the
-- commented game is only shown. No KOReader here, so the tests can use it.
local Chess = require("ink_knight/chess")
local EngineReview = require("ink_knight/engine_review")
local Kpk = require("ink_knight/kpk")

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

Practice.TREE_GOALS = { eval_in = true, equal_in = true }
Practice.SCRIPTED_GOALS = { eval_in = true, equal_in = true, draw_in = true }
local DRAW_GOALS = { equal_in = true, draw_in = true }

function Practice.tree_of(chapter)
    return Practice.TREE_GOALS[chapter.goal] and require("ink_knight/data/practice_trees")[chapter.id] or nil
end

function Practice.start_goal(chapter)
    local position = Chess.parse_fen(chapter.fen)
    local state = {
        position = position,
        player = chapter.color,
        played = 0,
        status = "playing",
        seen = { [Chess.epd(position)] = 1 },
    }
    local tree = Practice.tree_of(chapter)
    if tree then
        state.node, state.reply = tree.tree, tree.first
    end
    return state
end

-- The entry of the move in a position of the tree: { uci, true } solves the chapter, { uci, false } can no longer
-- reach the goal, { uci, reply, node } goes on with the opponent's answer.
local function tree_entry(node, uci)
    for _, entry in ipairs(node) do
        if entry[1] == uci then
            return entry
        end
    end
    return nil
end

-- The best move the tree knows for the reader: the first that still reaches the goal.
function Practice.tree_best(state)
    for _, entry in ipairs(state.node or {}) do
        if entry[2] ~= false then
            return Chess.parse_uci(state.position, entry[1])
        end
    end
    return nil
end

function Practice.tree_reply(state)
    return state.reply and Chess.parse_uci(state.position, state.reply) or nil
end

-- Whether the side with the pawn wins a position of king and pawn against king, or what is left of it: a pawn
-- taken leaves a draw, and a new queen or rook wins unless the other king takes it at once.
local function strong_wins(position, strong)
    local result = Kpk.result(position)
    if result then
        return result == "win"
    end
    local piece_square, count = nil, 0
    for square = 1, 64 do
        local piece = position.board[square]
        if piece then
            count = count + 1
            if piece:lower() ~= "k" then
                piece_square = square
            end
        end
    end
    if count ~= 3 or not piece_square then
        return false
    end
    local piece = position.board[piece_square]:lower()
    if piece ~= "q" and piece ~= "r" then
        return false
    end
    if position.turn ~= strong then
        for _, move in ipairs(Chess.legal_moves(position)) do
            if move.to == piece_square then
                return false
            end
        end
    end
    return true
end

local function strong_side(state)
    return state.player == "w" and "b" or "w"
end

local function drawing_moves(state)
    local list = {}
    for _, move in ipairs(Chess.legal_moves(state.position)) do
        if not strong_wins(Chess.play(state.position, move), strong_side(state)) then
            list[#list + 1] = move
        end
    end
    return list
end

function Practice.best_move(state, chapter)
    if chapter.goal == "draw_in" then
        return drawing_moves(state)[1]
    end
    return Practice.tree_best(state)
end

-- The opponent's move in a chapter judged without the engine. To hold the draw, a winning move if the reader let one
-- in, or else the drawing one that leaves the reader the fewest moves that still draw.
function Practice.scripted_reply(state, chapter)
    if chapter.goal ~= "draw_in" then
        return Practice.tree_reply(state)
    end
    local strong = strong_side(state)
    local best, fewest
    for _, move in ipairs(Chess.legal_moves(state.position)) do
        local after = Chess.play(state.position, move)
        if strong_wins(after, strong) then
            return move
        end
        local holding = 0
        for _, reply in ipairs(Chess.legal_moves(after)) do
            if not strong_wins(Chess.play(after, reply), strong) then
                holding = holding + 1
            end
        end
        -- A new piece the other king takes at once is no try; it is played only when nothing else is left.
        local score = holding + (move.promotion and 100 or 0)
        if not fewest or score < fewest then
            best, fewest = move, score
        end
    end
    return best
end

function Practice.is_player_turn(state)
    return state.status == "playing" and state.position.turn == state.player
end

-- Plays a move, by the reader or the engine, and judges what it led to as far as the rules can tell. Returns what
-- comes next: "judge" when the reader promoted and the engine must say whether the position is still won, "reply"
-- for the engine's move, "move" for the reader's, or "over".
function Practice.play(state, chapter, move)
    local by_player = state.position.turn == state.player
    local entry, better
    local before = state.position
    if state.node then
        state.notice = nil
        if by_player then
            local uci = Chess.move_to_uci(move)
            entry = tree_entry(state.node, uci)
            if not entry then
                -- A fair move the tree did not follow is taken back, so the reader tries another; any other is a
                -- mistake, as the app calls it.
                if state.node.o and (" " .. state.node.o .. " "):find(" " .. uci .. " ", 1, true) then
                    state.notice = "other"
                    return "move"
                end
                local best = Practice.tree_best(state)
                better = best and Chess.to_san(state.position, best)
            end
        else
            state.reply = nil
        end
    end
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
    elseif by_player and state.node and not entry then
        -- As in the app, a mistake fails even when it happens to draw the game.
        state.status, state.reason, state.better = "failed", "mistake", better
        return "over"
    elseif ending or (state.seen[key] >= 3 and chapter.goal ~= "promotion") then
        if DRAW_GOALS[chapter.goal] then
            state.status = "solved"
        else
            state.status, state.reason = "failed", "draw"
        end
        return "over"
    end
    if by_player and chapter.engine then
        return "engine_judge"
    end
    if by_player and chapter.goal == "draw_in" then
        if strong_wins(state.position, strong_side(state)) then
            local best = drawing_moves({ position = before, player = state.player })[1]
            state.status, state.reason, state.better = "failed", "mistake", best and Chess.to_san(before, best)
            return "over"
        elseif state.played >= chapter.moves then
            state.status = "solved"
            return "over"
        end
        return "reply"
    end
    if by_player and state.node then
        if entry[2] == true then
            state.status = "solved"
        elseif entry[2] == false then
            state.status, state.reason = "failed", state.played >= chapter.moves and "short" or "astray"
        else
            state.reply, state.node = entry[2], entry[3]
            return "reply"
        end
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

-- The judgment of the app for the long endgames (practice_goal.dart and practice_comment.dart of lichess-org/mobile, from lila's studyPracticeSuccess.ts) -----------------------------------------------------------------------------

-- An evaluation counts from this depth, as in the app; a shallower one judges nothing.
Practice.SOLID_DEPTH = 15
-- The shifts of winning chances (from -1 to 1) of the app's verdicts, and the chances past which a position is won.
local GOOD_SHIFT, INACCURACY_SHIFT, MISTAKE_SHIFT, WINNING = 0.05, 0.11, 0.24, 0.5

-- "good", "not_best", "inaccuracy", "mistake" or "blunder", from the reader's chances before and after the move and whether the engine had a better one.
function Practice.verdict(before_chances, after_chances, has_better_move)
    local shift = before_chances - after_chances
    if not has_better_move or shift < GOOD_SHIFT then
        return "good"
    elseif before_chances >= WINNING and after_chances >= WINNING then
        return "not_best"
    elseif shift < INACCURACY_SHIFT then
        return "inaccuracy"
    elseif shift < MISTAKE_SHIFT then
        return "mistake"
    end
    return "blunder"
end

-- Whether a score is roughly level (no mate, less than a pawn and a half), or nil without one.
local function drawish(score)
    if not score then
        return nil
    end
    return score.mate == nil and math.abs(score.cp or 0) < 150
end

-- After a move of the reader in a long endgame. before and after: the scores of the positions before and after the move, for the reader ({ cp } or { mate }), each nil when the engine did not reach SOLID_DEPTH; better: the engine's move before, in the usual notation, when it was not the one played. Ends the chapter, or returns "reply" for the engine's answer.
function Practice.judge_engine(state, chapter, before, after, better)
    if before and after then
        local verdict = Practice.verdict(EngineReview.score_chances(before), EngineReview.score_chances(after), better ~= nil)
        if verdict == "mistake" or verdict == "blunder" then
            state.status, state.reason, state.better = "failed", "mistake", better
            return "over"
        end
    end
    local level = drawish(after)
    if level == false or state.played > chapter.moves then
        state.status, state.reason = "failed", "short"
        return "over"
    elseif level and state.played >= chapter.moves then
        state.status = "solved"
        return "over"
    end
    return "reply"
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
