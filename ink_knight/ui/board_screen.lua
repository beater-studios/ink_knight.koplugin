-- The board and what surrounds it, shared by every mode. It only draws what it is told and reports taps.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local bit = require("bit")
local ffi = require("ffi")

local BoardDiff = require("ink_knight/board_diff")
local StatusStrip = require("ink_knight/ui/status_strip")

local Screen = Device.screen

-- A full flash now and then clears what e-ink leaves behind, and it is rare because each move touches little.
local FULL_REFRESH_EVERY = 40
-- Past this many separate squares, one update of the board is quicker than many small ones.
local MAX_SEPARATE_SQUARES = 24
local BOLD = "noto/NotoSans-Bold.ttf"
local REGULAR = "noto/NotoSans-Regular.ttf"
local PIECE_FONT = "freefont/FreeSerif.ttf"
local LIGHT_SQUARE, DARK_SQUARE = Blitbuffer.COLOR_WHITE, Blitbuffer.Color8(0xAA)
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
-- The solid chess symbols give the shape of a piece, and the hollow ones draw its outline.
local SOLID = { k = "\226\153\154", q = "\226\153\155", r = "\226\153\156", b = "\226\153\157", n = "\226\153\158", p = "\226\153\159" }
local HOLLOW = { k = "\226\153\148", q = "\226\153\149", r = "\226\153\150", b = "\226\153\151", n = "\226\153\152", p = "\226\153\153" }

local BoardScreen = InputContainer:extend{
    name = "ink_knight_board",
    covers_fullscreen = true,
    stop_events_propagation = true,
    state = nil,
    on_square = nil,
    on_button = nil,
    on_close_request = nil,
    on_closed = nil,
    on_suspend = nil,
    on_resume = nil,
}

local function face(name, size)
    return Font:getFace(name, size * 1000 / Screen:scaleBySize(1000))
end

-- Both glyphs of a piece, cut to the same box, so the outline falls exactly over the fill.
local function make_piece(kind, size)
    local function render(char)
        local widget = TextWidget:new{ text = char, face = face(PIECE_FONT, size), fgcolor = WHITE }
        local measured = widget:getSize()
        local mask = Blitbuffer.new(measured.w, measured.h, Blitbuffer.TYPE_BB8)
        mask:paintRect(0, 0, measured.w, measured.h, BLACK)
        widget:paintTo(mask, 0, 0)
        widget:free()
        return mask, measured.w, measured.h
    end
    local solid, sw, sh = render(SOLID[kind])
    local hollow, hw, hh = render(HOLLOW[kind])
    local left, top, right, bottom = math.huge, math.huge, -1, -1
    local function scan(mask, w, h)
        local data = ffi.cast("uint8_t*", mask.data)
        for y = 0, h - 1 do
            local row = data + y * mask.stride
            for x = 0, w - 1 do
                if row[x] > 40 then
                    left, right = math.min(left, x), math.max(right, x)
                    top, bottom = math.min(top, y), math.max(bottom, y)
                end
            end
        end
    end
    scan(solid, sw, sh)
    scan(hollow, hw, hh)
    if right < 0 then
        solid:free()
        hollow:free()
        return nil
    end
    return { solid = solid, hollow = hollow, x = left, y = top, w = right - left + 1, h = bottom - top + 1 }
end

function BoardScreen:init()
    -- The layout only fits portrait, and odd rotation modes are landscape.
    local rotation = Screen:getRotationMode()
    if bit.band(rotation, 1) == 1 then
        self.restore_rotation = rotation
        Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
    end
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self.scale = math.min(self.width / 600, self.height / 800)
    self:layout()
    self.pieces = {}
    self.state = self.state or {}
    self.refreshes = 0
end

function BoardScreen:px(value)
    return math.floor(value * self.scale + 0.5)
end

function BoardScreen:layout()
    local bar_h, status_h, button_h = self:px(46), self:px(34), self:px(58)
    local room = self.height - StatusStrip.height() - 2 * bar_h - status_h - button_h
    self.square = math.floor(math.min(self.width, room) / 8)
    local board_size = self.square * 8
    self.board_x = math.floor((self.width - board_size) / 2)
    self.top_bar = { x = 0, y = 0, w = self.width, h = bar_h }
    self.board_y = bar_h
    self.board_rect = Geom:new{ x = self.board_x, y = self.board_y, w = board_size, h = board_size }
    self.bottom_bar = { x = 0, y = self.board_y + board_size, w = self.width, h = bar_h }
    self.status_rect = { x = 0, y = self.bottom_bar.y + bar_h, w = self.width, h = status_h }
    self.buttons_rect = { x = 0, y = self.status_rect.y + status_h, w = self.width, h = button_h }
