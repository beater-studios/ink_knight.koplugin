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
local ffi = require("ffi")
local logger = require("logger")

local BoardDiff = require("ink_knight/board_diff")
local Page = require("ink_knight/ui/page")
local Portrait = require("ink_knight/portrait")
local Refresh = require("ink_knight/refresh")
local Sleep = require("ink_knight/sleep")
local State = require("ink_knight/state")
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
-- Only black and white, or the plain gray, so the board stays clean on e-ink. On a pattern or a darker gray,
-- a piece needs a white edge to stand out.
-- spacing and thickness grow with the screen, so a pattern looks the same on a sharper one.
local STYLES = {
    plain = { dark = DARK_SQUARE },
    newspaper = { halo = true, spacing = 5, ink = function(x, y, spacing, thickness)
        return (x + y) % spacing < thickness
    end },
    crosshatch = { halo = true, spacing = 6, ink = function(x, y, spacing, thickness)
        return (x + y) % spacing < thickness or (x - y) % spacing < thickness
    end },
    dotted = { halo = true, spacing = 6, ink = function(x, y, spacing, thickness)
        local shift = math.floor(y / spacing) % 2 == 1 and math.floor(spacing / 2) or 0
        return (x + shift) % spacing < 2 * thickness and y % spacing < 2 * thickness
    end },
    contrast = { halo = true, dark = Blitbuffer.Color8(0x55) },
}
-- The same names the saved options accept, so a saved style always has a drawing.
local STYLE_NAMES = State.OPTIONS.board_style[1]
-- "classic" is drawn from FreeSerif. The others are pictures in ink_knight/pieces, see NOTICE for their authors.
local PIECE_SET_NAMES = State.OPTIONS.piece_set[1]
local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("/ink_knight/ui/board_screen%.lua$", "")
-- The pieces of a set at a size are the same on every screen, and drawing a picture costs time on a Kindle.
local art_cache = {}

local BoardScreen = InputContainer:extend{
    name = "ink_knight_board",
    covers_fullscreen = true,
    stop_events_propagation = true,
    style = "plain",
    piece_set = "classic",
    coordinates = false,
    state = nil,
    on_square = nil,
    on_button = nil,
    on_close_request = nil,
    on_closed = nil,
    on_suspend = nil,
    on_resume = nil,
    -- Shown in place of the board when it cannot be drawn.
    broken_text = nil,
    -- Lines of text in place of the top bar, for a goal that does not fit one line, as in the lessons.
    banner_lines = nil,
}

-- The hints of the lessons: the colors of the app become grays, and the arrows that warn are black.
local SHAPE_INK = { red = BLACK, yellow = Blitbuffer.Color8(0x44) }
local HINT_INK = Blitbuffer.Color8(0x66)

local function face(name, size)
    return Font:getFace(name, size * 1000 / Screen:scaleBySize(1000))
end

-- Grows box to hold every pixel of the mask that is more than faint.
local function scan_box(box, mask)
    local data = ffi.cast("uint8_t*", mask.data)
    local stride = tonumber(mask.stride)
    for y = 0, mask:getHeight() - 1 do
        local row = data + y * stride
        for x = 0, mask:getWidth() - 1 do
            if row[x] > 40 then
                box.left, box.right = math.min(box.left or x, x), math.max(box.right or x, x)
                box.top, box.bottom = math.min(box.top or y, y), math.max(box.bottom or y, y)
            end
        end
    end
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
    local solid = render(SOLID[kind])
    local hollow = render(HOLLOW[kind])
    local box = {}
    scan_box(box, solid)
    scan_box(box, hollow)
    if not box.right then
        solid:free()
        hollow:free()
        return nil
    end
    return { solid = solid, hollow = hollow, mask = solid, x = box.left, y = box.top, w = box.right - box.left + 1, h = box.bottom - box.top + 1 }
end

