-- Every screen outside the board: a title in a black band with a way back, and rows laid out for a finger on
-- e-ink, on a light gray ground. Rows that list things share a white card with the rows next to them; buttons,
-- headings, texts and tiles stand on the ground. Rows are plain tables, and a page that does not fit is split in
-- sheets, turned with a swipe or the buttons at the foot.
--
-- kind nil: text, detail, value, tag, piece, bold, dim, callback. tag: a short state in a black pill before the
-- value, such as "Your turn". piece: a piece ("K" or "k") in a light circle before the name. "game": the same.
-- "section": text, action_text, action. "primary" and "secondary": text, callback. "stat": text, value.
-- "toggle": text, on, on_text, off_text, callback, a switch with its word inside. "text": text, center.
-- "hero": icon (or piece), text, stars ({ won, of }), detail, note, and band (in a black band from the top) or card. "tiles": columns, items of { text, detail, label, icon, solid, callback }, and fill to
-- grow into the room left on the page; solid draws the tile in black, as the one chosen.
-- disabled, on a row or a tile: shown in gray, and tapping it does nothing.
-- preview, on a plain row: function(bb, x, y, size) drawing a sample before the text, preview_columns sizes wide, each preview_size units (40 by default).
-- "moves": number, white, black, white_current, black_current, white_callback, black_callback, as on a score sheet.
-- "phase": text, a heading inside the score sheet, where a phase of the game begins.
-- focus, on any row: the page opens on the sheet that holds it.
-- "buttons": items of { text, callback, primary }, side by side in equal parts, the text made smaller if it does not fit.
-- "split": text, white, draws, black, value: a move of an explorer, with a bar of how its games ended.
-- "metric": text, value, detail: a number in large, with what it is beside it.
-- "figures": items of { value, label }: numbers side by side over what they count.
-- "state": text, detail, piece: what the page has instead of its rows, loading, empty or failed, with fill to
-- stand in the middle of the page; the piece tells which ("N" loading, "P" empty, "r" no connection, "b" error).
-- "drawing": height, draw(bb, x, y, w, h): a picture of its own, the width of its card; with points and
-- on_point(index), a tap on it gives the nearest of points + 1 marks spread evenly across it, from 0.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Draw = require("ink_knight/ui/draw")
local MoveText = require("ink_knight/ui/move_text")
local Portrait = require("ink_knight/portrait")
local Refresh = require("ink_knight/refresh")
local Sleep = require("ink_knight/sleep")
local StatusStrip = require("ink_knight/ui/status_strip")
local Style = require("ink_knight/ui/style")

local Screen = Device.screen

local BOLD, REGULAR = Style.BOLD, Style.REGULAR
local SYMBOLS = "freefont/FreeSerif.ttf"
local BLACK, WHITE = Style.BLACK, Style.WHITE
local GRAY = Style.DARK
local LINE = Style.LIGHT
local DISABLED = Style.DISABLED
local DRAW_GRAY = Style.LIGHT

local FOOTER_H, MARGIN = 58, 16
-- Room above a card and below it, and inside it on the sides.
local GAP, PAD = 14, 16
-- The band of a page about someone.
local HERO_H = 150
-- Above the first row, under the header.
local TOP = 6
-- A tile that fills the page stops growing here, so a few of them do not turn into walls.
local MAX_FILL_EXTRA = 110
local HEIGHTS = { section = 40, primary = 76, secondary = 72, stat = 50, toggle = 60, game = 68, hero = 190, moves = 40, phase = 34, buttons = 76, split = 56, metric = 84, figures = 82 }
-- The rows that sit in a white card with the ones next to them; the others stand on the gray ground.
local CARDED = { game = true, toggle = true, stat = true, metric = true, moves = true, phase = true, split = true, figures = true, drawing = true }

local function carded(line)
    return line ~= nil and (line.kind == nil or CARDED[line.kind] == true)
end

local Page = InputContainer:extend{
    name = "ink_knight_page",
    covers_fullscreen = true,
    stop_events_propagation = true,
    title = "",
    subtitle = nil,
    -- false for a page that has no title and no way back, such as the first one.
    header = true,
    rows = nil,
    build = nil,
    close_on_tap = false,
    on_closed = nil,
    -- Where the Back key goes: closing the page by default, one step back.
    on_back = nil,
    -- Shown in place of the rows when they cannot be drawn.
    broken_text = nil,
    -- "center" or "bottom" for a question or a choice in a card over the screen, which stays visible around it;
    -- icon, the name of an icon of ui/draw.lua over the title of a question; hint, a line at the foot of a choice.
    dialog = nil,
    icon = nil,
    hint = nil,
    -- A taller black band in place of the title, for a page about someone: hero = { piece, title, detail, note }.
    hero = nil,
}

-- One count for every page of the plugin, since they open and close over each other with the same layout:
-- a change of a page, a page on top or a page that closes gets "ui", and the update after eight of them
-- flashes the whole screen, which KOReader would never do for "ui" by itself.
Page.refresh = Refresh.new(8)

function Page.refresh_mode()
    return Page.refresh:mode("page")
end

local function face(name, size)
    return Font:getFace(name, size * 1000 / Screen:scaleBySize(1000))
end

-- The rows stay where they are, so the page keeps its shape, and none of them answers.
function Page.disable_rows(rows)
    for _, row in ipairs(rows) do
        row.disabled = true
        row.callback, row.action, row.action_text = nil, nil, nil
        for _, item in ipairs(row.items or {}) do
            item.disabled = true
            item.callback = nil
        end
    end
end

function Page:init()
    Portrait.open(self, self.setup)
end

-- Everything init does, after the screen is in portrait. A failure here gives the rotation back.
function Page:setup()
    if self.dialog then
        self.covers_fullscreen = false
    end
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.scale = math.min(self.width / 600, self.height / 800)
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
    Sleep.watch(self)
    self.sheet = 1
    self:reload(true)
    for index, sheet in ipairs(self.sheets) do
        for _, line in ipairs(sheet) do
            if line.focus then
                self.sheet = index
            end
        end
    end
