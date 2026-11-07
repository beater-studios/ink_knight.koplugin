-- Every screen outside the board: a title with a way back, and rows laid out for a finger on e-ink.
-- Rows are plain tables, and a page that does not fit is split in sheets, turned with a swipe or the arrows.
--
-- kind nil: text, detail, value, bold, dim, callback. "game": the same, with mine for a game waiting for the reader.
-- "section": text, action_text, action. "primary" and "secondary": text, callback. "stat": text, value.
-- "toggle": text, on, on_text, off_text, callback. "text": text, center. "hero": icon, text, detail.
-- "tiles": columns, items of { text, detail, icon, callback }, and fill to grow into the room left on the page.
-- disabled, on a row or a tile: shown in gray, and tapping it does nothing.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")

local StatusStrip = require("ink_knight/ui/status_strip")

local Screen = Device.screen

local BOLD = "noto/NotoSans-Bold.ttf"
local REGULAR = "noto/NotoSans-Regular.ttf"
local SYMBOLS = "freefont/FreeSerif.ttf"
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.Color8(0x55)
local LINE = Blitbuffer.Color8(0xBB)
local DISABLED = Blitbuffer.Color8(0x99)

local HEADER_H, FOOTER_H, MARGIN = 66, 58, 16
-- A tile that fills the page stops growing here, so a few of them do not turn into walls.
local MAX_FILL_EXTRA = 110
local HEIGHTS = { section = 46, primary = 80, secondary = 70, stat = 50, toggle = 64, game = 76, hero = 190 }

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
}

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
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.scale = math.min(self.width / 600, self.height / 800)
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self.sheet = 1
    self:reload(true)
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

function Page:row_height(row)
    if row.kind == "text" then
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
        UIManager:setDirty(self, function() return "ui", self.dimen end)
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
    local text_w = self.width - 2 * m - chevron_w - value_w
    local name = (row.bold or row.kind == "game") and BOLD or REGULAR
    local color = row.disabled and DISABLED or (row.dim and GRAY or BLACK)
    local detail_color = row.disabled and DISABLED or GRAY
    if row.detail then
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

function Page:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self.hits = {}
    bb:paintRect(0, 0, self.width, self.height, WHITE)
    if self.header then
        self:paint_header(bb)
    end
    local cursor = self:content_top()
    for _, line in ipairs(self.sheets[self.sheet] or {}) do
        local height = self.heights_of[line]
        self:paint_line(bb, line, cursor, height)
        cursor = cursor + height
    end
    if #self.sheets > 1 then
        self:paint_footer(bb)
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
        UIManager:setDirty(self, function() return "ui", self.dimen end)
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
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function Page:onClose()
    UIManager:close(self)
    return true
end

function Page:onCloseWidget()
    if self.on_closed then
        self.on_closed(self)
    end
    UIManager:setDirty(nil, "ui")
end

return Page