-- A picture with its own colors. Its transparency becomes the mask, which gives the box and the white edge.
local function make_picture_piece(set, piece, size)
    local color = piece == piece:upper() and "w" or "b"
    local path = PLUGIN_DIR .. "/ink_knight/pieces/" .. set .. "/" .. color .. piece:upper() .. ".svg"
    local RenderImage = require("ui/renderimage")
    local ok, image = pcall(RenderImage.renderSVGImageFile, RenderImage, path, size, size)
    if not ok or not image then
        return nil
    end
    local w, h = image:getWidth(), image:getHeight()
    local mask = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    local out = ffi.cast("uint8_t*", mask.data)
    local stride = tonumber(mask.stride)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            out[y * stride + x] = image:getPixel(x, y).alpha
        end
    end
    local box = {}
    scan_box(box, mask)
    if not box.right then
        image:free()
        mask:free()
        return nil
    end
    return { image = image, mask = mask, x = box.left, y = box.top, w = box.right - box.left + 1, h = box.bottom - box.top + 1 }
end

-- The shape of the piece grown by radius on every side, in two passes so each pixel looks at a line, not a square.
local function make_halo(mask, art, radius)
    local w, h = art.w + 2 * radius, art.h + 2 * radius
    local source = ffi.cast("uint8_t*", mask.data)
    local stride = tonumber(mask.stride)
    local mask_w, mask_h = mask:getWidth(), mask:getHeight()
    local widened = ffi.new("uint8_t[?]", w * h)
    for y = 0, h - 1 do
        local source_y = art.y + y - radius
        if source_y >= 0 and source_y < mask_h then
            local row = source + source_y * stride
            for x = 0, w - 1 do
                local center = art.x + x - radius
                local best = 0
                for source_x = math.max(center - radius, 0), math.min(center + radius, mask_w - 1) do
                    if row[source_x] > best then
                        best = row[source_x]
                    end
                end
                widened[y * w + x] = best
            end
        end
    end
    local halo = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    local out = ffi.cast("uint8_t*", halo.data)
    local out_stride = tonumber(halo.stride)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local best = 0
            for near = math.max(y - radius, 0), math.min(y + radius, h - 1) do
                local value = widened[near * w + x]
                if value > best then
                    best = value
                end
            end
            out[y * out_stride + x] = best
        end
    end
    return halo
end

-- The pattern of a dark square at a size, white with the lines or dots of the style in black.
local function make_pattern(style, size, scale)
    local spacing = math.max(3, math.floor(style.spacing * scale + 0.5))
    local thickness = math.max(1, math.floor(scale + 0.5))
    local tile = Blitbuffer.new(size, size, Blitbuffer.TYPE_BB8)
    tile:paintRect(0, 0, size, size, WHITE)
    local data = ffi.cast("uint8_t*", tile.data)
    local stride = tonumber(tile.stride)
    for y = 0, size - 1 do
        for x = 0, size - 1 do
            if style.ink(x, y, spacing, thickness) then
                data[y * stride + x] = 0
            end
        end
    end
    return tile
end

-- piece is the letter of the position: upper case for white. A set whose picture fails falls back to the glyphs.
local function piece_art(set, piece, size)
    local picture = set ~= "classic"
    local key = string.format("%s:%d:%s", set, size, picture and piece or piece:lower())
    if art_cache[key] == nil then
        if picture then
            art_cache[key] = make_picture_piece(set, piece, size) or false
        else
            art_cache[key] = make_piece(piece:lower(), size * 0.86) or false
        end
    end
    if not art_cache[key] and picture then
        return piece_art("classic", piece, size)
    end
    return art_cache[key]
end

-- left and top are where the box of the piece goes, without the empty margin of its glyph or picture.
local function blit_piece(bb, art, piece, left, top)
    if art.image then
        bb:alphablitFrom(art.image, left, top, art.x, art.y, art.w, art.h)
    elseif piece == piece:upper() then
        bb:colorblitFrom(art.solid, left, top, art.x, art.y, art.w, art.h, WHITE)
        bb:colorblitFrom(art.hollow, left, top, art.x, art.y, art.w, art.h, BLACK)
    else
        bb:colorblitFrom(art.solid, left, top, art.x, art.y, art.w, art.h, BLACK)
    end