end

function Page:px(value)
    return math.floor(value * self.scale + 0.5)
end

function Page:text_box(row)
    return TextBoxWidget:new{
        text = row.text,
        face = face(REGULAR, 17 * self.scale),
        width = self.width - 2 * self:px(MARGIN) - 2 * self:px(4),
        alignment = row.center and "center" or "left",
        fgcolor = BLACK,
        bgcolor = Style.PAPER,
    }
end

-- The card of a group of rows: where it is, how wide, and where the rows draw inside it.
function Page:card_box()
    local m = self:px(MARGIN)
    local w = self.width - 2 * m - self:px(Style.CARD_SHADOW)
    return m, w, m + self:px(PAD), w - 2 * self:px(PAD)
end

-- What a row shows before its name: a drawing of its own, or a piece in a circle.
function Page:lead_width(row)
    if row.preview then
        return self:px(row.preview_size or 40) * (row.preview_columns or 1) + self:px(14)
    elseif row.piece then
        return self:px(48)
    end
    return 0
end

function Page:tag_width(row)
    if not row.tag or row.disabled then
        return 0
    end
    return Draw.text_width(row.tag, BOLD, 12 * self.scale) + self:px(20) + self:px(10)
end

-- The width the name of a row has, beside its value, its tag and its arrow.
function Page:nav_text_width(row)
    local _, _, _, inner_w = self:card_box()
    local arrow_w = row.callback and self:px(28) or 0
    local value_w = row.value and row.value ~= "" and self:px(row.wide_value and 220 or 150) or 0
    return inner_w - self:lead_width(row) - arrow_w - value_w - self:tag_width(row)
end

-- The name of a row with wrap, on as many lines as it needs, with its detail below when it has one.
function Page:wrapped_box(row, color)
    return TextBoxWidget:new{
        text = row.text,
        face = face(BOLD, 18 * self.scale),
        width = self:nav_text_width(row),
        fgcolor = color or BLACK,
        bgcolor = WHITE,
    }
end

function Page:base_height(row)
    if row.kind == "drawing" then
        return self:px(row.height)
    elseif row.wrap and not row.kind then
        local box = self:wrapped_box(row)
        local height = box:getSize().h
        box:free()
        return math.max(self:px(64), height + self:px(24) + (row.detail and self:px(22) or 0))
    elseif row.kind == "text" then
        local box = self:text_box(row)
        local height = box:getSize().h
        box:free()
        return height + self:px(18)
    elseif row.kind == "tile_line" then
        return self:px(row.has_icon and (row.has_detail and 136 or 116) or (row.has_label and 102 or (row.has_detail and 92 or 76)))
    elseif row.kind == "hero" and (row.card or row.note or row.stars) then
        return self:px(HEIGHTS.hero + (row.note and 30 or 0) + (row.card and 50 or 0) + (row.stars and 50 or 0) - ((row.stars and not row.detail) and 28 or 0))
    elseif row.kind == "state" then
        local inner = self.width - 2 * self:px(MARGIN)
        return self:px(150) + self:box_height(row.text, BOLD, 21, inner) + (row.detail and self:box_height(row.detail, REGULAR, 16, inner) + self:px(6) or 0) + self:px(24)
    elseif HEIGHTS[row.kind] then
        return self:px(HEIGHTS[row.kind])
    end
    return math.max(self:px(row.detail and 68 or 60), row.preview_size and self:px(row.preview_size + 20) or 0)
end

-- A row with the room around its card: above the first row of a card that has no heading over it, and below the last.
function Page:row_height(row)
    return self:base_height(row) + (row.gap_before and self:px(GAP) or 0) + (row.gap_after and self:px(GAP) or 0)
end

