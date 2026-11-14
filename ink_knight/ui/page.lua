-- Every screen outside the board: a title with a way back, and rows laid out for a finger on e-ink.
-- Rows are plain tables, and a page that does not fit is split in sheets, turned with a swipe or the arrows.
--
-- kind nil: text, detail, value, bold, dim, callback. "game": the same, with mine for a game waiting for the reader.
-- "section": text, action_text, action. "primary" and "secondary": text, callback. "stat": text, value.
-- "toggle": text, on, on_text, off_text, callback. "text": text, center. "hero": icon, text, detail.
-- "tiles": columns, items of { text, detail, icon, callback }, and fill to grow into the room left on the page.
-- disabled, on a row or a tile: shown in gray, and tapping it does nothing.
-- preview, on a plain row: function(bb, x, y, size) drawing a sample before the text, preview_columns sizes wide.
-- "moves": number, white, black, white_current, black_current, white_callback, black_callback, as on a score sheet.
-- focus, on any row: the page opens on the sheet that holds it.
-- "buttons": items of { text, callback, primary }, side by side in equal parts, the text made smaller if it does not fit.
-- "split": text, white, draws, black, value: a move of an explorer, with a bar of how its games ended.
-- "metric": text, value, detail: a number in large, with what it is and a line below it.
-- "figures": items of { value, label }: numbers side by side over what they count, without borders.
-- "drawing": height, draw(bb, x, y, w, h): a picture of its own, the width of the page; with points and
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

local Portrait = require("ink_knight/portrait")
local Refresh = require("ink_knight/refresh")
local Sleep = require("ink_knight/sleep")
local StatusStrip = require("ink_knight/ui/status_strip")

local Screen = Device.screen

local BOLD = "noto/NotoSans-Bold.ttf"
local REGULAR = "noto/NotoSans-Regular.ttf"
local SYMBOLS = "freefont/FreeSerif.ttf"
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.Color8(0x55)
local LINE = Blitbuffer.Color8(0xBB)
local DISABLED = Blitbuffer.Color8(0x99)
local DRAW_GRAY = Blitbuffer.Color8(0xAA)

local HEADER_H, FOOTER_H, MARGIN = 66, 58, 16
-- A tile that fills the page stops growing here, so a few of them do not turn into walls.
local MAX_FILL_EXTRA = 110
local HEIGHTS = { section = 46, primary = 80, secondary = 70, stat = 50, toggle = 64, game = 76, hero = 190, moves = 48, buttons = 80, split = 58, metric = 76, figures = 82 }

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
        face = face(REGULAR, 18 * self.scale),
        width = self.width - 2 * self:px(MARGIN) - 2 * self:px(4),
        alignment = row.center and "center" or "left",
        fgcolor = BLACK,
        bgcolor = WHITE,
    }
end

-- The width the name of a row has, beside its value and chevron.
function Page:nav_text_width(row)
    local chevron_w = row.callback and self:px(24) or 0
    local value_w = row.value and row.value ~= "" and self:px(row.wide_value and 250 or 170) or 0
    return self.width - 2 * self:px(MARGIN) - chevron_w - value_w
end

-- The name of a row with wrap, on as many lines as it needs, with its detail below when it has one.
function Page:wrapped_box(row, color)
    return TextBoxWidget:new{
        text = row.text,
        face = face((row.bold and BOLD or REGULAR), 20 * self.scale),
        width = self:nav_text_width(row),
        fgcolor = color or BLACK,
        bgcolor = WHITE,
    }
end

function Page:row_height(row)
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
        return self:px(row.has_icon and 116 or (row.has_detail and 92 or 76))
    elseif HEIGHTS[row.kind] then
        return self:px(HEIGHTS[row.kind])
    end
    return self:px(row.detail and 76 or 64)
end