end

function BoardScreen.style_names()
    return STYLE_NAMES
end

-- Called when the plugin closes, so the pieces do not stay in memory after it. The next board draws them again.
function BoardScreen.clear_art_cache()
    for _, art in pairs(art_cache) do
        if art then
            for _, field in ipairs({ "image", "solid", "hollow", "halo" }) do
                if art[field] then
                    art[field]:free()
                end
            end
            if art.mask and art.mask ~= art.solid then
                art.mask:free()
            end
        end
    end
    art_cache = {}
end

-- For the list of styles: a light and a dark square side by side, framed like the board, at the size of the screen.
function BoardScreen.paint_style_sample(bb, name, x, y, size)
    local style = STYLES[name] or STYLES.plain
    bb:paintRect(x, y, size, size, LIGHT_SQUARE)
    if style.ink then
        local scale = math.min(Screen:getWidth() / 600, Screen:getHeight() / 800)
        local tile = make_pattern(style, size, scale)
        bb:blitFrom(tile, x + size, y, 0, 0, size, size)
        tile:free()
    else
        bb:paintRect(x + size, y, size, size, style.dark or DARK_SQUARE)
    end
    bb:paintBorder(x, y, 2 * size, size, 1, BLACK)
end

-- For the list of piece sets: the white and the black king side by side.
function BoardScreen.paint_piece_sample(bb, set, x, y, size)
    for index, piece in ipairs({ "K", "k" }) do
        local art = piece_art(set, piece, size)
        if art then
            local left = x + (index - 1) * size + math.floor((size - art.w) / 2)
            blit_piece(bb, art, piece, left, y + math.floor((size - art.h) / 2))
        end
    end
end

function BoardScreen.piece_set_names()
    return PIECE_SET_NAMES
end

-- The layout only fits portrait.
function BoardScreen:init()
    Portrait.open(self, self.setup)
end

function BoardScreen:setup()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
    Sleep.watch(self)
    self.scale = math.min(self.width / 600, self.height / 800)
    self:layout()
    self.tiles = {}
    self.labels = {}
    self.state = self.state or {}
    -- Not "refresh", which is the method that sends a change to the screen.
    self.refresh_count = Refresh.new(FULL_REFRESH_EVERY)
end

function BoardScreen:px(value)
    return math.floor(value * self.scale + 0.5)
end

function BoardScreen:layout()
    local bar_h, status_h, button_h = self:px(46), self:px(34), self:px(58)
    local top_h = self.banner_lines and self:px(24) * self.banner_lines + self:px(12) or bar_h
    local room = self.height - StatusStrip.height() - top_h - bar_h - status_h - button_h
    self.square = math.floor(math.min(self.width, room) / 8)
    local board_size = self.square * 8
    self.board_x = math.floor((self.width - board_size) / 2)
    self.top_bar = { x = 0, y = 0, w = self.width, h = top_h }
    self.board_y = top_h
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

function BoardScreen:piece(piece)
    return piece_art(self.piece_set, piece, self.square)
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

-- The pattern of a dark square, made once for the size of a square.
function BoardScreen:pattern_tile(name, style)
    if not self.tiles[name] then
        self.tiles[name] = make_pattern(style, self.square, self.scale)
    end
    return self.tiles[name]
end

function BoardScreen:halo_radius()
    return math.max(1, self:px(2))
end

function BoardScreen:halo(art)
    if not art.halo then
        art.halo = make_halo(art.mask, art, self:halo_radius())
    end
    return art.halo
end