end

function BoardScreen:square_position(square)
    local file, rank = (square - 1) % 8, math.floor((square - 1) / 8)
    if self.state.flipped then
        file, rank = 7 - file, rank
    else
        rank = 7 - rank
    end
    return self.board_x + file * self.square, self.board_y + rank * self.square
end

function BoardScreen:square_at(x, y)
    local file = math.floor((x - self.board_x) / self.square)
    local row = math.floor((y - self.board_y) / self.square)
    if file < 0 or file > 7 or row < 0 or row > 7 then
        return nil
    end
    if self.state.flipped then
        return row * 8 + (7 - file) + 1
    end
    return (7 - row) * 8 + file + 1
end

function BoardScreen:piece(kind)
    if self.pieces[kind] == nil then
        self.pieces[kind] = make_piece(kind, self.square * 0.86) or false
    end
    return self.pieces[kind]
end

function BoardScreen:paint_text(bb, text, name, size, x, y, w, h, align, color)
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

function BoardScreen:paint_bar(bb, rect, info)
    if not info then
        return
    end
    local pad = self:px(10)
    local clock_w = self:px(120)
    self:paint_text(bb, info.name, BOLD, 20, rect.x + pad, rect.y, rect.w - clock_w - 3 * pad, rect.h, "left")
    if info.clock and info.clock ~= "" then
        local x = rect.x + rect.w - clock_w - pad
        local y, h = rect.y + self:px(5), rect.h - self:px(10)
        -- Rounded, because buttons here have square corners and a clock cannot be tapped.
        local radius = math.floor(h / 2)
        if info.active then
            bb:paintRoundedRect(x, y, clock_w, h, BLACK, radius)
        else
            bb:paintBorder(x, y, clock_w, h, self:px(2), BLACK, radius)
        end
        self:paint_text(bb, info.clock, BOLD, 24, x, y, clock_w, h, "center", info.active and WHITE or BLACK)
    end
end

function BoardScreen:paint_marker(bb, square, thickness)
    local x, y = self:square_position(square)
    bb:paintBorder(x, y, self.square, self.square, thickness, BLACK)
end

function BoardScreen:paint_board(bb)
    local state = self.state
    local position = state.position
    for square = 1, 64 do
        local x, y = self:square_position(square)
        local file, rank = (square - 1) % 8, math.floor((square - 1) / 8)
        bb:paintRect(x, y, self.square, self.square, (file + rank) % 2 == 0 and DARK_SQUARE or LIGHT_SQUARE)
    end
    bb:paintBorder(self.board_x, self.board_y, self.square * 8, self.square * 8, 1, BLACK)
    if state.last_move then
        self:paint_marker(bb, state.last_move.from, self:px(3))
        self:paint_marker(bb, state.last_move.to, self:px(3))
    end
    if position then
        for square, piece in pairs(position.board) do
            local art = self:piece(piece:lower())
            if art then
                local x, y = self:square_position(square)
                local px = x + math.floor((self.square - art.w) / 2) - art.x
                local py = y + math.floor((self.square - art.h) / 2) - art.y
                local offset_x, offset_y = px + art.x, py + art.y
                if piece == piece:upper() then
                    bb:colorblitFrom(art.solid, offset_x, offset_y, art.x, art.y, art.w, art.h, WHITE)
                    bb:colorblitFrom(art.hollow, offset_x, offset_y, art.x, art.y, art.w, art.h, BLACK)
                else
                    bb:colorblitFrom(art.solid, offset_x, offset_y, art.x, art.y, art.w, art.h, BLACK)
                end
            end
        end
    end
    if state.selected then
        self:paint_marker(bb, state.selected, self:px(6))
    end
    for square in pairs(state.targets or {}) do
        local x, y = self:square_position(square)
        local r = math.floor(self.square * 0.16)
        local cx, cy = x + math.floor(self.square / 2), y + math.floor(self.square / 2)
        bb:paintCircle(cx, cy, r + self:px(3), WHITE)
        bb:paintCircle(cx, cy, r, BLACK)
    end
end

function BoardScreen:button_rects()
    local buttons = self.state.buttons or {}
    local count = #buttons
    local rects = {}
    if count == 0 then
        return rects
    end
    local gap = self:px(6)
    local pad = self:px(6)
    local w = math.floor((self.width - 2 * pad - gap * (count - 1)) / count)
    local rect = self.buttons_rect
    for index, button in ipairs(buttons) do
        rects[index] = { id = button.id, label = button.label, x = pad + (index - 1) * (w + gap), y = rect.y + self:px(5), w = w, h = rect.h - self:px(10) }
    end
    return rects