-- Tiles become lines, so that a sheet can end between them; the rows next to each other share a card.
local function flatten(rows)
    local lines = {}
    for _, row in ipairs(rows or {}) do
        if row.kind == "tiles" then
            local columns = row.columns or 2
            for start = 1, #row.items, columns do
                local line = { kind = "tile_line", columns = columns, items = {}, fill = row.fill }
                for index = start, math.min(start + columns - 1, #row.items) do
                    local item = row.items[index]
                    line.items[#line.items + 1] = item
                    line.has_icon = line.has_icon or item.icon ~= nil
                    line.has_detail = line.has_detail or item.detail ~= nil
                    line.has_label = line.has_label or item.label ~= nil
                end
                lines[#lines + 1] = line
            end
        else
            lines[#lines + 1] = row
        end
    end
    for index, line in ipairs(lines) do
        local before, after = lines[index - 1], lines[index + 1]
        line.gap_before = carded(line) and not carded(before) and not (before and before.kind == "section")
        line.gap_after = carded(line) and not carded(after)
    end
    return lines
end

function Page:content_top()
    if self.hero then
        return self:px(HERO_H) + self:px(TOP)
    end
    return (self.header and self:px(Style.BAND) or 0) + self:px(TOP)
end

function Page:split(lines)
    local room = self.height - StatusStrip.height() - self:content_top() - self:px(8)
    local total = 0
    local heights = {}
    for index, line in ipairs(lines) do
        heights[index] = self:row_height(line)
        total = total + heights[index]
    end
    if total <= room then
        local filling = {}
        for index, line in ipairs(lines) do
            if line.fill then
                filling[#filling + 1] = index
            end
        end
        if #filling > 0 then
            local extra = math.min(math.floor((room - total) / #filling), self:px(MAX_FILL_EXTRA))
            for _, index in ipairs(filling) do
                heights[index] = heights[index] + extra
            end
        end
        return { lines }, heights
    end
    room = room - self:px(FOOTER_H)
    local sheets, current, used = {}, {}, 0
    for index, line in ipairs(lines) do
        local height = heights[index]
        local alone_heading = line.kind == "section" and lines[index + 1] and used + height + heights[index + 1] > room
        if #current > 0 and (used + height > room or alone_heading) then
            sheets[#sheets + 1] = current
            current, used = {}, 0
        end
        current[#current + 1] = line
        used = used + height
    end
    sheets[#sheets + 1] = current
    return sheets, heights
end

-- Rows again, from build when there is one. Before the page is on screen, nothing needs drawing.
function Page:reload(first_time)
    local rows = self.build and self.build(self) or self.rows
    self.lines = flatten(rows)
    self.heights_of = {}
    local sheets, heights = self:split(self.lines)
    for index, line in ipairs(self.lines) do
        self.heights_of[line] = heights[index]
    end
    self.sheets = sheets
    self.sheet = math.min(self.sheet, #sheets)
    if not first_time then
        self:redraw()
    end
end

-- Whether the page is shown and no other full screen covers it.
function Page:is_visible()
    local stack = UIManager._window_stack
    for index = #stack, 1, -1 do
        local widget = stack[index].widget
        if widget == self then
            return true
        elseif widget.covers_fullscreen then
            return false
        end
    end
    return false
end

-- The whole page, as the shared count says. Asleep, it waits for the device to wake up. A page under another
-- full screen is drawn again when that one closes, so it asks for nothing now.
function Page:redraw()
    if self:is_visible() then
        Sleep.dirty(self, function() return Page.refresh_mode(), self.card_rect or self.dimen end)
    end
end

function Page:paint_text(bb, text, name, size, x, y, w, h, align, color)
    if not text or text == "" then
        return
    end
    local widget = TextWidget:new{ text = text, face = face(name, size * self.scale), fgcolor = color or BLACK, max_width = w }
    local measured = widget:getSize()
    local tx = x
    if align == "center" then
        tx = x + math.floor((w - measured.w) / 2)
    elseif align == "right" then
        tx = x + w - measured.w
    end
    widget:paintTo(bb, tx, y + math.floor((h - measured.h) / 2))
    widget:free()
end

-- The largest size, from size down to smallest, at which text fits in width, so a label is never cut.
function Page:fitting_size(text, name, size, smallest, width)
    for candidate = size, smallest + 1, -1 do
        local widget = TextWidget:new{ text = text, face = face(name, candidate * self.scale) }
        local fits = widget:getSize().w <= width
        widget:free()
        if fits then
            return candidate
        end
    end
    return smallest
end

function Page:add_hit(x, y, w, h, callback, keep_open)
    if callback then
        self.hits[#self.hits + 1] = { x = x, y = y, w = w, h = h, callback = callback, keep_open = keep_open }
    end
end

-- The band of a page about someone: the way back, a piece in a white circle, the name, a line about them and a state with a dot, such as online.
function Page:paint_hero(bb, hero)
    local height = self:px(HERO_H)
    bb:paintRect(0, 0, self.width, height, BLACK)
    Draw.icon(bb, "back", self:px(26), self:px(32), self:px(24), WHITE)
    self:add_hit(0, 0, self:px(80), self:px(60), function() UIManager:close(self) end, true)
    local radius = self:px(40)
    local cx, cy = self:px(44) + radius, self:px(30) + radius
    bb:paintCircle(cx, cy, radius, WHITE)
    local BoardScreen = require("ink_knight/ui/board_screen")
    BoardScreen.paint_piece_fit(bb, BoardScreen.piece_set, hero.piece or "n", cx, cy, math.floor(radius * 1.35))
    local x = cx + radius + self:px(18)
    local w = self.width - x - self:px(MARGIN)
    self:paint_text(bb, hero.title, BOLD, 26, x, self:px(36), w, self:px(36), "left", WHITE)
    self:paint_text(bb, hero.detail, REGULAR, 15, x, self:px(72), w, self:px(24), "left", Style.PALE)
    if hero.note then
        bb:paintCircle(x + self:px(5), self:px(110), self:px(5), WHITE)
        self:paint_text(bb, hero.note, BOLD, 14, x + self:px(16), self:px(98), w - self:px(16), self:px(24), "left", WHITE)
    end
end

function Page:paint_header(bb)
    if self.hero then
        self:paint_hero(bb, self.hero)
        return
    end
    local height = self:px(Style.BAND)
    local back = self:px(52)
    bb:paintRect(0, 0, self.width, height, BLACK)
    Draw.icon(bb, "back", self:px(26), math.floor(height / 2), self:px(24), WHITE)
    local subtitle_w = self.subtitle and self:px(170) or 0
    self:paint_text(bb, self.title, BOLD, Style.TITLE, back, 0, self.width - back - subtitle_w - self:px(MARGIN), height, "left", WHITE)
    if self.subtitle then
        self:paint_text(bb, self.subtitle, REGULAR, 15, self.width - subtitle_w - self:px(MARGIN), 0, subtitle_w, height, "right", Style.PALE)
    end
    self:add_hit(0, 0, back + self:px(40), height, function() UIManager:close(self) end, true)
end

-- A piece in a light circle, before the name of a row: the side of a game, a player.
function Page:paint_piece(bb, piece, x, y, h)
    local radius = self:px(20)
    local cx, cy = x + radius, y + math.floor(h / 2)
    bb:paintCircle(cx, cy, radius, Style.PALE)
    local BoardScreen = require("ink_knight/ui/board_screen")
    BoardScreen.paint_piece_fit(bb, BoardScreen.piece_set, piece, cx, cy, math.floor(radius * 1.45))
end

function Page:paint_nav(bb, row, y, h)
    local _, _, x, inner_w = self:card_box()
    local right = x + inner_w
    local arrow_w = row.callback and self:px(28) or 0
    local value_w = row.value and row.value ~= "" and self:px(row.wide_value and 220 or 150) or 0
    local tag_w = self:tag_width(row)
    local text_w = self:nav_text_width(row)
    if row.preview then
        local size = self:px(row.preview_size or 40)
        row.preview(bb, x, y + math.floor((h - size) / 2), size)
    elseif row.piece then
        self:paint_piece(bb, row.piece, x, y, h)
    end
    x = x + self:lead_width(row)
    local color = row.disabled and DISABLED or (row.dim and GRAY or BLACK)
    local detail_color = row.disabled and DISABLED or GRAY
    if row.wrap and not row.kind then
        local box = self:wrapped_box(row, color)
        local box_h = box:getSize().h
        if row.detail then
            local top = y + math.floor((h - box_h - self:px(22)) / 2)
            box:paintTo(bb, x, top)
            self:paint_text(bb, row.detail, REGULAR, 14, x, top + box_h, text_w, self:px(22), "left", detail_color)
        else
            box:paintTo(bb, x, y + math.floor((h - box_h) / 2))
        end
        box:free()
    elseif row.detail then
        local top = y + math.floor((h - self:px(52)) / 2)
        self:paint_text(bb, row.text, BOLD, 18, x, top, text_w, self:px(30), "left", color)
        self:paint_text(bb, row.detail, REGULAR, 14, x, top + self:px(30), text_w, self:px(22), "left", detail_color)
    else
        self:paint_text(bb, row.text, BOLD, 18, x, y, text_w, h, "left", color)
    end
    local cursor = right - arrow_w
    if value_w > 0 then
        self:paint_text(bb, row.value, REGULAR, 16, cursor - value_w, y, value_w - self:px(4), h, "right", detail_color)
        cursor = cursor - value_w
    end
    if tag_w > 0 then
        local tag_h = self:px(24)
        Draw.tag(bb, row.tag, cursor - tag_w + self:px(4), y + math.floor((h - tag_h) / 2), tag_h, self.scale, true)
    end
    if row.callback then
        Draw.icon(bb, "next", right - self:px(9), y + math.floor(h / 2), self:px(18))
    end
end

function Page:paint_tile(bb, item, x, y, w, h)
    local shadow = self:px(Style.CARD_SHADOW)
    w, h = w - shadow, h - shadow
    local solid = item.solid and not item.disabled
    local color = item.disabled and DISABLED or (solid and WHITE or BLACK)
    local detail_color = item.disabled and DISABLED or (solid and WHITE or GRAY)
    if item.disabled then
        local radius = self:px(Style.CARD_RADIUS)
        bb:paintRoundedRect(x, y, w, h, WHITE, radius)
        bb:paintBorder(x, y, w, h, self:px(2), LINE, radius)
    else
        Draw.card(bb, x, y, w, h, self.scale, solid)
    end
    local pad = self:px(6)
    if item.icon then
        -- The piece in a light band on top, the name below it, and a line under the name when it has one.
        local label_h = self:px(item.detail and 60 or 40)
        local border = math.max(1, math.floor(Style.CARD_BORDER * self.scale + 0.5))
        local radius = math.max(1, self:px(Style.CARD_RADIUS) - border)
        local band_h = h - label_h - border
        if not solid and not item.disabled then
            bb:paintRoundedRect(x + border, y + border, w - 2 * border, band_h, Style.PALE, radius)
            bb:paintRect(x + border, y + border + band_h - radius, w - 2 * border, radius, Style.PALE)
        end
        local icon_h = math.min(band_h - self:px(8), self:px(96))
        -- A chess sign fills about two thirds of its size.
        self:paint_text(bb, item.icon, SYMBOLS, math.floor(icon_h * 1.25 / self.scale), x, y + border + math.floor((band_h - icon_h) / 2), w, icon_h, "center", color)
        if item.detail then
            self:paint_text(bb, item.text, BOLD, 18, x + pad, y + h - label_h + self:px(4), w - 2 * pad, self:px(30), "center", color)
            self:paint_text(bb, item.detail, REGULAR, 13, x + pad, y + h - label_h + self:px(32), w - 2 * pad, self:px(22), "center", detail_color)
        else
            self:paint_text(bb, item.text, BOLD, 18, x + pad, y + h - label_h, w - 2 * pad, label_h, "center", color)
        end
    elseif item.label then
        -- A number with what it counts above it, as the ratings of a player, and a line below.
        local top = y + math.floor((h - self:px(80)) / 2)
        self:paint_text(bb, item.label, REGULAR, 13, x + pad, top, w - 2 * pad, self:px(20), "center", detail_color)
        self:paint_text(bb, item.text, BOLD, 24, x + pad, top + self:px(20), w - 2 * pad, self:px(38), "center", color)
        self:paint_text(bb, item.detail, REGULAR, 12, x + pad, top + self:px(58), w - 2 * pad, self:px(20), "center", detail_color)
    elseif item.detail then
        local top = y + math.floor((h - self:px(66)) / 2)
        self:paint_text(bb, item.text, BOLD, 24, x + pad, top, w - 2 * pad, self:px(40), "center", color)
        self:paint_text(bb, item.detail, REGULAR, 14, x + pad, top + self:px(40), w - 2 * pad, self:px(24), "center", detail_color)
    else
        self:paint_text(bb, item.text, BOLD, 19, x + pad, y, w - 2 * pad, h, "center", color)
    end
    self:add_hit(x, y, w, h, item.callback, item.keep_open)
end

-- A button in a pill: black when it does what the page is for, outlined otherwise, gray when it does nothing.
function Page:paint_pill_button(bb, x, y, w, h, text, solid, disabled)
    solid = solid and not disabled
    if disabled then
        bb:paintRoundedRect(x, y, w, h, WHITE, math.floor(h / 2))
        bb:paintBorder(x, y, w, h, self:px(2), LINE, math.floor(h / 2))
    else
        Draw.pill(bb, x, y, w, h, self.scale, solid)
    end
    local pad = self:px(10)
    local size = self:fitting_size(text, BOLD, 20, 14, w - 2 * pad)
    self:paint_text(bb, text, BOLD, size, x + pad, y, w - 2 * pad, h, "center", solid and WHITE or (disabled and DISABLED or BLACK))
end

-- The switch of a Yes/No row: its word inside, beside the knob.
function Page:paint_switch(bb, row, x, y, w, h)
    local knob = math.floor(h / 2) - self:px(5)
    if row.on then
        Draw.pill(bb, x, y, w, h, self.scale, true)
        bb:paintCircle(x + w - math.floor(h / 2), y + math.floor(h / 2), knob, WHITE)
        self:paint_text(bb, row.on_text, BOLD, 13, x + self:px(6), y, w - h - self:px(4), h, "center", WHITE)
    else
        Draw.pill(bb, x, y, w, h, self.scale, false)
        bb:paintCircle(x + math.floor(h / 2), y + math.floor(h / 2), knob, BLACK)
        self:paint_text(bb, row.off_text, BOLD, 13, x + h - self:px(2), y, w - h - self:px(4), h, "center", BLACK)
    end
end

-- A bar of how the games of a move ended, white, draws and black, as on Lichess, in a pill.
function Page:paint_result_bar(bb, row, x, y, w, h)
    local total = math.max(1, row.white + row.draws + row.black)
    -- Each part ends where the games so far end, rounded once, so the parts fill the bar exactly.
    local cursor, counted = x, 0
    local labels = {}
    for _, part in ipairs({ { row.white, WHITE, BLACK }, { row.draws, DRAW_GRAY, BLACK }, { row.black, BLACK, WHITE } }) do
        counted = counted + part[1]
        local part_w = x + math.floor(w * counted / total + 0.5) - cursor
        if part_w > 0 then
            bb:paintRect(cursor, y, part_w, h, part[2])
            if part_w >= self:px(48) then
                labels[#labels + 1] = { string.format("%d%%", math.floor(part[1] / total * 100 + 0.5)), cursor, part_w, part[3] }
            end
        end
        cursor = cursor + part_w
    end
    local radius = math.floor(h / 2)
    Draw.round_corners(bb, x, y, w, h, radius, WHITE)
    bb:paintBorder(x, y, w, h, self:px(2), BLACK, radius)
    for _, label in ipairs(labels) do
        self:paint_text(bb, label[1], BOLD, 14, label[2], y, label[3], h, "center", label[4])
    end
end

function Page:paint_line(bb, row, y, h)
    local m = self:px(MARGIN)
    local _, _, cx, cw = self:card_box()
    if row.kind == "section" then
        local action_w = row.action_text and self:px(170) or 0
        self:paint_text(bb, Draw.upper(row.text), BOLD, Style.SECTION_TEXT, m + self:px(8), y + self:px(12), self.width - 2 * m - self:px(8) - action_w, h - self:px(14), "left", GRAY)
        if row.action_text then
            self:paint_text(bb, row.action_text, BOLD, 15, self.width - m - action_w, y + self:px(12), action_w, h - self:px(14), "right")
            self:add_hit(self.width - m - action_w - self:px(20), y, action_w + m + self:px(20), h, row.action, true)
        end
    elseif row.kind == "primary" or row.kind == "secondary" then
        local bh = math.min(h - self:px(16), self:px(Style.BUTTON))
        local by = y + math.floor((h - bh) / 2)
        self:paint_pill_button(bb, m, by, self.width - 2 * m, bh, row.text, row.kind == "primary", row.disabled)
        self:add_hit(m, by, self.width - 2 * m, bh, row.callback, row.keep_open)
    elseif row.kind == "buttons" then
        local gap = self:px(8)
        local count = #row.items
        local w = math.floor((self.width - 2 * m - gap * (count - 1)) / count)
        local bh = math.min(h - 2 * gap, self:px(Style.BUTTON))
        local by = y + math.floor((h - bh) / 2)
        for index, item in ipairs(row.items) do
            local x = m + (index - 1) * (w + gap)
            self:paint_pill_button(bb, x, by, w, bh, item.text, item.primary, item.disabled)
            self:add_hit(x, by, w, bh, item.callback, item.keep_open)
        end
    elseif row.kind == "moves" then
        local number_w = self:px(70)
        local column_w = math.floor((cw - number_w) / 2)
        self:paint_text(bb, row.number, REGULAR, 17, cx, y, number_w, h, "left", GRAY)
        for index, side in ipairs({ "white", "black" }) do
            local x = cx + number_w + (index - 1) * column_w
            local text = row[side]
            if text then
                local current = row[side .. "_current"]
                if current then
                    local pill_h = h - self:px(8)
                    Draw.pill(bb, x - self:px(10), y + self:px(4), column_w - self:px(20), pill_h, self.scale, true)
                end
                MoveText.paint(self, bb, text, BOLD, 19, x, y, column_w - self:px(40), h, "left", current and WHITE or BLACK)
                self:add_hit(x - self:px(10), y, column_w, h, row[side .. "_callback"])
            end
        end
    elseif row.kind == "phase" then
        local ph = h - self:px(10)
        bb:paintRoundedRect(cx, y + self:px(5), cw, ph, Style.PALE, math.floor(ph / 2))
        self:paint_text(bb, Draw.upper(row.text), BOLD, 12, cx + self:px(10), y + self:px(5), cw - self:px(20), ph, "center", GRAY)
    elseif row.kind == "split" then
        -- A move of an explorer: its name, a bar of how its games ended and how many games.
        local name_w, value_w, gap = self:px(100), self:px(74), self:px(12)
        MoveText.paint(self, bb, row.text, BOLD, 19, cx, y, name_w - self:px(8), h, "left")
        local bar_x, bar_w = cx + name_w, cw - name_w - value_w - gap
        local bar_h = self:px(30)
        self:paint_result_bar(bb, row, bar_x, y + math.floor((h - bar_h) / 2), bar_w, bar_h)
        self:paint_text(bb, row.value, REGULAR, 15, cx + cw - value_w, y, value_w, h, "right", GRAY)
    elseif row.kind == "drawing" then
        row.draw(bb, cx, y, cw, h)
        if row.points and row.on_point then
            self:add_hit(cx, y, cw, h, function()
                local tap_x = self.tap_x or cx
                row.on_point(math.max(0, math.min(row.points, math.floor((tap_x - cx) / cw * row.points + 0.5))))
            end)
        end
    elseif row.kind == "figures" then
        -- Numbers side by side, each over what it counts.
        local count = #row.items
        local w = math.floor(cw / count)
        local pad = self:px(4)
        for index, item in ipairs(row.items) do
            local x = cx + (index - 1) * w
            if index > 1 then
                bb:paintRect(x, y + self:px(14), 1, h - self:px(28), LINE)
            end
            self:paint_text(bb, item.value, BOLD, 26, x + pad, y + self:px(8), w - 2 * pad, self:px(40), "center")
            self:paint_text(bb, item.label, REGULAR, 13, x + pad, y + self:px(48), w - 2 * pad, self:px(24), "center", GRAY)
        end
    elseif row.kind == "metric" then
        -- A number that matters, large, with what it is beside it.
        local value_w = self:px(150)
        if row.detail then
            self:paint_text(bb, row.text, BOLD, 18, cx, y + self:px(14), cw - value_w, self:px(30), "left")
            self:paint_text(bb, row.detail, REGULAR, 14, cx, y + self:px(44), cw - value_w, self:px(24), "left", GRAY)
        else
            self:paint_text(bb, row.text, BOLD, 18, cx, y, cw - value_w, h, "left")
        end
        self:paint_text(bb, row.value, BOLD, 36, cx + cw - value_w, y, value_w, h, "right")
    elseif row.kind == "stat" then
        self:paint_text(bb, row.text, REGULAR, 17, cx, y, cw - self:px(180), h, "left")
        self:paint_text(bb, row.value, BOLD, 17, cx + cw - self:px(180), y, self:px(180), h, "right")
    elseif row.kind == "toggle" then
        local w, bh = self:px(76), self:px(36)
        self:paint_text(bb, row.text, BOLD, 18, cx, y, cw - w - self:px(12), h, "left")
        self:paint_switch(bb, row, cx + cw - w, y + math.floor((h - bh) / 2), w, bh)
        self:add_hit(m, y, self.width - 2 * m, h, row.callback, true)
    elseif row.kind == "text" then
        local box = self:text_box(row)
        box:paintTo(bb, m + self:px(4), y + self:px(9))
        box:free()
    elseif row.kind == "hero" then
        -- The piece in a circle, the name and a line below it: on the ground, in a black band from the top of the screen (band), or in a card (card), with a note under them.
        local hero_y = y + math.floor((h - self:px(HEIGHTS.hero)) / 2)
        local radius = self:px(52)
        local x, w = m, self.width - 2 * m
        local fg, sub = BLACK, GRAY
        local cx, cy = math.floor(self.width / 2), hero_y + radius + self:px(4)
        if row.band then
            bb:paintRect(0, 0, self.width, y + h, BLACK)
            fg, sub = WHITE, Style.PALE
            bb:paintCircle(cx, cy, radius, WHITE)
        elseif row.card then
            local shadow = self:px(Style.CARD_SHADOW)
            Draw.card(bb, self:px(40), y + self:px(10), self.width - self:px(80) - shadow, h - self:px(20) - shadow, self.scale)
            x, w = self:px(56), self.width - self:px(112) - shadow
            hero_y = y + self:px(30)
            cy = hero_y + radius + self:px(4)
            bb:paintCircle(cx, cy, radius, BLACK)
        else
            bb:paintCircle(cx, cy, radius, WHITE)
            bb:paintCircle(cx, cy, radius, BLACK, self:px(3))
        end
        if row.piece then
            local BoardScreen = require("ink_knight/ui/board_screen")
            BoardScreen.paint_piece_fit(bb, BoardScreen.piece_set, row.piece, cx, cy, math.floor(radius * 1.3))
        else
            self:paint_text(bb, row.icon, SYMBOLS, 82, 0, cy - radius, self.width, 2 * radius, "center", row.card and WHITE or BLACK)
        end
        self:paint_text(bb, row.text, BOLD, 26, x, hero_y + self:px(116), w, self:px(40), "center", fg)
        local line = hero_y + self:px(156)
        if row.stars then
            -- Stars won of the stars there are, filled and hollow.
            local text = string.rep("\226\152\133", row.stars[1]) .. string.rep("\226\152\134", row.stars[2] - row.stars[1])
            self:paint_text(bb, text, SYMBOLS, 40, x, line, w, self:px(48), "center", fg)
            line = line + self:px(50)
        end
        self:paint_text(bb, row.detail, REGULAR, 16, x, line, w, self:px(28), "center", sub)
        if row.note then
            self:paint_text(bb, row.note, REGULAR, 14, x, line + self:px(34), w, self:px(26), "center", sub)
        end
    elseif row.kind == "state" then
        -- What a page has instead of its rows: loading, nothing to show, no connection, an error. A piece in a
        -- circle over what happened, in the middle of the room the row has.
        local inner = self.width - 2 * m
        local text_h = self:box_height(row.text, BOLD, 21, inner)
        local detail_h = row.detail and self:box_height(row.detail, REGULAR, 16, inner) + self:px(6) or 0
        local top = y + math.floor((h - self:px(150) - text_h - detail_h) / 2) + self:px(12)
        local radius = self:px(52)
        local cx = math.floor(self.width / 2)
        bb:paintCircle(cx, top + radius, radius, WHITE)
        bb:paintCircle(cx, top + radius, radius, BLACK, self:px(3))
        local BoardScreen = require("ink_knight/ui/board_screen")
        BoardScreen.paint_piece_fit(bb, BoardScreen.piece_set, row.piece or "N", cx, top + radius, math.floor(radius * 1.3))
        local box = TextBoxWidget:new{ text = row.text, face = face(BOLD, 21 * self.scale), width = inner, alignment = "center", fgcolor = BLACK, bgcolor = Style.PAPER }
        box:paintTo(bb, m, top + self:px(128))
        box:free()
        if row.detail then
            local detail = TextBoxWidget:new{ text = row.detail, face = face(REGULAR, 16 * self.scale), width = inner, alignment = "center", fgcolor = GRAY, bgcolor = Style.PAPER }
            detail:paintTo(bb, m, top + self:px(134) + text_h)
            detail:free()
        end
    elseif row.kind == "tile_line" then
        local gap = self:px(10)
        local w = math.floor((self.width - 2 * m - gap * (row.columns - 1)) / row.columns)
        for index, item in ipairs(row.items) do
            self:paint_tile(bb, item, m + (index - 1) * (w + gap), y + self:px(4), w, h - self:px(8))
        end
    else
        self:paint_nav(bb, row, y, h)
    end
    -- A whole row of a card answers a tap, not only its text.
    if carded(row) and row.callback and row.kind ~= "toggle" then
        self:add_hit(m, y, self.width - 2 * m, h, row.callback, row.keep_open)
    end
end

-- The height of a text wrapped in width, as a text box draws it.
function Page:box_height(text, name, size, width)
    local box = TextBoxWidget:new{ text = text, face = face(name, size * self.scale), width = width }
    local height = box:getSize().h
    box:free()
    return height
end

-- A question or a choice drawn over the screen, in a card: "center" in the middle, with an icon, the title, the
-- text and the answers side by side; "bottom" rising from the foot, with the title on the left, the tiles and a
-- hint. Returns its parts, each with its place from the top of the card, and the card.
function Page:dialog_parts()
    local bottom = self.dialog == "bottom"
    local m = self:px(bottom and MARGIN or 36)
    local w = self.width - 2 * m - self:px(Style.CARD_SHADOW)
    local pad = self:px(20)
    local inner = w - 2 * pad
    local parts, y = {}, pad
    local function add(part, h)
        part.y, part.h = y, h
        parts[#parts + 1] = part
        y = y + h
    end
    if not bottom and self.icon then
        add({ kind = "icon" }, self:px(68))
    end
    if self.title and self.title ~= "" then
        if bottom then
            add({ kind = "title" }, self:px(44))
        else
            add({ kind = "title" }, self:box_height(self.title, BOLD, 22, inner) + self:px(8))
        end
    end
    local buttons = {}
    for _, line in ipairs(self.lines) do
        if line.kind == "primary" or line.kind == "secondary" then
            buttons[#buttons + 1] = line
        elseif line.kind == "text" then
            add({ kind = "text", line = line }, self:box_height(line.text, REGULAR, 16, inner) + self:px(6))
        elseif line.kind == "tile_line" then
            add({ kind = "tiles", line = line }, self:base_height(line))
        else
            add({ kind = "row", line = line }, self:base_height(line))
        end
    end
    if #buttons > 0 then
        y = y + self:px(12)
        -- The answer that does nothing first, the one that acts on the right, in black.
        table.sort(buttons, function(a, b) return a.kind == "secondary" and b.kind == "primary" end)
        add({ kind = "buttons", items = buttons }, self:px(Style.BUTTON))
    end
    if self.hint then
        add({ kind = "hint" }, self:px(36))
    end
    local h = y + (self.hint and self:px(6) or pad)
    local top = bottom and (self.height - StatusStrip.height() - h - self:px(12)) or math.floor((self.height - h) / 2)
    return parts, { x = m, y = top, w = w, h = h, pad = pad, inner = inner }
end

function Page:paint_dialog(bb)
    local parts, card = self:dialog_parts()
    local shadow = self:px(Style.CARD_SHADOW)
    self.card_rect = Geom:new{ x = card.x, y = card.y, w = card.w + shadow, h = card.h + shadow }
    Draw.card(bb, card.x, card.y, card.w, card.h, self.scale)
    local x = card.x + card.pad
    for _, part in ipairs(parts) do
        local y = card.y + part.y
        if part.kind == "icon" then
            local radius = self:px(28)
            local cx = card.x + math.floor(card.w / 2)
            bb:paintCircle(cx, y + radius, radius, BLACK)
            Draw.icon(bb, self.icon, cx, y + radius, self:px(28), WHITE)
        elseif part.kind == "title" then
            if self.dialog == "bottom" then
                self:paint_text(bb, self.title, BOLD, 20, x, y, card.inner, part.h, "left")
            else
                local box = TextBoxWidget:new{ text = self.title, face = face(BOLD, 22 * self.scale), width = card.inner, alignment = "center", fgcolor = BLACK, bgcolor = WHITE }
                box:paintTo(bb, x, y)
                box:free()
            end
        elseif part.kind == "text" then
            local box = TextBoxWidget:new{ text = part.line.text, face = face(REGULAR, 16 * self.scale), width = card.inner, alignment = part.line.center == false and "left" or "center", fgcolor = GRAY, bgcolor = WHITE }
            box:paintTo(bb, x, y)
            box:free()
        elseif part.kind == "tiles" then
            local line = part.line
            local gap = self:px(10)
            local w = math.floor((card.inner - gap * (line.columns - 1)) / line.columns)
            for index, item in ipairs(line.items) do
                self:paint_tile(bb, item, x + (index - 1) * (w + gap), y + self:px(4), w, part.h - self:px(8))
            end
        elseif part.kind == "buttons" then
            local gap = self:px(12)
            local count = #part.items
            local w = math.floor((card.inner - gap * (count - 1)) / count)
            for index, item in ipairs(part.items) do
                local bx = x + (index - 1) * (w + gap)
                self:paint_pill_button(bb, bx, y, w, part.h, item.text, item.kind == "primary", item.disabled)
                self:add_hit(bx, y, w, part.h, item.callback, item.keep_open)
            end
        elseif part.kind == "hint" then
            self:paint_text(bb, self.hint, REGULAR, 14, x, y, card.inner, part.h, "center", GRAY)
        else
            self:paint_line(bb, part.line, y, part.h)
        end
    end
end

function Page:paint_footer(bb)
    local height = self:px(FOOTER_H)
    local y = self.height - StatusStrip.height() - height
    bb:paintRect(0, y, self.width, height, WHITE)
    bb:paintRect(0, y, self.width, self:px(2), BLACK)
    local count = #self.sheets
    local m = self:px(MARGIN)
    local bw, bh = self:px(80), self:px(38)
    local by = y + math.floor((height - bh) / 2) + self:px(1)
    self:paint_text(bb, string.format("%d / %d", self.sheet, count), BOLD, 17, m + bw, y, self.width - 2 * (m + bw), height, "center")
    for _, side in ipairs({ { -1, m, "previous" }, { 1, self.width - m - bw, "next" } }) do
        local active = (side[1] < 0 and self.sheet > 1) or (side[1] > 0 and self.sheet < count)
        if active then
            Draw.pill(bb, side[2], by, bw, bh, self.scale, true)
            Draw.icon(bb, side[3], side[2] + math.floor(bw / 2), by + math.floor(bh / 2), self:px(20), WHITE)
            self:add_hit(side[2] - m, y, bw + 2 * m, height, function() self:turn(side[1]) end, true)
        else
            bb:paintBorder(side[2], by, bw, bh, self:px(2), LINE, math.floor(bh / 2))
            Draw.icon(bb, side[3], side[2] + math.floor(bw / 2), by + math.floor(bh / 2), self:px(20), LINE)
        end
    end
end

-- The rows of the sheet, each group of them in its card, drawn before the rows on it.
function Page:paint_rows(bb)
    local lines = self.sheets[self.sheet] or {}
    local cursor = self:content_top()
    local card_x, card_w, inner_x, inner_w = self:card_box()
    for index, line in ipairs(lines) do
        local height = self.heights_of[line]
        local top = cursor + (line.gap_before and self:px(GAP) or 0)
        local inner_h = height - (line.gap_before and self:px(GAP) or 0) - (line.gap_after and self:px(GAP) or 0)
        if carded(line) and not carded(lines[index - 1]) then
            local card_h = inner_h
            for next_index = index + 1, #lines do
                local next_line = lines[next_index]
                if not carded(next_line) then
                    break
                end
                card_h = card_h + self.heights_of[next_line] - (next_line.gap_after and self:px(GAP) or 0)
            end
            Draw.card(bb, card_x, top, card_w, card_h, self.scale)
        end
        self:paint_line(bb, line, top, inner_h)
        local after = lines[index + 1]
        if carded(line) and carded(after) and line.kind ~= "phase" and after.kind ~= "phase" then
            bb:paintRect(inner_x, top + inner_h - 1, inner_w, Style.LINE, LINE)
        end
        cursor = cursor + height
    end
    if #self.sheets > 1 then
        self:paint_footer(bb)
    end
end

function Page:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self.hits = {}
    if self.dialog then
        local ok, err = pcall(self.paint_dialog, self, bb)
        if not ok then
            logger.warn("Ink Knight: could not draw a question", err)
        end
        if self.pressed then
            bb:invertRect(self.pressed.x, self.pressed.y, self.pressed.w, self.pressed.h)
        end
        return
    end
    bb:paintRect(0, 0, self.width, self.height, Style.PAPER)
    if self.header then
        self:paint_header(bb)
    end
    -- The rows carry what came from Lichess. If one cannot be drawn, a short message takes their place, and
    -- the way back in the header still works.
    local ok, err = pcall(self.paint_rows, self, bb)
    if not ok then
        logger.warn("Ink Knight: could not draw a page", err)
        local top = self:content_top()
        bb:paintRect(0, top, self.width, self.height - top, Style.PAPER)
        local hits = {}
        for _, hit in ipairs(self.hits) do
            if hit.y < top then
                hits[#hits + 1] = hit
            end
        end
        self.hits = hits
        self:paint_text(bb, self.broken_text or "", REGULAR, 18, self:px(MARGIN), top, self.width - 2 * self:px(MARGIN), self:px(80), "center", GRAY)
    end
    StatusStrip.paint(bb, self.width, self.height)
    if self.pressed then
        bb:invertRect(self.pressed.x, self.pressed.y, self.pressed.w, self.pressed.h)
    end
end

function Page:strip_region()
    return StatusStrip.region(self.width, self.height)
end

function Page:turn(step)
    local target = self.sheet + step
    if target >= 1 and target <= #self.sheets then
        self.sheet = target
        self:redraw()
    end
end

-- The row answers right away, in black, because what comes next can take a moment on e-ink.
function Page:press(hit)
    self.pressed = hit
    local region = Geom:new{ x = hit.x, y = hit.y, w = hit.w, h = hit.h }
    UIManager:setDirty(self, function() return Refresh.settle("fast"), region end)
    UIManager:forceRePaint()
    self.pressed = nil
    UIManager:setDirty(self, function() return "ui", region end)
    if self.close_on_tap and not hit.keep_open then
        UIManager:close(self)
    end
    hit.callback()
end

function Page:onTap(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    -- For a drawing that answers where it was tapped.
    self.tap_x = x
    for _, hit in ipairs(self.hits or {}) do
        if x >= hit.x and x < hit.x + hit.w and y >= hit.y and y < hit.y + hit.h then
            self:press(hit)
            return true
        end
    end
    -- A tap beside a question or a choice leaves it unanswered, as going back does.
    local card = self.card_rect
    if self.dialog and card and not (x >= card.x and x < card.x + card.w and y >= card.y and y < card.y + card.h) then
        self:onBack()
    end
    return true
end

function Page:onSwipe(_, ges)
    if ges.direction == "west" then
        self:turn(1)
    elseif ges.direction == "east" then
        self:turn(-1)
    end
    return true
end

-- UIManager paints a new window but leaves it to the window to ask for the screen to show it.
function Page:onShow()
    self:redraw()
    return true
end

function Page:onBack()
    if self.on_back then
        self.on_back(self)
    else
        UIManager:close(self)
    end
    return true
end

Page.onSetRotationMode = Portrait.ignore_rotation

-- KOReader sends Close to every window before it quits (USB mode on a Kobo, closing the window on a computer),
-- and before powering off, with keep_screensaver, when the window stays so the sleep screen is left alone.
function Page:onClose(arg)
    if not (arg and arg.keep_screensaver) then
        UIManager:close(self)
    end
end

-- What is underneath shows again, as one more update of the pages.
function Page:close_refresh()
    UIManager:setDirty(nil, Page.refresh_mode())
end

function Page:onCloseWidget()
    if self.on_closed then
        self.on_closed(self)
    end
    Portrait.close(self)
    self:close_refresh()
end

return Page