-- A coordinate in black on a white tag, made once per screen, since the whole board is painted again at each move.
function BoardScreen:label(text)
    if not self.labels[text] then
        local pad = math.max(1, self:px(1))
        local widget = TextWidget:new{ text = text, face = face(BOLD, math.max(9, math.floor(self.square * 0.17))), fgcolor = BLACK }
        local measured = widget:getSize()
        local tag = Blitbuffer.new(measured.w + 2 * pad, measured.h, Blitbuffer.TYPE_BB8)
        tag:paintRect(0, 0, tag:getWidth(), tag:getHeight(), WHITE)
        widget:paintTo(tag, pad, 0)
        widget:free()
        self.labels[text] = tag
    end
    return self.labels[text]
end

-- In the corners, as on Lichess: the rank on the left edge and the file along the bottom, whichever way the board faces.
function BoardScreen:paint_coordinates(bb)
    local bottom_y = self.board_y + 7 * self.square
    for square = 1, 64 do
        local x, y = self:square_position(square)
        if x == self.board_x then
            local tag = self:label(tostring(math.floor((square - 1) / 8) + 1))
            bb:blitFrom(tag, x + 1, y + 1, 0, 0, tag:getWidth(), tag:getHeight())
        end
        if y == bottom_y then
            local tag = self:label(string.char(string.byte("a") + (square - 1) % 8))
            local w, h = tag:getWidth(), tag:getHeight()
            bb:blitFrom(tag, x + self.square - w - 1, y + self.square - h - 1, 0, 0, w, h)
        end
    end
end

function BoardScreen:paint_board(bb)
    local state = self.state
    local position = state.position
    local style = STYLES[self.style] or STYLES.plain
    local pattern = style.ink and self:pattern_tile(self.style, style)
    for square = 1, 64 do
        local x, y = self:square_position(square)
        local file, rank = (square - 1) % 8, math.floor((square - 1) / 8)
        local dark = (file + rank) % 2 == 0
        if dark and pattern then
            bb:blitFrom(pattern, x, y, 0, 0, self.square, self.square)
        else
            bb:paintRect(x, y, self.square, self.square, dark and (style.dark or DARK_SQUARE) or LIGHT_SQUARE)
        end
    end
    bb:paintBorder(self.board_x, self.board_y, self.square * 8, self.square * 8, 1, BLACK)
    if position then
        for square, piece in pairs(position.board) do
            local art = self:piece(piece)
            if art then
                local x, y = self:square_position(square)
                local px = x + math.floor((self.square - art.w) / 2) - art.x
                local py = y + math.floor((self.square - art.h) / 2) - art.y
                local offset_x, offset_y = px + art.x, py + art.y
                if style.halo then
                    local halo = self:halo(art)
                    local radius = self:halo_radius()
                    bb:colorblitFrom(halo, offset_x - radius, offset_y - radius, 0, 0, halo:getWidth(), halo:getHeight(), WHITE)
                end
                blit_piece(bb, art, piece, offset_x, offset_y)
            end
        end
    end
    if self.coordinates then
        self:paint_coordinates(bb)
    end
    -- After the pieces and the coordinates, so neither a white edge nor a tag covers the mark of the last move.
    if state.last_move then
        self:paint_marker(bb, state.last_move.from, self:px(3))
        self:paint_marker(bb, state.last_move.to, self:px(3))
    end
    if state.selected then
        self:paint_marker(bb, state.selected, self:px(6))
    end
    if state.highlighted_rank then
        local _, y = self:square_position((state.highlighted_rank - 1) * 8 + 1)
        bb:paintBorder(self.board_x, y, self.square * 8, self.square, self:px(4), BLACK)
    end
    if state.check_square then
        local x, y = self:square_position(state.check_square)
        bb:paintBorder(x + self:px(4), y + self:px(4), self.square - self:px(8), self.square - self:px(8), self:px(3), BLACK)
    end
    for _, shape in ipairs(state.shapes or {}) do
        self:paint_shape(bb, shape)
    end
    -- Over the arrows, which often end on them.
    for square in pairs(state.stars or {}) do
        self:paint_star(bb, square)
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

