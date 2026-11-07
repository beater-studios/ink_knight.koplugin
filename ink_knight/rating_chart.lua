-- The rating of a player over time, turned into what the chart draws. It knows nothing about the screen.
local RatingChart = {}

local STEPS = { 10, 25, 50, 100, 200, 250, 500, 1000 }
local MAX_TICKS = 5

local function normalize(name)
    return tostring(name):lower():gsub("[%s%-]", "")
end

-- history: what Lichess sends, with one series per kind of game, whose names differ from the keys of the profile.
function RatingChart.points(history, perf)
    local wanted = perf == "puzzle" and "puzzles" or normalize(perf)
    for _, series in ipairs(history or {}) do
        if normalize(series.name) == wanted then
            local points = {}
            for _, raw in ipairs(series.points or {}) do
                -- Lichess counts months from zero.
                local time = os.time({ year = raw[1], month = raw[2] + 1, day = raw[3], hour = 12 })
                points[#points + 1] = { time = time, rating = raw[4] }
            end
            return points
        end
    end
    return {}
end

-- rect: x, y, w, h. Returns the marks in pixels, or nil without points.
function RatingChart.layout(points, rect)
    if #points == 0 then
        return nil
    end
    local lowest, highest = math.huge, -math.huge
    for _, point in ipairs(points) do
        lowest, highest = math.min(lowest, point.rating), math.max(highest, point.rating)
    end
    local step = STEPS[#STEPS]
    for _, candidate in ipairs(STEPS) do
        if math.ceil(highest / candidate) - math.floor(lowest / candidate) <= MAX_TICKS - 1 then
            step = candidate
            break
        end
    end
    local bottom, top = math.floor(lowest / step) * step, math.ceil(highest / step) * step
    if top == bottom then
        top = bottom + step
    end
    local first, last = points[1].time, points[#points].time
    local function y_of(rating)
        return rect.y + rect.h - math.floor((rating - bottom) / (top - bottom) * rect.h + 0.5)
    end
    local function x_of(time)
        if last == first then
            return rect.x + math.floor(rect.w / 2)
        end
        return rect.x + math.floor((time - first) / (last - first) * rect.w + 0.5)
    end
    local ticks = {}
    for value = bottom, top, step do
        ticks[#ticks + 1] = { value = value, y = y_of(value) }
    end
    local path = {}
    for _, point in ipairs(points) do
        path[#path + 1] = { x = x_of(point.time), y = y_of(point.rating) }
    end
    return {
        ticks = ticks,
        path = path,
        lowest = lowest,
        highest = highest,
        current = points[#points].rating,
        first_time = first,
        last_time = last,
    }
end

-- The numbers below the chart. data is the answer of the statistics, which can be missing.
function RatingChart.stat_lines(s, data, layout)
    local lines = {}
    local stat = data and data.stat or {}
    local count = stat.count
    if count and (count.all or 0) > 0 then
        lines[#lines + 1] = string.format(s.stat_games, count.all, count.win or 0, count.loss or 0, count.draw or 0)
    end
    local highest = stat.highest and stat.highest.int or (layout and layout.highest)
    local lowest = stat.lowest and stat.lowest.int or (layout and layout.lowest)
    if highest and lowest then
        lines[#lines + 1] = string.format(s.stat_range, highest, lowest)
    end
    local streak = stat.resultStreak and stat.resultStreak.win and stat.resultStreak.win.max
    if streak and (streak.v or 0) > 0 then
        lines[#lines + 1] = string.format(s.stat_streak, streak.v)
    end
    if data and type(data.percentile) == "number" then
        lines[#lines + 1] = string.format(s.stat_percentile, string.format("%.1f", data.percentile))
    end
    return lines
end

return RatingChart
