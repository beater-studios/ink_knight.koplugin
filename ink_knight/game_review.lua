-- The mistakes of a game played without internet, found by the small engine of the plugin: each move looked at is
-- compared with the best one found, and only the clear losses are marked, since the engine is too shallow to judge
-- small ones. No KOReader here, so the tests can use it.
local Api = require("ink_knight/api")
local Chess = require("ink_knight/chess")
local Engine = require("ink_knight/engine")

local GameReview = {}

-- What each move gets: the engine at its best, without noise, for a short time, with up to four captures searched
-- past its depth, so a line does not end in the middle of an exchange. On the Kindle 10 depth 3 took up to 1.5 s in a
-- middlegame, so the time leaves room for it.
GameReview.LIMITS = { seconds = 2.5, depth = 3, noise = 0, quiescence = 4 }
-- Losses, in hundredths of a pawn, from which a move is marked. A pawn and a half is past what the evaluation of
-- the engine can get wrong at this depth.
GameReview.BLUNDER, GameReview.MISTAKE = 300, 150

local MATE_FROM = Engine.MATE - 200

local function is_mate(score)
    return score >= MATE_FROM
end

local function is_mated(score)
    return score <= -MATE_FROM
end

-- "Blunder", "Mistake" or nil, with the names Lichess gives, from the scores of the best move and of the move
-- played, both for the side that moved.
function GameReview.judge(best, played)
    if not best or not played then
        return nil
    end
    if is_mated(played) and not is_mated(best) then
        return "Blunder"
    end
    if is_mate(best) and not is_mate(played) then
        -- A mate missed is a mistake while the game is still won, and a blunder when it is not any more.
        return played >= GameReview.BLUNDER and "Mistake" or "Blunder"
    end
    if is_mate(best) or is_mated(best) then
        return nil
    end
    local loss = best - played
    if loss >= GameReview.BLUNDER then
        return "Blunder"
    elseif loss >= GameReview.MISTAKE then
        return "Mistake"
    end
    return nil
end

-- The score of the position after the move for white: centipawns, or the moves to a mate (negative when black mates),
-- or both nil. The engine counts the plies to the mate from before the move, so the move itself comes off; a move
-- that mates leaves nothing.
function GameReview.white_score(score, mover)
    if not score then
        return nil, nil
    end
    local white = mover == "w" and score or -score
    if is_mate(white) or is_mated(white) then
        local after = Engine.MATE - math.abs(white) - 1
        if after <= 0 then
            return nil, nil
        end
        local moves = math.ceil(after / 2)
        return nil, white > 0 and moves or -moves
    end
    return white, nil
end

-- The same as Lichess writes it: "+1.20", or "#3" and "#-3" for a mate in so many moves.
function GameReview.eval_text(score, mover)
    local cp, mate = GameReview.white_score(score, mover)
    if not cp and not mate then
        return nil
    end
    return Api.eval_text(cp, mate)
end

-- The moves to look at: { index, position before it, uci, mover }. Only the moves of only_color when given (the
-- reader's, in a game against the engine), and none where there was a single legal move.
function GameReview.moves(initial_fen, moves, only_color)
    local position = Chess.start_position(initial_fen)
    local list, index = {}, 0
    for uci in tostring(moves or ""):gmatch("%S+") do
        index = index + 1
        local mover = position.turn
        if (not only_color or mover == only_color) and #Chess.legal_moves(position) > 1 then
            list[#list + 1] = { index = index, position = position, uci = uci, mover = mover }
        end
        position = Chess.apply_uci(position, uci)
        if not position then
            break
        end
    end
    return list
end

-- How many of each mark each side got: { w = { Blunder = n, Mistake = n }, b = { ... } }.
function GameReview.count(results)
    local counts = { w = { Blunder = 0, Mistake = 0 }, b = { Blunder = 0, Mistake = 0 } }
    for _, result in pairs(results) do
        if result.judgment then
            local side = counts[result.mover]
            side[result.judgment] = side[result.judgment] + 1
        end
    end
    return counts
end

return GameReview