-- The banner: text over several lines, centered, smaller when it would not fit.
function BoardScreen:paint_banner(bb, rect, text)
    local pad = self:px(12)
    -- The size that fits is worked out once for each text, since the board redraws it on every move.
    self.banner_sizes = self.banner_sizes or {}
    local size = self.banner_sizes[text] or 19
    local box
    while true do
        box = TextBoxWidget:new{ text = text, face = face(REGULAR, size * self.scale), width = rect.w - 2 * pad, alignment = "center", fgcolor = BLACK, bgcolor = WHITE }
        local fits = box:getSize().h <= rect.h - self:px(4)
        if fits or size <= 13 then
            -- For the layout check: even the smallest size did not fit.
            self.banner_overflow = not fits
            self.banner_sizes[text] = size
            break
        end
        box:free()
        size = size - 1
    end
    local h = box:getSize().h
    box:paintTo(bb, rect.x + pad, rect.y + math.floor((rect.h - h) / 2))
    box:free()
    bb:paintRect(0, rect.y + rect.h - 1, self.width, 1, Blitbuffer.Color8(0xCC))
end

function BoardScreen:square_center(square)
    local x, y = self:square_position(square)
    return x + math.floor(self.square / 2), y + math.floor(self.square / 2)
end

-- A straight line, thick, by small squares along it.
local function paint_line(bb, x0, y0, x1, y1, thickness, color)
    local steps = math.max(math.abs(x1 - x0), math.abs(y1 - y0))
    local half = math.floor(thickness / 2)
    for i = 0, steps do
        local t = steps == 0 and 0 or i / steps
        bb:paintRect(math.floor(x0 + (x1 - x0) * t + 0.5) - half, math.floor(y0 + (y1 - y0) * t + 0.5) - half, thickness, thickness, color)
    end
end