end

function BoardScreen:paint_buttons(bb)
    for _, rect in ipairs(self:button_rects()) do
        bb:paintBorder(rect.x, rect.y, rect.w, rect.h, self:px(2), BLACK)
        local box = TextBoxWidget:new{
            text = rect.label,
            face = face(BOLD, 17 * self.scale),
            width = rect.w - self:px(8),
            alignment = "center",
            fgcolor = BLACK,
            bgcolor = WHITE,
        }
        local measured = box:getSize()
        box:paintTo(bb, rect.x + self:px(4), rect.y + math.floor((rect.h - measured.h) / 2))
        box:free()
    end
end

function BoardScreen:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(0, 0, self.width, self.height, WHITE)
    self:paint_bar(bb, self.top_bar, self.state.top)
    self:paint_board(bb)
    self:paint_bar(bb, self.bottom_bar, self.state.bottom)
    local rect = self.status_rect
    self:paint_text(bb, self.state.status, REGULAR, 18, self:px(10), rect.y, rect.w - self:px(20), rect.h, "center")
    self:paint_buttons(bb)
    StatusStrip.paint(bb, self.width, self.height)
end

function BoardScreen:strip_region()
    return StatusStrip.region(self.width, self.height)
end

function BoardScreen:dirty(mode, x, y, w, h)
    local region = Geom:new{ x = x, y = y, w = w, h = h }
    UIManager:setDirty(self, function() return mode, region end)
end

function BoardScreen:dirty_rect(mode, rect)
    self:dirty(mode, rect.x, rect.y, rect.w, rect.h)
end

-- Sends to the screen only what changed: each square on its own, so a move does not redraw what lies between.
function BoardScreen:refresh(what)
    local shown = BoardDiff.snapshot(self.state)
    local changes = BoardDiff.changes(self.shown, shown)
    self.shown = shown
    if what == "clock" then
        self:dirty_rect("fast", self.top_bar)
        self:dirty_rect("fast", self.bottom_bar)
        return
    end
    self.refreshes = self.refreshes + 1
    local flash = what == "full" or self.refreshes % FULL_REFRESH_EVERY == 0
    if flash or changes.whole then
        UIManager:setDirty(self, function() return flash and "full" or "ui", self.dimen end)
        return
    end
    if #changes.squares > MAX_SEPARATE_SQUARES then
        self:dirty("ui", self.board_x, self.board_y, self.square * 8, self.square * 8)
    else
        for _, square in ipairs(changes.squares) do
            local x, y = self:square_position(square)
            self:dirty("ui", x, y, self.square, self.square)
        end
    end
    if changes.top then self:dirty_rect("ui", self.top_bar) end
    if changes.bottom then self:dirty_rect("ui", self.bottom_bar) end
    if changes.status then self:dirty_rect("ui", self.status_rect) end
    if changes.buttons then self:dirty_rect("ui", self.buttons_rect) end
end

-- Replaces everything shown. What is left out disappears, such as the marks of a square no longer selected.
function BoardScreen:show(state, what)
    self.state = state
    self:refresh(what)
end

function BoardScreen:onTap(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    for _, rect in ipairs(self:button_rects()) do
        if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
            if self.on_button then
                self.on_button(rect.id)
            end
            return true
        end
    end
    local square = self:square_at(x, y)
    if square and self.on_square then
        self.on_square(square)
    end
    return true
end

function BoardScreen:onClose()
    if self.on_close_request then
        self.on_close_request()
    else
        UIManager:close(self)
    end
    return true
end

-- The whole screen once when it opens. Only after that does it send what changed.
function BoardScreen:onShow()
    self.shown = BoardDiff.snapshot(self.state)
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    return true
end

function BoardScreen:onSuspend()
    if self.on_suspend then
        self.on_suspend()
    end
end

function BoardScreen:onResume()
    if self.on_resume then
        self.on_resume()
    end
end

function BoardScreen:onSetRotationMode()
    return true
end

function BoardScreen:onCloseWidget()
    for _, art in pairs(self.pieces) do
        if art then
            art.solid:free()
            art.hollow:free()
        end
    end
    self.pieces = {}
    if self.on_closed then
        self.on_closed()
    end
    if self.restore_rotation then
        Screen:setRotationMode(self.restore_rotation)
    end
    UIManager:setDirty(nil, "ui")
end

return BoardScreen
