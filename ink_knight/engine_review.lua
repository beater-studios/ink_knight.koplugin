-- A game judged as Lichess judges it, from Stockfish's score of each position: each move by how much it lowered the
-- mover's chances of winning (inaccuracy, mistake, blunder), the average loss in centipawns and an accuracy from the
-- winning chances lost on each move. Used for the analysis made by the plugin on the device, never for the one the
-- site made. No KOReader here, so the tests can use it.
local Api = require("ink_knight/api")

local EngineReview = {}

-- The losses of winning chances (from -1 to 1) from which a move is marked, as on Lichess.
EngineReview.THRESHOLDS = { { 0.3, "Blunder" }, { 0.2, "Mistake" }, { 0.1, "Inaccuracy" } }
-- Scores past this many centipawns count as this many, as on Lichess.
EngineReview.CP_CAP = 1000

-- A score { cp, mate } for the side to move as centipawns, a mate in n as a large number that keeps faster mates
-- larger, the way the app of Lichess counts mates in winning chances.
local function centipawns(score)
    if score.mate then
        local cp = (21 - math.min(10, math.abs(score.mate))) * 100
        return score.mate > 0 and cp or -cp
    end
    return math.max(-EngineReview.CP_CAP, math.min(EngineReview.CP_CAP, score.cp or 0))
end

function EngineReview.chances(cp)
    return 2 / (1 + math.exp(-0.00368208 * cp)) - 1
end

-- The score of a position after its game ended, for the side to move: mated ({ mate = 0 }), or a draw.
function EngineReview.final_score(position_ending)
    if position_ending == "mate" then
        return { mate = 0 }
    end
    return { cp = 0 }
end

-- scores[i]: the score of the position after i moves, for the side to move there ({ cp } or { mate }), i from 0;
-- movers[i]: who played move i ("w" or "b"); best[i]: the best move in the position before move i (UCI), from the
-- search of position i - 1. Returns, for each move, { judgment, eval_text, loss, white_cp, white_score, white_mate },
-- white_cp being the score after the move for white in centipawns, a mate as a thousand, for the chart, and
-- white_score or white_mate the score as the engine gave it, for white; and, per side, the counts, average
-- loss and accuracy: { w = { inaccuracy, mistake, blunder, acpl, accuracy }, b = { ... } }.
function EngineReview.judge(scores, movers)
    local moves, sides = {}, { w = { losses = {}, accuracies = {} }, b = { losses = {}, accuracies = {} } }
    for i = 1, #movers do
        local before, after = scores[i - 1], scores[i]
        if before and after then
            local mover = movers[i]
            -- Both for the mover: the position before is theirs to play, the one after is the opponent's.
            local cp_before = centipawns(before)
            local cp_after = after.mate == 0 and centipawns({ mate = 1 }) or -centipawns(after)
            local wc_before, wc_after = EngineReview.chances(cp_before), EngineReview.chances(cp_after)
            local drop = wc_before - wc_after
            local judgment
            for _, threshold in ipairs(EngineReview.THRESHOLDS) do
                if drop >= threshold[1] then
                    judgment = threshold[2]
                    break
                end
            end
            local side = sides[mover]
            -- Both capped at a thousand either way, as on Lichess, so a mate allowed costs at most that much.
            local cap = EngineReview.CP_CAP
            local loss = math.max(0, math.max(-cap, math.min(cap, cp_before)) - math.max(-cap, math.min(cap, cp_after)))
            side.losses[#side.losses + 1] = loss
            -- The accuracy of a move, from the winning chances (in percent) it lost, with the curve Lichess uses.
            local percent_drop = math.max(0, (wc_before - wc_after) * 50)
            local accuracy = 103.1668 * math.exp(-0.04354 * percent_drop) - 3.1669
            side.accuracies[#side.accuracies + 1] = math.max(0, math.min(100, accuracy))
            -- The score after the move, for white, as Lichess writes it: the position after is the opponent's to play.
            -- A move that mates leaves nothing to write.
            local sign = mover == "b" and 1 or -1
            local eval_text
            if after.mate and after.mate ~= 0 then
                eval_text = Api.eval_text(nil, sign * after.mate)
            elseif not after.mate then
                eval_text = Api.eval_text(sign * (after.cp or 0), nil)
            end
            local for_white = mover == "w" and cp_after or -cp_after
            moves[i] = {
                judgment = judgment, eval_text = eval_text, loss = loss, white_cp = math.max(-cap, math.min(cap, for_white)),
                white_score = not after.mate and sign * (after.cp or 0) or nil,
                white_mate = after.mate and after.mate ~= 0 and sign * after.mate or nil,
            }
        end
    end
    local summary = {}
    for color, side in pairs(sides) do
        local counts = { Inaccuracy = 0, Mistake = 0, Blunder = 0 }
        for i = 1, #movers do
            if movers[i] == color and moves[i] and moves[i].judgment then
                counts[moves[i].judgment] = counts[moves[i].judgment] + 1
            end
        end
        local sum, harmonic = 0, 0
        for _, value in ipairs(side.accuracies) do
            sum = sum + value
            harmonic = harmonic + 1 / math.max(value, 1)
        end
        local n = #side.accuracies
        local losses = 0
        for _, value in ipairs(side.losses) do
            losses = losses + value
        end
        summary[color] = {
            inaccuracy = counts.Inaccuracy, mistake = counts.Mistake, blunder = counts.Blunder,
            acpl = n > 0 and math.floor(losses / n + 0.5) or nil,
            -- The mean of the plain and harmonic averages, so a few bad moves weigh more than in a plain average.
            accuracy = n > 0 and math.floor((sum / n + n / harmonic) / 2 + 0.5) or nil,
        }
    end
    return moves, summary
end

return EngineReview