-- A filled triangle, a row at a time.
local function paint_triangle(bb, points, color)
    local top, bottom = math.huge, -math.huge
    for _, p in ipairs(points) do
        top, bottom = math.min(top, p[2]), math.max(bottom, p[2])
    end
    for y = math.floor(top), math.ceil(bottom) do
        local xs = {}
        for i = 1, 3 do
            local a, b = points[i], points[i % 3 + 1]
            if (a[2] <= y and b[2] > y) or (b[2] <= y and a[2] > y) then
                xs[#xs + 1] = a[1] + (y - a[2]) * (b[1] - a[1]) / (b[2] - a[2])
            end
        end
        if #xs == 2 then
            local left, right = math.min(xs[1], xs[2]), math.max(xs[1], xs[2])
            bb:paintRect(math.floor(left), y, math.max(1, math.ceil(right - left)), 1, color)
        end
    end
end

-- An arrow from the center of one square to the edge of the head on another, or a ring on a square.
function BoardScreen:paint_shape(bb, shape)
    local color = SHAPE_INK[shape.brush] or HINT_INK
    local x0, y0 = self:square_center(shape.from)
    if not shape.to then
        local r = math.floor(self.square * 0.42)
        bb:paintCircle(x0, y0, r, color, self:px(4))
        return
    end
    local x1, y1 = self:square_center(shape.to)
    local dx, dy = x1 - x0, y1 - y0
    local length = math.sqrt(dx * dx + dy * dy)
    if length == 0 then
        return
    end
    local ux, uy = dx / length, dy / length
    local head, half_w = self.square * 0.38, self.square * 0.22
    local bx, by = x1 - ux * head, y1 - uy * head
    paint_line(bb, x0, y0, bx, by, math.max(3, self:px(7)), color)
    paint_triangle(bb, { { x1, y1 }, { bx - uy * half_w, by + ux * half_w }, { bx + uy * half_w, by - ux * half_w } }, color)
end

-- A star to collect: a white one over a larger black one, so it shows on any square.
function BoardScreen:paint_star(bb, square)
    local x, y = self:square_position(square)
    local size = math.floor(self.square * 0.62)
    self:paint_text(bb, "\226\152\133", PIECE_FONT, size * 1.3 / self.scale, x, y, self.square, self.square, "center", BLACK)
    self:paint_text(bb, "\226\152\133", PIECE_FONT, size / self.scale, x, y, self.square, self.square, "center", WHITE)
end

function BoardScreen:paint_game(bb)
    if self.banner_lines then
        self:paint_banner(bb, self.top_bar, self.state.banner or "")
    else
        self:paint_bar(bb, self.top_bar, self.state.top)
    end
    self:paint_board(bb)
    self:paint_bar(bb, self.bottom_bar, self.state.bottom)
    local rect = self.status_rect
    self:paint_text(bb, self.state.status, REGULAR, 18, self:px(10), rect.y, rect.w - self:px(20), rect.h, "center")
end

function BoardScreen:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(0, 0, self.width, self.height, WHITE)
    -- The game comes from Lichess or from a save. If it cannot be drawn, a short message takes its place, and the
    -- buttons below, with the way back, still work.
    local ok, err = pcall(self.paint_game, self, bb)
    if not ok then
        logger.warn("Ink Knight: could not draw the board", err)
        local bottom = self.buttons_rect.y
        bb:paintRect(0, 0, self.width, bottom, WHITE)
        self:paint_text(bb, self.broken_text or "", REGULAR, 18, self:px(10), 0, self.width - self:px(20), bottom, "center")
    end
    self:paint_buttons(bb)
    StatusStrip.paint(bb, self.width, self.height)
end

function BoardScreen:strip_region()
    return StatusStrip.region(self.width, self.height)
end

-- Asleep, it waits for the device to wake up, and then the whole board is drawn again.
function BoardScreen:dirty(mode, x, y, w, h)
    local region = Geom:new{ x = x, y = y, w = w, h = h }
    Sleep.dirty(self, function() return mode, region end)
end

function BoardScreen:dirty_rect(mode, rect)
    self:dirty(mode, rect.x, rect.y, rect.w, rect.h)
end

-- Sends to the screen only what changed: each square on its own, so a move does not redraw what lies between.
-- The clock changes every second when it is short, so it stays out of the count, with "fast" on its bars.
function BoardScreen:refresh(what)
    local shown = BoardDiff.snapshot(self.state)
    local changes = BoardDiff.changes(self.shown, shown)
    self.shown = shown
    if what == "clock" then
        self:dirty_rect("fast", self.top_bar)
        self:dirty_rect("fast", self.bottom_bar)
        return
    end
    if what == "full" then
        self.refresh_count:reset()
    end
    local mode = self.refresh_count:mode("cells")
    if mode == "full" or changes.whole then
        Sleep.dirty(self, function() return mode, self.dimen end)
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

-- The Back key does what the back button does: a game with a running clock asks first.
function BoardScreen:onBack()
    if self.on_close_request then
        self.on_close_request()
    else
        UIManager:close(self)
    end
    return true
end

-- KOReader sends Close to every window before it quits, and with keep_screensaver before powering off, when the
-- window stays so the sleep screen is left alone. Nothing is asked then.
function BoardScreen:onClose(arg)
    if not (arg and arg.keep_screensaver) then
        UIManager:close(self)
    end
end

-- The whole screen once when it opens, with a flash, since it comes over a page. Only after that does it send
-- what changed.
function BoardScreen:onShow()
    self.shown = BoardDiff.snapshot(self.state)
    local mode = self.refresh_count:mode("cells")
    Sleep.dirty(self, function() return mode, self.dimen end)
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

BoardScreen.onSetRotationMode = Portrait.ignore_rotation

function BoardScreen:onCloseWidget()
    for _, list in ipairs({ self.tiles, self.labels }) do
        for _, buffer in pairs(list) do
            buffer:free()
        end
    end
    self.tiles, self.labels = {}, {}
    if self.on_closed then
        self.on_closed()
    end
    Portrait.close(self)
    -- A page of the plugin shows again underneath, as one more update of the pages.
    UIManager:setDirty(nil, Page.refresh_mode())
end

return BoardScreen