-- Tiles become lines, so that a sheet can end between them.
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
                end
                lines[#lines + 1] = line
            end
        else
            lines[#lines + 1] = row
        end
    end
    return lines
end

function Page:content_top()
    return self.header and self:px(HEADER_H) or 0
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
        Sleep.dirty(self, function() return Page.refresh_mode(), self.dimen end)
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

function Page:paint_header(bb)
    local height = self:px(HEADER_H)
    local back = self:px(60)
    self:paint_text(bb, "\226\128\185", BOLD, 40, 0, 0, back, height - self:px(6), "center")
    local subtitle_w = self.subtitle and self:px(170) or 0
    self:paint_text(bb, self.title, BOLD, 24, back, 0, self.width - back - subtitle_w - self:px(MARGIN), height, "left")
    if self.subtitle then
        self:paint_text(bb, self.subtitle, REGULAR, 15, self.width - subtitle_w - self:px(MARGIN), 0, subtitle_w, height, "right", GRAY)
    end
    bb:paintRect(0, height - self:px(2), self.width, self:px(2), BLACK)
    self:add_hit(0, 0, back + self:px(40), height, function() UIManager:close(self) end, true)
end

function Page:paint_nav(bb, row, y, h)
    local m = self:px(MARGIN)
    local x = m
    if row.kind == "game" and row.mine and not row.disabled then
        bb:paintRect(0, y, self:px(8), h, BLACK)
    end
    local chevron_w = row.callback and self:px(24) or 0
    local value_w = row.value and row.value ~= "" and self:px(row.wide_value and 250 or 170) or 0
    local text_w = self:nav_text_width(row)
    if row.preview then
        local size = self:px(40)
        row.preview(bb, x, y + math.floor((h - size) / 2), size)
        local used = size * (row.preview_columns or 1) + self:px(14)
        x = x + used
        text_w = text_w - used
    end
    local name = (row.bold or row.kind == "game") and BOLD or REGULAR
    local color = row.disabled and DISABLED or (row.dim and GRAY or BLACK)
    local detail_color = row.disabled and DISABLED or GRAY
    if row.wrap and not row.kind then
        local box = self:wrapped_box(row, color)
        local box_h = box:getSize().h
        if row.detail then
            local top = y + math.floor((h - box_h - self:px(22)) / 2)
            box:paintTo(bb, x, top)
            self:paint_text(bb, row.detail, REGULAR, 15, x, top + box_h, text_w, self:px(22), "left", detail_color)
        else
            box:paintTo(bb, x, y + math.floor((h - box_h) / 2))
        end
        box:free()
    elseif row.detail then
        self:paint_text(bb, row.text, name, 20, x, y + self:px(10), text_w, self:px(32), "left", color)
        self:paint_text(bb, row.detail, REGULAR, 15, x, y + self:px(41), text_w, self:px(24), "left", detail_color)
    else
        self:paint_text(bb, row.text, name, 20, x, y, text_w, h, "left", color)
    end
    if value_w > 0 then
        self:paint_text(bb, row.value, row.kind == "game" and BOLD or REGULAR, 17, self.width - m - chevron_w - value_w, y, value_w, h, "right", row.kind == "game" and color or detail_color)
    end
    if row.callback then
        self:paint_text(bb, "\226\128\186", BOLD, 28, self.width - m - chevron_w, y, chevron_w, h - self:px(4), "right", GRAY)
    end
    bb:paintRect(m, y + h - 1, self.width - 2 * m, 1, LINE)
    self:add_hit(0, y, self.width, h, row.callback, row.keep_open)
end

function Page:paint_tile(bb, item, x, y, w, h)
    local color = item.disabled and DISABLED or BLACK
    bb:paintBorder(x, y, w, h, self:px(2), item.disabled and LINE or BLACK)
    local pad = self:px(6)
    if item.icon then
        -- The icon takes what the label leaves, and the two stay together in the middle of the tile.
        local label_h = self:px(36)
        local icon_h = math.min(h - label_h - self:px(12), self:px(96))
        local cursor_y = y + math.floor((h - icon_h - label_h) / 2)
        self:paint_text(bb, item.icon, SYMBOLS, math.floor(icon_h * 0.8 / self.scale), x, cursor_y, w, icon_h, "center", color)
        self:paint_text(bb, item.text, BOLD, 18, x + pad, cursor_y + icon_h, w - 2 * pad, label_h, "center", color)
    elseif item.detail then
        self:paint_text(bb, item.text, BOLD, 24, x + pad, y + self:px(10), w - 2 * pad, self:px(38), "center", color)
        self:paint_text(bb, item.detail, REGULAR, 15, x + pad, y + self:px(48), w - 2 * pad, self:px(24), "center", item.disabled and DISABLED or GRAY)
    else
        self:paint_text(bb, item.text, BOLD, 19, x + pad, y, w - 2 * pad, h, "center", color)
    end
    self:add_hit(x, y, w, h, item.callback, item.keep_open)
end

function Page:paint_line(bb, row, y, h)
    local m = self:px(MARGIN)
    if row.kind == "section" then
        self:paint_text(bb, row.text, BOLD, 15, m, y + self:px(10), self.width - 2 * m - self:px(170), h - self:px(10), "left", GRAY)
        if row.action_text then
            local action_w = self:px(170)
            self:paint_text(bb, row.action_text, BOLD, 16, self.width - m - action_w, y + self:px(10), action_w, h - self:px(10), "right")
            self:add_hit(self.width - m - action_w - self:px(20), y, action_w + m + self:px(20), h, row.action, true)
        end
    elseif row.kind == "primary" or row.kind == "secondary" then
        local gap = self:px(8)
        local bh = h - 2 * gap
        local solid = row.kind == "primary" and not row.disabled
        if solid then
            bb:paintRect(m, y + gap, self.width - 2 * m, bh, BLACK)
        else
            bb:paintBorder(m, y + gap, self.width - 2 * m, bh, self:px(2), row.disabled and LINE or BLACK)
        end
        self:paint_text(bb, row.text, BOLD, 20, m, y + gap, self.width - 2 * m, bh, "center", solid and WHITE or (row.disabled and DISABLED or BLACK))
        self:add_hit(m, y + gap, self.width - 2 * m, bh, row.callback, row.keep_open)
    elseif row.kind == "buttons" then
        local gap = self:px(8)
        local count = #row.items
        local w = math.floor((self.width - 2 * m - gap * (count - 1)) / count)
        local bh = h - 2 * gap
        for index, item in ipairs(row.items) do
            local x = m + (index - 1) * (w + gap)
            local solid = item.primary and not item.disabled
            if solid then
                bb:paintRect(x, y + gap, w, bh, BLACK)
            else
                bb:paintBorder(x, y + gap, w, bh, self:px(2), item.disabled and LINE or BLACK)
            end
            local pad = self:px(10)
            local size = self:fitting_size(item.text, BOLD, 20, 14, w - 2 * pad)
            self:paint_text(bb, item.text, BOLD, size, x + pad, y + gap, w - 2 * pad, bh, "center", solid and WHITE or (item.disabled and DISABLED or BLACK))
            self:add_hit(x, y + gap, w, bh, item.callback, item.keep_open)
        end
    elseif row.kind == "moves" then
        local number_w, column_w = self:px(80), self:px(200)
        self:paint_text(bb, row.number, REGULAR, 18, m, y, number_w, h, "left", GRAY)
        for index, side in ipairs({ "white", "black" }) do
            local x = m + number_w + (index - 1) * column_w
            local text = row[side]
            if text then
                local current = row[side .. "_current"]
                if current then
                    bb:paintRect(x, y + self:px(6), column_w - self:px(12), h - self:px(12), BLACK)
                end
                self:paint_text(bb, text, BOLD, 20, x + self:px(10), y, column_w - self:px(32), h, "left", current and WHITE or BLACK)
                self:add_hit(x, y, column_w, h, row[side .. "_callback"])
            end
        end
        bb:paintRect(m, y + h - 1, self.width - 2 * m, 1, LINE)
    elseif row.kind == "split" then
        -- A move of an explorer: its name, a bar of how its games ended (white, draws, black, as on Lichess) and
        -- how many games.
        local name_w, value_w, gap = self:px(110), self:px(90), self:px(12)
        self:paint_text(bb, row.text, BOLD, 20, m, y, name_w - self:px(8), h, "left")
        local bar_x, bar_w = m + name_w, self.width - 2 * m - name_w - value_w - gap
        local bar_h = self:px(32)
        local bar_y = y + math.floor((h - bar_h) / 2)
        local total = math.max(1, row.white + row.draws + row.black)
        -- Each part ends where the games so far end, rounded once, so the parts fill the bar exactly.
        local x, counted = bar_x, 0
        for _, part in ipairs({ { row.white, WHITE, BLACK }, { row.draws, DRAW_GRAY, BLACK }, { row.black, BLACK, WHITE } }) do
            counted = counted + part[1]
            local w = bar_x + math.floor(bar_w * counted / total + 0.5) - x
            if w > 0 then
                bb:paintRect(x, bar_y, w, bar_h, part[2])
                if w >= self:px(48) then
                    self:paint_text(bb, string.format("%d%%", math.floor(part[1] / total * 100 + 0.5)), BOLD, 15, x, bar_y, w, bar_h, "center", part[3])
                end
            end
            x = x + w
        end
        bb:paintBorder(bar_x, bar_y, bar_w, bar_h, self:px(2), BLACK)
        self:paint_text(bb, row.value, REGULAR, 16, self.width - m - value_w, y, value_w, h, "right", GRAY)
        bb:paintRect(m, y + h - 1, self.width - 2 * m, 1, LINE)
    elseif row.kind == "drawing" then
        local w = self.width - 2 * m
        row.draw(bb, m, y, w, h)
        if row.points and row.on_point then
            self:add_hit(m, y, w, h, function()
                local tap_x = self.tap_x or m
                row.on_point(math.max(0, math.min(row.points, math.floor((tap_x - m) / w * row.points + 0.5))))
            end)
        end
    elseif row.kind == "figures" then
        -- Numbers side by side, each over what it counts; not buttons, so no borders.
        local count = #row.items
        local w = math.floor((self.width - 2 * m) / count)
        local pad = self:px(4)
        for index, item in ipairs(row.items) do
            local x = m + (index - 1) * w
            if index > 1 then
                bb:paintRect(x, y + self:px(14), 1, h - self:px(28), LINE)
            end
            self:paint_text(bb, item.value, BOLD, 26, x + pad, y + self:px(8), w - 2 * pad, self:px(40), "center")
            self:paint_text(bb, item.label, REGULAR, 14, x + pad, y + self:px(48), w - 2 * pad, self:px(24), "center", GRAY)
        end
        bb:paintRect(m, y + h - 1, self.width - 2 * m, 1, LINE)
    elseif row.kind == "metric" then
        -- A number that matters, large, with what it is beside it.
        local value_w = self:px(140)
        if row.detail then
            self:paint_text(bb, row.text, REGULAR, 20, m, y + self:px(10), self.width - 2 * m - value_w, self:px(32), "left")
            self:paint_text(bb, row.detail, REGULAR, 15, m, y + self:px(42), self.width - 2 * m - value_w, self:px(24), "left", GRAY)
        else
            self:paint_text(bb, row.text, REGULAR, 20, m, y, self.width - 2 * m - value_w, h, "left")
        end
        self:paint_text(bb, row.value, BOLD, 34, self.width - m - value_w, y, value_w, h, "right")
        bb:paintRect(m, y + h - 1, self.width - 2 * m, 1, LINE)
    elseif row.kind == "stat" then
        self:paint_text(bb, row.text, REGULAR, 18, m, y, self.width - 2 * m - self:px(180), h, "left")
        self:paint_text(bb, row.value, BOLD, 18, self.width - m - self:px(180), y, self:px(180), h, "right")
        bb:paintRect(m, y + h - 1, self.width - 2 * m, 1, LINE)
    elseif row.kind == "toggle" then
        self:paint_text(bb, row.text, REGULAR, 20, m, y, self.width - 2 * m - self:px(90), h, "left")
        local w, bh = self:px(76), self:px(38)
        local bx, by = self.width - m - w, y + math.floor((h - bh) / 2)
        if row.on then
            bb:paintRect(bx, by, w, bh, BLACK)
        else
            bb:paintBorder(bx, by, w, bh, self:px(2), BLACK)
        end
        self:paint_text(bb, row.on and row.on_text or row.off_text, BOLD, 16, bx, by, w, bh, "center", row.on and WHITE or BLACK)
        bb:paintRect(m, y + h - 1, self.width - 2 * m, 1, LINE)
        self:add_hit(0, y, self.width, h, row.callback, true)
    elseif row.kind == "text" then
        local box = self:text_box(row)
        box:paintTo(bb, m + self:px(4), y + self:px(9))
        box:free()
    elseif row.kind == "hero" then
        local hero_y = y + math.floor((h - self:px(HEIGHTS.hero)) / 2)
        self:paint_text(bb, row.icon, SYMBOLS, 92, 0, hero_y + self:px(8), self.width, self:px(108), "center")
        self:paint_text(bb, row.text, BOLD, 28, m, hero_y + self:px(116), self.width - 2 * m, self:px(40), "center")
        self:paint_text(bb, row.detail, REGULAR, 16, m, hero_y + self:px(156), self.width - 2 * m, self:px(28), "center", GRAY)
    elseif row.kind == "tile_line" then
        local gap = self:px(8)
        local w = math.floor((self.width - 2 * m - gap * (row.columns - 1)) / row.columns)
        for index, item in ipairs(row.items) do
            self:paint_tile(bb, item, m + (index - 1) * (w + gap), y + math.floor(gap / 2), w, h - gap)
        end
    else
        self:paint_nav(bb, row, y, h)
    end
end

function Page:paint_footer(bb)
    local height = self:px(FOOTER_H)
    local y = self.height - StatusStrip.height() - height
    bb:paintRect(0, y, self.width, 1, LINE)
    local arrow = math.floor(self.width / 3)
    local count = #self.sheets
    self:paint_text(bb, string.format("%d / %d", self.sheet, count), REGULAR, 17, arrow, y, arrow, height, "center")
    if self.sheet > 1 then
        self:paint_text(bb, "\226\128\185", BOLD, 34, 0, y, arrow, height - self:px(6), "center")
        self:add_hit(0, y, arrow, height, function() self:turn(-1) end, true)
    end
    if self.sheet < count then
        self:paint_text(bb, "\226\128\186", BOLD, 34, 2 * arrow, y, arrow, height - self:px(6), "center")
        self:add_hit(2 * arrow, y, arrow, height, function() self:turn(1) end, true)
    end
end

function Page:paint_rows(bb)
    local cursor = self:content_top()
    for _, line in ipairs(self.sheets[self.sheet] or {}) do
        local height = self.heights_of[line]
        self:paint_line(bb, line, cursor, height)
        cursor = cursor + height
    end
    if #self.sheets > 1 then
        self:paint_footer(bb)
    end
end

function Page:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self.hits = {}
    bb:paintRect(0, 0, self.width, self.height, WHITE)
    if self.header then
        self:paint_header(bb)
    end
    -- The rows carry what came from Lichess. If one cannot be drawn, a short message takes their place, and
    -- the way back in the header still works.
    local ok, err = pcall(self.paint_rows, self, bb)
    if not ok then
        logger.warn("Ink Knight: could not draw a page", err)
        local top = self:content_top()
        bb:paintRect(0, top, self.width, self.height - top, WHITE)
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
    UIManager:setDirty(self, function() return "fast", region end)
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
