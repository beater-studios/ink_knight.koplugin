-- The chart of the evaluation along a game, as a row of a page: white's advantage above the middle line, black's
-- below, the line of the scores over both, and the mistakes and blunders marked on it. A tap goes to the move under it.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")

local Screen = Device.screen

local EvalChart = {}

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local WHITE_AREA, BLACK_AREA = Blitbuffer.Color8(0xDD), Blitbuffer.Color8(0x66)
local MIDDLE, LEGEND = Blitbuffer.Color8(0x55), Blitbuffer.Color8(0x55)
-- Scores past five pawns either way are drawn at the edge, so the small ones still show.
local LIMIT = 500
local HEIGHT, LEGEND_H = 150, 28

-- The score for white after each move, from 0 (the start) to count: a move without one keeps the one before it.
function EvalChart.values(moves, count)
    local values, known = { [0] = 0 }, 0
    for i = 1, count do
        local cp = moves[i] and moves[i].white_cp
        if cp then
            known = known + 1
            values[i] = math.max(-LIMIT, math.min(LIMIT, cp))
        else
            values[i] = values[i - 1]
        end
    end
    return values, known
end

-- nil when fewer than two moves have a score. moves: { white_cp, judgment }; on_move(index) for a tap, index going
-- from 0, the start, to count. Drawn once and kept, since a page paints again on every tap.
function EvalChart.row(moves, count, legend, scale, on_move)
    local values, known = EvalChart.values(moves, count)
    if known < 2 or count < 2 then
        return nil
    end
    local function px(value)
        return math.floor(value * scale + 0.5)
    end
    local cache
    return {
        kind = "drawing",
        height = HEIGHT,
        points = count,
        on_point = on_move,
        draw = function(target, at_x, at_y, w, h)
            if cache and (cache:getWidth() ~= w or cache:getHeight() ~= h) then
                cache:free()
                cache = nil
            end
            if cache then
                target:blitFrom(cache, at_x, at_y, 0, 0, w, h)
                return
            end
            cache = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
            local bb, x, y = cache, 0, 0
            bb:fill(WHITE)
            local top, bottom = y + px(8), y + h - px(LEGEND_H)
            local mid = math.floor((top + bottom) / 2)
            local half = mid - top - px(4)
            local function point(index)
                return x + math.floor(w * index / count), mid - math.floor(half * values[index] / LIMIT)
            end
            bb:paintRect(x, top, w, bottom - top, WHITE)
            for column = 0, w - 1 do
                local at = column / w * count
                local i = math.floor(at)
                local a, b = values[i], values[math.min(count, i + 1)]
                local cy = mid - math.floor(half * (a + (b - a) * (at - i)) / LIMIT)
                if cy < mid then
                    bb:paintRect(x + column, cy, 1, mid - cy, WHITE_AREA)
                elseif cy > mid then
                    bb:paintRect(x + column, mid, 1, cy - mid, BLACK_AREA)
                end
            end
            bb:paintRect(x, mid, w, 1, MIDDLE)
            local thick = math.max(2, px(3))
            for index = 1, count do
                local x0, y0 = point(index - 1)
                local x1, y1 = point(index)
                local steps = math.max(1, math.abs(x1 - x0), math.abs(y1 - y0))
                for step = 0, steps do
                    local px0 = x0 + math.floor((x1 - x0) * step / steps)
                    local py0 = y0 + math.floor((y1 - y0) * step / steps)
                    bb:paintRect(px0 - math.floor(thick / 2), py0 - math.floor(thick / 2), thick, thick, BLACK)
                end
            end
            -- A blunder as a black dot, a mistake as a ring.
            for index = 1, count do
                local judgment = moves[index] and moves[index].judgment
                if judgment == "Blunder" or judgment == "Mistake" then
                    local cx, cy = point(index)
                    bb:paintCircle(cx, cy, px(10), WHITE)
                    if judgment == "Blunder" then
                        bb:paintCircle(cx, cy, px(7), BLACK)
                    else
                        bb:paintCircle(cx, cy, px(7), BLACK, px(3))
                    end
                end
            end
            bb:paintBorder(x, top, w, bottom - top, math.max(1, px(2)), BLACK)
            -- Font:getFace scales by the screen already, so the size given is taken back to the page's own scale.
            local text = TextWidget:new{ text = legend, face = Font:getFace("noto/NotoSans-Regular.ttf", 14 * scale * 1000 / Screen:scaleBySize(1000)), fgcolor = LEGEND, max_width = w }
            local size = text:getSize()
            text:paintTo(bb, x, bottom + math.floor((px(LEGEND_H) - size.h) / 2))
            text:free()
            target:blitFrom(cache, at_x, at_y, 0, 0, w, h)
        end,
    }
end

return EvalChart
