-- The cover of the sleep screen while the plugin is open: the game on the screen, or, with none, the first game waiting for the reader's turn, under a black band that says the e-reader rests. With no game to show it returns nil, and the fixed image of assets/screensaver.png stays.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")

local BoardScreen = require("ink_knight/ui/board_screen")
local Chess = require("ink_knight/chess")
local Correspondence = require("ink_knight/correspondence")
local Style = require("ink_knight/ui/style")

local Screen = Device.screen

local UIManager = require("ui/uimanager")

-- The open plugin, set by its first page. A game screen is found on the window stack: its board has cover_source, the game that answers cover_info.
local SleepCover = { app = nil }

-- The variants the plugin plays, so a game of another one is never drawn as plain chess.
local PLAYED = { standard = true, chess960 = true }

-- A game the reader waits on: { position, flipped, title, detail }, from a game of Lichess or a kept correspondence game.
local function waiting_game(app, s)
    local now = os.time()
    local candidates = {}
    for _, entry in ipairs(app.games or {}) do
        local variant = type(entry.variant) == "table" and entry.variant.key or entry.variant or "standard"
        if entry.isMyTurn and PLAYED[variant] then
            local game = Correspondence.from_playing(entry, now) or (type(entry.fen) == "string" and { fen = entry.fen, color = entry.color == "black" and "b" or "w", opponent = entry.opponent and entry.opponent.username })
            if game then
                game.perf = entry.perf or entry.speed
                candidates[#candidates + 1] = game
            end
        end
    end
    if #candidates == 0 and app.correspondence then
        local ok, data = pcall(app.correspondence, app)
        for _, game in ipairs(ok and data and data.games or {}) do
            if Correspondence.is_my_turn(game) and not game.pending then
                game.perf = "correspondence"
                candidates[#candidates + 1] = game
            end
        end
    end
    -- The first one whose position can be read.
    for _, game in ipairs(candidates) do
        local position = Chess.parse_fen(game.fen)
        if position then
            return {
                position = position,
                flipped = game.color == "b",
                title = string.format(s.sleep_your_turn, game.opponent or s.anonymous),
                detail = s.perf_names[game.perf] or nil,
            }
        end
    end
    return nil
end

function SleepCover.game(app)
    for widget in UIManager:topdown_widgets_iter() do
        local source = widget.cover_source
        if source and source.cover_info then
            local ok, info = pcall(source.cover_info, source)
            if ok and info and info.position then
                return info
            end
        end
    end
    return waiting_game(app, app.strings)
end

local function text(bb, value, name, size, x, y, w, h, color, align)
    if not value or value == "" then
        return
    end
    local widget = TextWidget:new{ text = value, face = Font:getFace(name, size * 1000 / Screen:scaleBySize(1000)), fgcolor = color, max_width = w }
    local measured = widget:getSize()
    local left = align == "left" and x or x + math.floor((w - measured.w) / 2)
    widget:paintTo(bb, left, y + math.floor((h - measured.h) / 2))
    widget:free()
end

-- The cover, a Blitbuffer the size of the screen, or nil with no game to show.
function SleepCover.draw()
    local app = SleepCover.app
    if not app or app.is_closed then
        return nil
    end
    local info = SleepCover.game(app)
    if not info then
        return nil
    end
    local s = app.strings
    local width, height = Screen:getWidth(), Screen:getHeight()
    local scale = math.min(width / 600, height / 800)
    local function px(value)
        return math.floor(value * scale + 0.5)
    end
    local bb = Blitbuffer.new(width, height, Blitbuffer.TYPE_BB8)
    bb:fill(Style.WHITE)
    -- The band that says it rests: a crescent moon, the word and how to come back.
    local band = px(96)
    bb:paintRect(0, 0, width, band, Style.BLACK)
    local mx, my, mr = px(58), math.floor(band / 2), px(22)
    bb:paintCircle(mx, my, mr, Style.WHITE)
    bb:paintCircle(mx + math.floor(mr * 0.45), my - math.floor(mr * 0.35), math.floor(mr * 0.82), Style.BLACK)
    text(bb, s.sleep_resting, Style.BOLD, 26 * scale, px(96), px(18), width - px(112), px(40), Style.WHITE, "left")
    text(bb, s.sleep_return, Style.REGULAR, 15 * scale, px(96), px(56), width - px(112), px(28), Style.PALE, "left")
    -- The board as large as the rest leaves, then what game it is.
    local below = px(110)
    local frame = px(18)
    local size = math.min(width - 2 * px(30), height - band - below - px(28) - 2 * frame)
    local x = math.floor((width - size) / 2)
    BoardScreen.paint_board_at(bb, info.position, x, band + px(24) + frame, size, info.flipped)
    local y = band + px(24) + size + 2 * frame + px(14)
    text(bb, info.title, Style.BOLD, 21 * scale, px(16), y, width - px(32), px(34), Style.BLACK)
    text(bb, info.detail, Style.REGULAR, 15 * scale, px(16), y + px(34), width - px(32), px(26), Style.DARK)
    text(bb, s.games_title, Style.BOLD, 13 * scale, px(16), height - px(32), width - px(32), px(24), Style.MID)
    return bb
end

return SleepCover
