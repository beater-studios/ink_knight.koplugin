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
local Material = require("ink_knight/material")
local Draw = require("ink_knight/ui/draw")
local MoveText = require("ink_knight/ui/move_text")
local Page = require("ink_knight/ui/page")
local Portrait = require("ink_knight/portrait")
local Refresh = require("ink_knight/refresh")
local Sleep = require("ink_knight/sleep")
local State = require("ink_knight/state")
local StatusStrip = require("ink_knight/ui/status_strip")
local Style = require("ink_knight/ui/style")

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
local function rgb(r, g, b)
    return Blitbuffer.ColorRGB32(r, g, b, 0xFF)
end
-- Only black and white, or the plain gray, so the board stays clean on e-ink. On a pattern or a darker gray,
-- a piece needs a white edge to stand out.
-- spacing and thickness grow with the screen, so a pattern looks the same on a sharper one.
-- The colored styles (color) are only drawn on a screen that shows color (State.board_style). Color e-ink washes colors out, so they are lighter on the light squares and of a stronger hue on the dark ones than the boards of Lichess, whose colors turn almost gray there.
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
    wood = { color = true, light = rgb(0xF8, 0xE6, 0xC4), dark = rgb(0xD0, 0x8F, 0x50) },
    green = { color = true, light = rgb(0xF1, 0xF4, 0xD6), dark = rgb(0x6D, 0xB0, 0x4A) },
    blue = { color = true, light = rgb(0xE8, 0xF0, 0xF6), dark = rgb(0x6F, 0xA2, 0xD0) },
}

-- A square of a style. paintRect draws any color in gray, even on a color screen, so a colored style goes through paintRectRGB32.
local function paint_square(bb, style, x, y, w, h, dark)
    local color = dark and (style.dark or DARK_SQUARE) or (style.light or LIGHT_SQUARE)
    if style.color then
        bb:paintRectRGB32(x, y, w, h, color)
    else
        bb:paintRect(x, y, w, h, color)
    end
end
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
    -- The line of text under the plates; a mode that says everything in its plates turns it off for a larger board.
    status_line = true,
    -- A board being read (a review, a study): the last move shows, with corners where it came from and a frame where
    -- it went. In a game nothing marks it. state.reading does the same for one state.
    read_marks = false,
    -- The layout of a review: the players in a black band on top (state.band), a bar of the evaluation beside the board (state.eval), and the panel of the move below it in place of the plates.
    band = false,
    -- A line over the text of the banner, for where it comes from (state.banner_title), and the button a tap on the banner presses, such as reading it whole.
    banner_heading = false,
    banner_tap = nil,
    -- The layout of the editor: the title in a black band (state.header: title, subtitle), and the pieces to put under the board (state.palette: selected, a piece letter or "erase"), whose taps press "tool:<letter>" and "tool:erase".
    palette = false,
    -- Beside each player, what that side has more than the other, and "+n" for the side ahead, as on Lichess: where a game is played or read. Worked out from the position shown (shown_material).
    material = false,
}

-- The arrows and circles of the lessons in two inks: black for the ones that warn, dark gray for the others.
local SHAPE_INK = { red = BLACK }
local HINT_INK = Blitbuffer.Color8(0x55)
local PROGRESS_FILL = Blitbuffer.Color8(0xBB)

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

-- The white edge of a piece, made once for its art: the radius is the same everywhere on one screen (2 px of a screen 600 wide), so the board, the cover and the samples share it.
local function cached_halo(art, radius)
    if not art.halo then
        art.halo = make_halo(art.mask, art, radius)
    end
    return art.halo
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

-- Whether the boards are drawn in color now, a colored style being in use, which Home:apply_board_look only sets on a screen that shows color. KOReader uses the color modes of the panel only for what is marked as dithered.
function BoardScreen.in_color()
    return (STYLES[BoardScreen.style] or STYLES.plain).color == true
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

-- For the list of styles and the row of the settings: a light and a dark square of the style, apart, each framed,
-- two elements large enough to tell on e-ink. dim: faded, for a style that cannot be chosen here.
function BoardScreen.paint_style_sample(bb, name, x, y, size, with_pieces, dim)
    local style = STYLES[name] or STYLES.plain
    local scale = math.min(Screen:getWidth() / 600, Screen:getHeight() / 800)
    local gap = math.max(2, math.floor(size / 6))
    local side = size - math.floor(gap / 2)
    local border = math.max(1, math.floor(2 * scale + 0.5))
    local top = y + math.floor((size - side) / 2)
    local dark_x = x + side + gap
    paint_square(bb, style, x, top, side, side, false)
    if style.ink then
        local tile = make_pattern(style, side, scale)
        bb:blitFrom(tile, dark_x, top, 0, 0, side, side)
        tile:free()
    else
        paint_square(bb, style, dark_x, top, side, side, true)
    end
    bb:paintBorder(x, top, side, side, border, BLACK)
    bb:paintBorder(dark_x, top, side, side, border, BLACK)
    if with_pieces then
        -- A knight of each color, the black one on the dark square, where a style is hardest to read.
        for _, sample in ipairs({ { "N", x }, { "n", dark_x } }) do
            local art = piece_art(BoardScreen.piece_set, sample[1], side)
            if art then
                local px, py = sample[2] + math.floor((side - art.w) / 2), top + math.floor((side - art.h) / 2)
                if style.halo then
                    local radius = math.max(1, math.floor(2 * scale + 0.5))
                    local halo = cached_halo(art, radius)
                    bb:colorblitFrom(halo, px - radius, py - radius, 0, 0, halo:getWidth(), halo:getHeight(), WHITE)
                end
                blit_piece(bb, art, sample[1], px, py)
            end
        end
    end
    if dim then
        bb:lightenRect(x, top, dark_x + side - x, side, 0.6)
    end
end

-- One piece of a set (piece as "N" or "n"), centered in a square of size at x, y: for the plates and pictures of the redesign.
function BoardScreen.paint_piece(bb, set, piece, x, y, size)
    local art = piece_art(set, piece, size)
    if art then
        blit_piece(bb, art, piece, x + math.floor((size - art.w) / 2), y + math.floor((size - art.h) / 2))
    end
end

-- A still board anywhere, in the style and pieces chosen, in its black frame with the coordinates: for the cover of the sleep screen. position as Chess.parse_fen gives it; flipped with black at the bottom.
function BoardScreen.paint_board_at(bb, position, x, y, size, flipped)
    local scale = math.min(Screen:getWidth() / 600, Screen:getHeight() / 800)
    local style = STYLES[BoardScreen.style] or STYLES.plain
    local square = math.floor(size / 8)
    size = square * 8
    local frame = math.floor(18 * scale + 0.5)
    bb:paintRoundedRect(x - frame, y - frame, size + 2 * frame, size + 2 * frame, BLACK, math.floor(14 * scale + 0.5))
    local pattern = style.ink and make_pattern(style, square, scale)
    local function place(sq)
        local file, rank = (sq - 1) % 8, math.floor((sq - 1) / 8)
        if flipped then
            return x + (7 - file) * square, y + rank * square
        end
        return x + file * square, y + (7 - rank) * square
    end
    for sq = 1, 64 do
        local sx, sy = place(sq)
        local file, rank = (sq - 1) % 8, math.floor((sq - 1) / 8)
        if (file + rank) % 2 == 0 and pattern then
            bb:blitFrom(pattern, sx, sy, 0, 0, square, square)
        else
            paint_square(bb, style, sx, sy, square, square, (file + rank) % 2 == 0)
        end
    end
    if pattern then
        pattern:free()
    end
    local radius = math.max(1, math.floor(2 * scale + 0.5))
    for sq, piece in pairs(position and position.board or {}) do
        local art = piece_art(BoardScreen.piece_set, piece, square)
        if art then
            local sx, sy = place(sq)
            local px, py = sx + math.floor((square - art.w) / 2), sy + math.floor((square - art.h) / 2)
            if style.halo then
                local halo = cached_halo(art, radius)
                bb:colorblitFrom(halo, px - radius, py - radius, 0, 0, halo:getWidth(), halo:getHeight(), WHITE)
            end
            blit_piece(bb, art, piece, px, py)
        end
    end
    local label = Font:getFace(BOLD, 12 * scale * 1000 / Screen:scaleBySize(1000))
    for index = 0, 7 do
        local file = flipped and 7 - index or index
        local rank = flipped and index + 1 or 8 - index
        for _, mark in ipairs({ { string.char(string.byte("a") + file), x + index * square, y + size, square, frame }, { tostring(rank), x - frame, y + index * square, frame, square } }) do
            local widget = TextWidget:new{ text = mark[1], face = label, fgcolor = WHITE }
            local measured = widget:getSize()
            widget:paintTo(bb, mark[2] + math.floor((mark[4] - measured.w) / 2), mark[3] + math.floor((mark[5] - measured.h) / 2))
            widget:free()
        end
    end
end

-- How much of its box the drawing of a piece fills, by set and piece, measured once, so a piece in a circle is drawn at the right size the first time.
local fill_ratio = {}

-- One piece whose drawing, not its box, takes size, centered on cx, cy: for a piece in a circle, the same in every set.
function BoardScreen.paint_piece_fit(bb, set, piece, cx, cy, size)
    local key = set .. ":" .. piece
    if not fill_ratio[key] then
        local probe = piece_art(set, piece, size)
        if not probe then
            return
        end
        fill_ratio[key] = math.max(probe.w, probe.h) / size
    end
    local art = piece_art(set, piece, math.max(1, math.floor(size / math.max(0.1, fill_ratio[key]))))
    if art then
        blit_piece(bb, art, piece, cx - math.floor(art.w / 2), cy - math.floor(art.h / 2))
    end
end

-- For the list of piece sets and the row of the settings: the white and the black queen side by side.
function BoardScreen.paint_piece_sample(bb, set, x, y, size)
    for index, piece in ipairs({ "Q", "q" }) do
        local art = piece_art(set, piece, size)
        if art then
            local left = x + (index - 1) * size + math.floor((size - art.w) / 2)
            blit_piece(bb, art, piece, left, y + math.floor((size - art.h) / 2))
        end
    end
end

-- For the page of Chess960: the pieces of a back rank, white, in a row of squares of size, light and dark.
function BoardScreen.paint_rank_sample(bb, letters, x, y, size)
    for index = 1, #letters do
        local piece = letters:sub(index, index)
        local left = x + (index - 1) * size
        bb:paintRect(left, y, size, size, index % 2 == 1 and DARK_SQUARE or LIGHT_SQUARE)
        local art = piece_art(BoardScreen.piece_set, piece, size)
        if art then
            blit_piece(bb, art, piece, left + math.floor((size - art.w) / 2), y + math.floor((size - art.h) / 2))
        end
    end
    bb:paintBorder(x, y, size * #letters, size, 1, BLACK)
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
    self.dithered = BoardScreen.in_color() or nil
    -- Not "refresh", which is the method that sends a change to the screen.
    self.refresh_count = Refresh.new(FULL_REFRESH_EVERY)
end

function BoardScreen:px(value)
    return math.floor(value * self.scale + 0.5)
end

-- The review: the band of the players, the board with the bar of the evaluation on its left, the card of the move and the buttons.
function BoardScreen:band_layout()
    local gap, margin = self:px(6), self:px(6)
    local band_h, panel_h, button_h = self:px(50), self:px(106), self:px(Style.BAR)
    self.frame = self.coordinates and self:px(18) or self:px(8)
    local bar_x, bar_w = self:px(8), self:px(24)
    local left = bar_x + bar_w + self:px(6)
    local room = self.height - StatusStrip.height() - band_h - self:px(8) - 2 * self.frame - self:px(8) - panel_h - gap - button_h - margin
    self.square = math.floor(math.min(self.width - left - self:px(14) - 2 * self.frame, room) / 8)
    local board_size = self.square * 8
    self.board_x = left + self.frame + math.floor((self.width - left - self:px(14) - 2 * self.frame - board_size) / 2)
    self.band_rect = { x = 0, y = 0, w = self.width, h = band_h }
    self.top_bar = self.band_rect
    self.banner_rect = self.band_rect
    self.banner_sizes = nil
    self.board_y = band_h + self:px(8) + self.frame
    self.board_rect = Geom:new{ x = self.board_x, y = self.board_y, w = board_size, h = board_size }
    self.frame_rect = { x = self.board_x - self.frame, y = self.board_y - self.frame, w = board_size + 2 * self.frame, h = board_size + 2 * self.frame }
    self.eval_rect = { x = bar_x, y = self.frame_rect.y, w = bar_w, h = self.frame_rect.h }
    local bottom = self.frame_rect.y + self.frame_rect.h + self:px(8)
    -- No plate below: the card of the move is the "status" of a review.
    self.bottom_bar = { x = 0, y = bottom, w = self.width, h = 0 }
    self.status_rect = { x = 0, y = bottom, w = self.width, h = panel_h }
    self.buttons_rect = { x = 0, y = bottom + panel_h + gap, w = self.width, h = button_h }
end

-- The pieces of the palette, white on the first row and black on the second, as Editor.PIECES lists them.
local PALETTE = { "K", "Q", "R", "B", "N", "P", "k", "q", "r", "b", "n", "p" }

-- The editor: the band with the title, the board, the palette of pieces with Erase on its right, and the buttons.
function BoardScreen:palette_layout()
    local margin = self:px(6)
    local band_h, button_h = self:px(56), self:px(Style.BAR)
    self.frame = self.coordinates and self:px(18) or self:px(8)
    local gap = self:px(8)
    local erase_w = self:px(86)
    local tile_w = math.floor((self.width - 2 * self:px(16) - erase_w - 6 * gap) / 6)
    local tile_h = math.min(tile_w, self:px(66))
    local palette_h = 2 * tile_h + gap
    local room = self.height - StatusStrip.height() - band_h - self:px(8) - 2 * self.frame - self:px(10) - palette_h - self:px(10) - button_h - margin
    self.square = math.floor(math.min(self.width - 2 * (self:px(14) + self.frame), room) / 8)
    local board_size = self.square * 8
    self.board_x = math.floor((self.width - board_size) / 2)
    self.band_rect = { x = 0, y = 0, w = self.width, h = band_h }
    self.top_bar = self.band_rect
    self.banner_rect = self.band_rect
    self.banner_sizes = nil
    self.board_y = band_h + self:px(8) + self.frame
    self.board_rect = Geom:new{ x = self.board_x, y = self.board_y, w = board_size, h = board_size }
    self.frame_rect = { x = self.board_x - self.frame, y = self.board_y - self.frame, w = board_size + 2 * self.frame, h = board_size + 2 * self.frame }
    local top = self.frame_rect.y + self.frame_rect.h + self:px(10)
    self.palette_rects = {}
    for index, piece in ipairs(PALETTE) do
        local column, row = (index - 1) % 6, math.floor((index - 1) / 6)
        self.palette_rects[index] = { tool = piece, x = self:px(16) + column * (tile_w + gap), y = top + row * (tile_h + gap), w = tile_w, h = tile_h }
    end
    self.palette_rects[#self.palette_rects + 1] = { tool = "erase", x = self.width - self:px(16) - erase_w, y = top, w = erase_w, h = palette_h }
    self.palette_area = { x = 0, y = top, w = self.width, h = palette_h }
    self.bottom_bar = { x = 0, y = top, w = self.width, h = 0 }
    self.status_rect = { x = 0, y = top + palette_h, w = self.width, h = 0 }
    self.buttons_rect = { x = 0, y = top + palette_h + self:px(10), w = self.width, h = button_h }
end

function BoardScreen:layout()
    if self.band then
        self:band_layout()
        return
    elseif self.palette then
        self:palette_layout()
        return
    end
    local margin, gap = self:px(6), self:px(6)
    local plate_h, button_h = self:px(Style.PLATE), self:px(Style.BAR)
    local status_h = self.status_line and self:px(30) or 0
    -- The black frame holds the coordinates when they show; without them it is a thin edge.
    self.frame = self.coordinates and self:px(18) or self:px(8)
    local top_h = self.banner_lines and self:px(24) * self.banner_lines + self:px(30) + (self.banner_heading and self:px(22) or 0) or plate_h
    local room = self.height - StatusStrip.height() - margin - top_h - self:px(8) - 2 * self.frame - gap - plate_h - status_h - gap - button_h - margin
    local side = self:px(14) + self.frame
    self.square = math.floor(math.min(self.width - 2 * side, room) / 8)
    local board_size = self.square * 8
    self.board_x = math.floor((self.width - board_size) / 2)
    local plate_x, plate_w = self:px(14), self.width - 2 * self:px(14)
    self.top_bar = { x = plate_x, y = margin, w = plate_w, h = top_h }
    if self.banner_lines then
        local shadow = self:px(Style.CARD_SHADOW)
        self.top_bar = { x = self:px(10), y = margin, w = self.width - 2 * self:px(10) - shadow, h = top_h - shadow }
    end
    -- Where the text of the banner goes, inside its card, under its heading.
    local heading = self.banner_heading and self:px(22) or 0
    self.banner_rect = { x = self.top_bar.x + self:px(4), y = self.top_bar.y + self:px(4) + heading, w = self.top_bar.w - self:px(8), h = self.top_bar.h - self:px(8) - heading }
    -- The sizes that fit the banner depend on its width.
    self.banner_sizes = nil
    self.board_y = margin + top_h + self:px(8) + self.frame
    self.board_rect = Geom:new{ x = self.board_x, y = self.board_y, w = board_size, h = board_size }
    self.frame_rect = { x = self.board_x - self.frame, y = self.board_y - self.frame, w = board_size + 2 * self.frame, h = board_size + 2 * self.frame }
    self.bottom_bar = { x = plate_x, y = self.frame_rect.y + self.frame_rect.h + gap, w = plate_w, h = plate_h }
    self.status_rect = { x = 0, y = self.bottom_bar.y + plate_h, w = self.width, h = status_h }
    self.buttons_rect = { x = 0, y = self.status_rect.y + status_h + gap, w = self.width, h = button_h }
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

-- The parts of a plate: the circle with the piece, where the name starts, and the room the clock takes.
function BoardScreen:plate_parts(rect)
    local radius = math.floor(rect.h / 2) - self:px(6)
    local text_x = rect.x + self:px(8) + 2 * radius + self:px(10)
    return radius, text_x, self:px(104)
end

-- A player's plate: the piece of the side in a light circle, the name, a line below it, a tag and the clock in a pill,
-- black while it runs. info: name, detail, note ({ text, solid }, a pill in place of the detail), tag (tag_solid for a black one), clock, active, piece, or icon (of ui/draw.lua) in its place.
function BoardScreen:paint_bar(bb, rect, info, piece)
    if not info then
        return
    end
    Draw.pill(bb, rect.x, rect.y, rect.w, rect.h, self.scale, false)
    local radius, text_x, clock_w = self:plate_parts(rect)
    local cx, cy = rect.x + self:px(8) + radius, rect.y + math.floor(rect.h / 2)
    bb:paintCircle(cx, cy, radius, Style.PALE)
    if info.icon then
        Draw.icon(bb, info.icon, cx, cy, math.floor(radius * 1.2))
    else
        BoardScreen.paint_piece_fit(bb, self.piece_set, info.piece or piece, cx, cy, math.floor(radius * 1.45))
    end
    local right = rect.x + rect.w - self:px(8)
    if info.clock and info.clock ~= "" then
        local h = rect.h - self:px(14)
        local x, y = right - clock_w, rect.y + self:px(7)
        Draw.pill(bb, x, y, clock_w, h, self.scale, info.active)
        self:paint_text(bb, info.clock, BOLD, 22, x, y, clock_w, h, "center", info.active and WHITE or BLACK)
        right = x - self:px(10)
    end
    -- A tag says where what the screen shows comes from, beside the clock or in its place.
    if info.tag then
        local w = math.min(self:px(170), MoveText.width(info.tag, BOLD, 13 * self.scale) + self:px(20))
        self:paint_small_pill(bb, info.tag, right - w, cy, w, self:px(26), info.tag_solid)
        right = right - w - self:px(10)
    end
    -- What this side has more than the other, between the name and the clock.
    -- The side comes from where the plate is, not from its picture, which a screen may change.
    local difference = self:shown_material()
    local material = difference and difference[piece == "K" and "w" or "b"]
    local material_w = self:material_width(material)
    if material_w > 0 then
        self:paint_material(bb, right - material_w, cy, material)
        right = right - material_w - self:px(10)
    end
    local text_w = right - text_x
    if info.note then
        -- A state that asks for attention, in a pill under the name: solid when it is urgent.
        self:paint_text(bb, info.name, BOLD, 18, text_x, rect.y + self:px(4), text_w, self:px(24), "left")
        local h = self:px(20)
        local w = math.min(text_w, MoveText.drawn_width(info.note.text, BOLD, 12 * self.scale) + self:px(22))
        local y = rect.y + self:px(27)
        Draw.pill(bb, text_x, y, w, h, self.scale * 0.6, info.note.solid)
        MoveText.paint(self, bb, info.note.text, BOLD, 12, text_x + self:px(10), y, w - self:px(20), h, "left", info.note.solid and WHITE or BLACK)
    elseif info.detail and info.detail ~= "" then
        self:paint_text(bb, info.name, BOLD, 18, text_x, rect.y + self:px(5), text_w, self:px(24), "left")
        MoveText.paint(self, bb, info.detail, REGULAR, 13, text_x, rect.y + self:px(28), text_w, self:px(18), "left", Style.DARK)
    else
        self:paint_text(bb, info.name, BOLD, 18, text_x, rect.y, text_w, rect.h, "left")
    end
end

-- A short text in a small pill, black or outlined, centered on cy: the tag of a plate, the "+n" of the material.
function BoardScreen:paint_small_pill(bb, text, x, cy, w, h, solid)
    local y = cy - math.floor(h / 2)
    Draw.pill(bb, x, y, w, h, self.scale * 0.6, solid)
    self:paint_text(bb, text, BOLD, 13, x + self:px(6), y, w - self:px(12), h, "center", solid and WHITE or BLACK)
end

-- At most this many pieces show. With more, the last place says so with "…", since only the side ahead has a "+n" to say the rest.
local MATERIAL_PIECES = 6
local MORE = "\226\128\166"

-- The pieces of a material to draw, and whether "…" follows them.
local function material_pieces(material)
    if #material.pieces > MATERIAL_PIECES then
        return material.pieces:sub(1, MATERIAL_PIECES - 1), true
    end
    return material.pieces, false
end

-- The room the material of a side takes: its pieces, a little over each other, and the "+n". on_band: in the white pill of the band of a review, where the "+n" is plain text. A side with nothing more than the other takes none.
function BoardScreen:material_width(material, on_band)
    if not material or material.pieces == "" then
        return 0
    end
    local pieces, more = material_pieces(material)
    local w = self:px(20) + (#pieces - 1) * self:px(14)
    if more then
        w = w + self:px(2) + MoveText.width(MORE, BOLD, 13 * self.scale)
    end
    if material.lead then
        w = w + self:px(5) + MoveText.width("+" .. material.lead, BOLD, 13 * self.scale) + (on_band and self:px(2) or self:px(14))
    end
    return w + (on_band and self:px(16) or 0)
end

-- The pieces a side has more of, all in black as on Lichess, then "+n" for the side ahead: in a black pill on a plate, and the whole in a white pill on the black band of a review.
function BoardScreen:paint_material(bb, x, cy, material, on_band)
    if on_band then
        local w, h = self:material_width(material, true), self:px(28)
        bb:paintRoundedRect(x, cy - math.floor(h / 2), w, h, WHITE, math.floor(h / 2))
        x = x + self:px(8)
    end
    local size, step = self:px(20), self:px(14)
    local pieces, more = material_pieces(material)
    for index = 1, #pieces do
        BoardScreen.paint_piece_fit(bb, self.piece_set, pieces:sub(index, index), x + math.floor(size / 2) + (index - 1) * step, cy, size)
    end
    x = x + size + (#pieces - 1) * step
    if more then
        local w = MoveText.width(MORE, BOLD, 13 * self.scale)
        self:paint_text(bb, MORE, BOLD, 13, x + self:px(2), cy - self:px(12), w + self:px(2), self:px(24), "left")
        x = x + self:px(2) + w
    end
    if not material.lead then
        return
    end
    local text = "+" .. material.lead
    local text_w = MoveText.width(text, BOLD, 13 * self.scale)
    if on_band then
        self:paint_text(bb, text, BOLD, 13, x + self:px(5), cy - self:px(12), text_w + self:px(2), self:px(24), "left")
    else
        self:paint_small_pill(bb, text, x + self:px(5), cy, text_w + self:px(14), self:px(22), true)
    end
end

-- What each side has more than the other in the position shown, or nil where the screen does not show it or the material is level. Counted again only when the position is another, so a clock that ticks does not count the pieces every second.
function BoardScreen:shown_material()
    if not self.material then
        return nil
    end
    local position = self.state.position
    if self.material_position ~= position then
        self.material_position, self.material_difference = position, Material.difference(position)
    end
    return self.material_difference
end

-- The piece of the side at the top or the bottom, as the board faces.
function BoardScreen:side_piece(top)
    local white_top = self.state.flipped == true
    if top then
        return white_top and "K" or "k"
    end
    return white_top and "k" or "K"
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
    return cached_halo(art, self:halo_radius())
end

-- The corners of a square, in black with a white edge: where the last move came from, on a board being read.
function BoardScreen:paint_corners(bb, square)
    local x, y = self:square_position(square)
    local s = self.square
    local inset, len, t = self:px(5), math.floor(s * 0.28), math.max(2, self:px(5))
    local edge = math.max(1, self:px(2))
    local bars = {}
    for _, corner in ipairs({ { 0, 0, 1, 1 }, { 1, 0, -1, 1 }, { 0, 1, 1, -1 }, { 1, 1, -1, -1 } }) do
        local cx = x + inset + corner[1] * (s - 2 * inset)
        local cy = y + inset + corner[2] * (s - 2 * inset)
        local hx = corner[3] > 0 and cx or cx - len
        local vy = corner[4] > 0 and cy or cy - len
        local hy = corner[4] > 0 and cy or cy - t
        local vx = corner[3] > 0 and cx or cx - t
        bars[#bars + 1] = { hx, hy, len, t }
        bars[#bars + 1] = { vx, vy, t, len }
    end
    -- The white edges first, so a corner never covers the edge of another.
    for _, bar in ipairs(bars) do
        bb:paintRect(bar[1] - edge, bar[2] - edge, bar[3] + 2 * edge, bar[4] + 2 * edge, WHITE)
    end
    for _, bar in ipairs(bars) do
        bb:paintRect(bar[1], bar[2], bar[3], bar[4], BLACK)
    end
end

-- A frame in a square, black inside a white edge: where the last move went, on a board being read.
function BoardScreen:paint_frame_mark(bb, square)
    local x, y = self:square_position(square)
    local inset = self:px(2)
    bb:paintBorder(x + inset, y + inset, self.square - 2 * inset, self.square - 2 * inset, self:px(7), WHITE)
    bb:paintBorder(x + inset + self:px(1), y + inset + self:px(1), self.square - 2 * inset - self:px(2), self.square - 2 * inset - self:px(2), self:px(4), BLACK)
end

-- A ring around a square, black with a white edge: the king in check, and the circles of a lesson.
function BoardScreen:paint_ring(bb, square, color)
    local cx, cy = self:square_center(square)
    local r = math.floor(self.square * 0.44)
    bb:paintCircle(cx, cy, r + self:px(2), WHITE, self:px(9))
    bb:paintCircle(cx, cy, r, color or BLACK, self:px(5))
end

-- The coordinates in white on the black frame, centered on each file and rank, whichever way the board faces.
function BoardScreen:paint_coordinates(bb)
    local f = self.frame
    local bottom = self.board_y + 8 * self.square
    for index = 0, 7 do
        local file = self.state.flipped and 7 - index or index
        local rank = self.state.flipped and index + 1 or 8 - index
        self:paint_text(bb, string.char(string.byte("a") + file), BOLD, 12, self.board_x + index * self.square, bottom, self.square, f, "center", WHITE)
        self:paint_text(bb, tostring(rank), BOLD, 12, self.board_x - f, self.board_y + index * self.square, f, self.square, "center", WHITE)
    end
end

-- Whether the board is being read (a review, a study, a broadcast) rather than played: only then the last move shows.
function BoardScreen:reading()
    return self.read_marks == true or self.state.reading == true
end

function BoardScreen:paint_board(bb)
    local state = self.state
    local position = state.position
    local style = STYLES[self.style] or STYLES.plain
    local pattern = style.ink and self:pattern_tile(self.style, style)
    local frame = self.frame_rect
    bb:paintRoundedRect(frame.x, frame.y, frame.w, frame.h, BLACK, self:px(14))
    for square = 1, 64 do
        local x, y = self:square_position(square)
        local file, rank = (square - 1) % 8, math.floor((square - 1) / 8)
        local dark = (file + rank) % 2 == 0
        if dark and pattern then
            bb:blitFrom(pattern, x, y, 0, 0, self.square, self.square)
        else
            paint_square(bb, style, x, y, self.square, self.square, dark)
        end
    end
    -- The piece picked stands on a white disc in a black square.
    if state.selected then
        local x, y = self:square_position(state.selected)
        bb:paintRect(x, y, self.square, self.square, BLACK)
        bb:paintCircle(x + math.floor(self.square / 2), y + math.floor(self.square / 2), math.floor(self.square * 0.44), WHITE)
    end
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
    if state.last_move and self:reading() then
        self:paint_corners(bb, state.last_move.from)
        self:paint_frame_mark(bb, state.last_move.to)
    end
    if state.highlighted_rank then
        local _, y = self:square_position((state.highlighted_rank - 1) * 8 + 1)
        bb:paintBorder(self.board_x, y, self.square * 8, self.square, self:px(4), BLACK)
    end
    if state.check_square then
        self:paint_ring(bb, state.check_square)
    end
    for _, shape in ipairs(state.shapes or {}) do
        self:paint_shape(bb, shape)
    end
    -- Over the arrows, which often end on them.
    for square in pairs(state.stars or {}) do
        self:paint_star(bb, square)
    end
    -- The same dot on every square the piece can go to, empty or not.
    for square in pairs(state.targets or {}) do
        local cx, cy = self:square_center(square)
        local r = math.floor(self.square * 0.15)
        bb:paintCircle(cx, cy, r + self:px(3), WHITE)
        bb:paintCircle(cx, cy, r, BLACK)
    end
end

-- The icons of the buttons, by the id the modes give them. A button without one shows its name alone.
local BUTTON_ICONS = {
    back = "back", close = "back", next = "next", forward = "next", continue = "next", start = "next",
    previous = "previous", first = "first", last = "last",
    retry = "again", again = "again", restart = "again", rematch = "again",
    undo = "undo", takeback = "undo",
    moves = "moves", more = "more", hint = "hint", options = "options", comment = "comment",
    stop = "stop", abort = "stop", analysis_cancel = "stop", cancel_move = "stop", draw_no = "stop", takeback_no = "stop",
    review = "review", analyze = "review",
    resign = "flag", draw = "draw", flip = "flip", turn = "turn",
    pause = "pause", clock_pause = "pause", clock_resume = "turn", resume = "turn",
    done = "done", save = "done", confirm_move = "done", draw_yes = "done", takeback_yes = "done", claim = "done", claim_draw = "done",
    solution = "solution", show = "solution",
}

-- The buttons share the width. A bar that asks a question (confirm the move, a draw offered) has its answers as words in
-- pills, button.pill, the one that acts solid (button.primary); its other buttons then keep the width of an icon.
function BoardScreen:button_rects()
    local buttons = self.state.buttons or {}
    local count = #buttons
    local rects = {}
    if count == 0 then
        return rects
    end
    local gap = self:px(8)
    local pad = self:px(10)
    local rect = self.buttons_rect
    local pills = 0
    for _, button in ipairs(buttons) do
        if button.pill then
            pills = pills + 1
        end
    end
    local room = self.width - 2 * pad - gap * (count - 1)
    local small = pills > 0 and pills < count and self:px(100) or nil
    local w = math.floor(small and (room - small * (count - pills)) / pills or room / count)
    local x = pad
    for index, button in ipairs(buttons) do
        local bw = (small and not button.pill) and small or w
        rects[index] = { id = button.id, label = button.label, icon = button.icon, pill = button.pill, primary = button.primary, disabled = button.disabled, x = x, y = rect.y, w = bw, h = rect.h }
        x = x + bw + gap
    end
    return rects
end

-- Each button an outlined box with its icon over its name; a name too long for one line goes alone, wrapped.
function BoardScreen:paint_buttons(bb)
    for _, rect in ipairs(self:button_rects()) do
        if rect.pill then
            Draw.pill(bb, rect.x, rect.y, rect.w, rect.h, self.scale, rect.primary)
            local inner = rect.w - self:px(28)
            local size = 18
            while size > 14 and MoveText.drawn_width(rect.label, BOLD, size * self.scale) > inner do
                size = size - 1
            end
            MoveText.paint(self, bb, rect.label, BOLD, size, rect.x + self:px(14), rect.y, inner, rect.h, "center", rect.primary and WHITE or BLACK)
            goto continue
        end
        -- A button out of use for now (button.disabled) is drawn in gray, as a row of a page is, and a tap on it does nothing.
        local ink = rect.disabled and Style.DISABLED or BLACK
        Draw.box(bb, rect.x, rect.y, rect.w, rect.h, self.scale, false, rect.disabled and Style.LIGHT or nil)
        local icon = rect.icon or BUTTON_ICONS[rect.id]
        local inner = rect.w - self:px(8)
        -- A name that is only a sign, such as "<", says nothing the icon does not.
        if icon and not rect.label:find("[%a\128-\255]") then
            Draw.icon(bb, icon, rect.x + math.floor(rect.w / 2), rect.y + math.floor(rect.h / 2), self:px(28), ink)
        elseif icon and MoveText.width(rect.label, BOLD, 13 * self.scale) <= inner then
            Draw.icon(bb, icon, rect.x + math.floor(rect.w / 2), rect.y + self:px(22), self:px(24), ink)
            self:paint_text(bb, rect.label, BOLD, 13, rect.x + self:px(4), rect.y + self:px(37), inner, self:px(20), "center", ink)
        else
            local box = TextBoxWidget:new{
                text = rect.label,
                face = face(BOLD, 15 * self.scale),
                width = inner,
                alignment = "center",
                fgcolor = ink,
                bgcolor = WHITE,
            }
            local measured = box:getSize()
            box:paintTo(bb, rect.x + self:px(4), rect.y + math.floor((rect.h - measured.h) / 2))
            box:free()
        end
        ::continue::
    end
end

-- The banner: text over several lines, centered, at the largest size from 19 down to 13 that fits rect, and whether
-- even 13 did.
function BoardScreen:banner_box(text, rect)
    local pad = self:px(12)
    -- The size that fits is worked out once for each text, since the board redraws it on every move.
    self.banner_sizes = self.banner_sizes or {}
    local known = self.banner_sizes[text]
    local size = known and known.size or 19
    while true do
        local box = TextBoxWidget:new{ text = text, face = face(REGULAR, size * self.scale), width = rect.w - 2 * pad, alignment = "center", fgcolor = BLACK, bgcolor = WHITE }
        local fits = box:getSize().h <= rect.h - self:px(4)
        if fits or size <= 13 then
            self.banner_sizes[text] = { size = size, fits = fits }
            return box, fits
        end
        box:free()
        size = size - 1
    end
end

-- Whether a text fits the banner, so a screen can offer to read it whole when it does not.
function BoardScreen:banner_fits(text)
    local known = self.banner_sizes and self.banner_sizes[text]
    if known then
        return known.fits
    end
    local box, fits = self:banner_box(text, self.banner_rect)
    box:free()
    return fits
end

-- Whether a heading fits the line over the banner, in capitals as it is drawn, so a screen can shorten it.
function BoardScreen:banner_title_fits(text)
    return MoveText.width(Draw.upper(text), BOLD, 12 * self.scale) <= self.banner_rect.w - self:px(24)
end

-- The text of a lesson in a card on top of the board. A text cut at the edge, or with more to read (state.banner_more), has three dots in its corner, for the tap that reads it whole.
function BoardScreen:paint_banner(bb, text)
    local card = self.top_bar
    Draw.card(bb, card.x, card.y, card.w, card.h, self.scale)
    if self.banner_heading and self.state.banner_title then
        self:paint_text(bb, Draw.upper(self.state.banner_title), BOLD, 12, card.x + self:px(16), card.y + self:px(8), card.w - self:px(32), self:px(20), "left", Style.DARK)
    end
    local rect = self.banner_rect
    local pad = self:px(12)
    local box, fits = self:banner_box(text, rect)
    -- For the layout check: even the smallest size did not fit.
    self.banner_overflow = not fits
    -- Drawn in a buffer the size of the card, so a text that does not fit is cut at its edge, from its start.
    local h = box:getSize().h
    local area = Blitbuffer.new(rect.w, rect.h, bb:getType())
    area:paintRect(0, 0, rect.w, rect.h, WHITE)
    box:paintTo(area, pad, fits and math.floor((rect.h - h) / 2) or 0)
    box:free()
    bb:blitFrom(area, rect.x, rect.y, 0, 0, rect.w, rect.h)
    area:free()
    if self.banner_tap and (not fits or self.state.banner_more) then
        local w, h = self:px(34), self:px(18)
        local x, y = card.x + card.w - w - self:px(8), card.y + card.h - h - self:px(4)
        bb:paintRoundedRect(x, y, w, h, WHITE, math.floor(h / 2))
        Draw.icon(bb, "more", x + math.floor(w / 2), y + math.floor(h / 2), self:px(22))
    end
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

-- An arrow from the center of one square to the edge of the head on another, or a ring on a square, in black or dark
-- gray with a white edge, so it shows over the pieces and the squares alike.
function BoardScreen:paint_shape(bb, shape)
    local color = SHAPE_INK[shape.brush] or HINT_INK
    if not shape.to then
        self:paint_ring(bb, shape.from, color)
        return
    end
    local x0, y0 = self:square_center(shape.from)
    local x1, y1 = self:square_center(shape.to)
    local dx, dy = x1 - x0, y1 - y0
    local length = math.sqrt(dx * dx + dy * dy)
    if length == 0 then
        return
    end
    local ux, uy = dx / length, dy / length
    local head, half_w = self.square * 0.38, self.square * 0.22
    local thickness = math.max(3, self:px(7))
    local edge = math.max(2, self:px(2))
    for pass = 1, 2 do
        local grow = pass == 1 and edge or 0
        local ink = pass == 1 and WHITE or color
        local tip_x, tip_y = x1 + ux * grow, y1 + uy * grow
        local bx, by = x1 - ux * (head + grow), y1 - uy * (head + grow)
        local w = half_w + grow * 1.6
        paint_line(bb, x0, y0, x1 - ux * head, y1 - uy * head, thickness + 2 * grow, ink)
        paint_triangle(bb, { { tip_x, tip_y }, { bx - uy * w, by + ux * w }, { bx + uy * w, by - ux * w } }, ink)
    end
end

-- A star to collect, in black.
function BoardScreen:paint_star(bb, square)
    local x, y = self:square_position(square)
    local size = math.floor(self.square * 0.7)
    self:paint_text(bb, "\226\152\133", PIECE_FONT, size / self.scale, x, y, self.square, self.square, "center", BLACK)
end

-- A bar in a pill filled as far as the work went, with the status written over it.
function BoardScreen:paint_progress(bb, rect, progress)
    local m = self:px(16)
    local h = math.min(rect.h - self:px(4), self:px(28))
    local x, y, w = m, rect.y + math.floor((rect.h - h) / 2), rect.w - 2 * m
    local total = math.max(1, progress.total or 1)
    local radius = math.floor(h / 2)
    bb:paintRect(x, y, w, h, WHITE)
    bb:paintRect(x, y, math.floor(w * math.min(total, progress.done or 0) / total), h, PROGRESS_FILL)
    Draw.round_corners(bb, x, y, w, h, radius, Style.PAPER)
    bb:paintBorder(x, y, w, h, self:px(2), BLACK, radius)
    self:paint_text(bb, self.state.status, BOLD, 15, x + self:px(10), y, w - self:px(20), h, "center")
end

-- A work under way in a card, in place of the bottom plate or of the card of a move: what it is on the left (progress.title, or the status), how far on the right (progress.detail), and the bar under them.
function BoardScreen:paint_progress_card(bb, rect, progress)
    local radius = self:px(14)
    bb:paintRoundedRect(rect.x, rect.y, rect.w, rect.h, WHITE, radius)
    bb:paintBorder(rect.x, rect.y, rect.w, rect.h, math.max(1, math.floor(Style.BUTTON_BORDER * self.scale + 0.5)), BLACK, radius)
    local m = self:px(18)
    local inner = rect.w - 2 * m
    local detail_w = progress.detail and math.min(math.floor(inner / 2), MoveText.width(progress.detail, REGULAR, 13 * self.scale) + self:px(4)) or 0
    self:paint_text(bb, progress.title or self.state.status, BOLD, 15, rect.x + m, rect.y + self:px(4), inner - detail_w - self:px(8), self:px(24), "left")
    if progress.detail then
        self:paint_text(bb, progress.detail, REGULAR, 13, rect.x + m + inner - detail_w, rect.y + self:px(4), detail_w, self:px(24), "right", Style.DARK)
    end
    local h = self:px(14)
    local x, y = rect.x + m, rect.y + rect.h - h - self:px(8)
    local total = math.max(1, progress.total or 1)
    bb:paintRect(x, y, inner, h, WHITE)
    bb:paintRect(x, y, math.floor(inner * math.min(total, progress.done or 0) / total), h, BLACK)
    Draw.round_corners(bb, x, y, inner, h, math.floor(h / 2), WHITE)
    bb:paintBorder(x, y, inner, h, self:px(2), BLACK, math.floor(h / 2))
end

function BoardScreen:paint_game(bb)
    if self.band then
        self:paint_review(bb)
        return
    elseif self.palette then
        self:paint_editor(bb)
        return
    end
    if self.banner_lines then
        self:paint_banner(bb, self.state.banner or "")
    else
        self:paint_bar(bb, self.top_bar, self.state.top, self:side_piece(true))
    end
    self:paint_board(bb)
    local progress = self.state.progress
    if progress and self.status_rect.h == 0 then
        self:paint_progress_card(bb, self.bottom_bar, progress)
    else
        self:paint_bar(bb, self.bottom_bar, self.state.bottom, self:side_piece(false))
    end
    local rect = self.status_rect
    if rect.h > 0 then
        if progress then
            self:paint_progress(bb, rect, progress)
        elseif self.state.status then
            MoveText.paint(self, bb, self.state.status, REGULAR, 16, self:px(14), rect.y, rect.w - self:px(28), rect.h, "center", Style.DARK)
        end
    end
    self:paint_card(bb)
end

-- The players in the black band of a review: white on the left, black on the right, each with the king in a white circle, and the result or "live" between them. band: white, black, result, live.
function BoardScreen:paint_band(bb, band)
    local rect = self.band_rect
    bb:paintRect(rect.x, rect.y, rect.w, rect.h, BLACK)
    if not band then
        return
    end
    local radius = self:px(16)
    local m = self:px(8)
    local center_w = self:px(110)
    local side_w = math.floor((rect.w - center_w) / 2) - m - 2 * radius - self:px(8)
    local cy = rect.y + math.floor(rect.h / 2)
    for _, side in ipairs({ { band.white, "K", m + radius, m + 2 * radius + self:px(8), "left" }, { band.black, "k", rect.w - m - radius, rect.w - m - 2 * radius - self:px(8) - side_w, "right" } }) do
        bb:paintCircle(side[3], cy, radius, WHITE)
        BoardScreen.paint_piece_fit(bb, self.piece_set, side[2], side[3], cy, math.floor(radius * 1.45))
        -- What the side has more than the other, in a white pill at the end of its room next to the middle; the name takes what is left.
        local difference = self:shown_material()
        local material = difference and difference[side[2] == "K" and "w" or "b"]
        local material_w = self:material_width(material, true)
        local name_x, name_w = side[4], side_w
        if material_w > 0 then
            name_w = side_w - material_w - self:px(8)
            if side[5] == "left" then
                self:paint_material(bb, side[4] + side_w - material_w, cy, material, true)
            else
                self:paint_material(bb, side[4], cy, material, true)
                name_x = side[4] + material_w + self:px(8)
            end
        end
        -- The size of the name leaves room for a usual pill (a piece or two and the "+n") whether there is one or not, so it does not change from a move to the next as the material does; only a larger pill cuts the name shorter.
        local size = 17
        while size > 12 and MoveText.width(side[1], BOLD, size * self.scale) > side_w - self:px(84) do
            size = size - 1
        end
        self:paint_text(bb, side[1], BOLD, size, name_x, rect.y, name_w, rect.h, side[5], WHITE)
    end
    local cx = math.floor((rect.w - center_w) / 2)
    if band.live then
        local w, h = math.min(center_w, MoveText.width(band.live, BOLD, 14 * self.scale) + self:px(24)), self:px(28)
        local x = cx + math.floor((center_w - w) / 2)
        bb:paintRoundedRect(x, cy - math.floor(h / 2), w, h, WHITE, math.floor(h / 2))
        self:paint_text(bb, band.live, BOLD, 14, x + self:px(8), cy - math.floor(h / 2), w - self:px(16), h, "center")
    elseif band.result then
        self:paint_text(bb, band.result, BOLD, 24, cx, rect.y, center_w, rect.h, "center", WHITE)
    end
end

-- The bar of the evaluation beside the board, white rising from white's side: eval.white is white's share, from 0 to 1, and eval.text the number at its foot.
function BoardScreen:paint_eval(bb, eval)
    if not eval then
        return
    end
    local r = self.eval_rect
    local radius = math.floor(r.w / 2)
    bb:paintRoundedRect(r.x, r.y, r.w, r.h, BLACK, radius)
    local inset = math.max(2, self:px(3))
    local x, y, w, h = r.x + inset, r.y + inset, r.w - 2 * inset, r.h - 2 * inset
    local white_h = math.floor(h * math.max(0, math.min(1, eval.white)) + 0.5)
    local white_at_bottom = not self.state.flipped
    if white_h > 0 then
        bb:paintRect(x, white_at_bottom and y + h - white_h or y, w, white_h, WHITE)
    end
    Draw.round_corners(bb, x, y, w, h, math.floor(w / 2), BLACK)
    bb:paintRect(x, y + math.floor(h / 2), w, math.max(1, self:px(1)), Style.MID)
    if eval.text then
        local text_h = self:px(22)
        local foot_white = white_at_bottom and white_h > text_h or (not white_at_bottom and white_h > h - text_h)
        local size = 11
        while size > 7 and MoveText.width(eval.text, BOLD, size * self.scale) > r.w - self:px(2) do
            size = size - 1
        end
        self:paint_text(bb, eval.text, BOLD, size, r.x, r.y + r.h - text_h - self:px(4), r.w, text_h, "center", foot_white and BLACK or WHITE)
    end
end

-- The title of a page in the black band, as the pages have it, with its way back.
function BoardScreen:paint_header(bb, header)
    local rect = self.band_rect
    bb:paintRect(rect.x, rect.y, rect.w, rect.h, BLACK)
    Draw.icon(bb, "back", self:px(26), rect.y + math.floor(rect.h / 2), self:px(24), WHITE)
    if not header then
        return
    end
    local subtitle_w = header.subtitle and math.min(self:px(200), MoveText.width(header.subtitle, REGULAR, 15 * self.scale) + self:px(4)) or 0
    self:paint_text(bb, header.subtitle, REGULAR, 15, rect.w - self:px(16) - subtitle_w, rect.y, subtitle_w, rect.h, "right", Style.PALE)
    self:paint_text(bb, header.title, BOLD, 22, self:px(52), rect.y, rect.w - self:px(52) - subtitle_w - self:px(26), rect.h, "left", WHITE)
end

-- The pieces to put, each in a box, the one chosen in black with its piece on a white disc, as a piece picked in a game; Erase is a cross with its name.
function BoardScreen:paint_palette(bb, palette)
    local selected = palette and palette.selected
    for _, rect in ipairs(self.palette_rects) do
        local chosen = rect.tool == selected
        Draw.box(bb, rect.x, rect.y, rect.w, rect.h, self.scale, chosen)
        local cx, cy = rect.x + math.floor(rect.w / 2), rect.y + math.floor(rect.h / 2)
        if rect.tool == "erase" then
            local ink = chosen and WHITE or BLACK
            local arm = math.floor(math.min(rect.w, rect.h) * 0.22)
            local cross_y = cy - self:px(12)
            local thickness = math.max(2, self:px(4))
            local steps = 2 * arm
            for i = 0, steps do
                local d = i - arm
                bb:paintRect(cx + d - math.floor(thickness / 2), cross_y + d - math.floor(thickness / 2), thickness, thickness, ink)
                bb:paintRect(cx + d - math.floor(thickness / 2), cross_y - d - math.floor(thickness / 2), thickness, thickness, ink)
            end
            self:paint_text(bb, palette.erase_label, BOLD, 14, rect.x + self:px(4), cross_y + arm + self:px(6), rect.w - self:px(8), self:px(24), "center", ink)
        else
            if chosen then
                bb:paintCircle(cx, cy, math.floor(math.min(rect.w, rect.h) * 0.42), WHITE)
            end
            BoardScreen.paint_piece_fit(bb, self.piece_set, rect.tool, cx, cy, math.floor(math.min(rect.w, rect.h) * 0.62))
        end
    end
end

function BoardScreen:paint_editor(bb)
    self:paint_header(bb, self.state.header)
    self:paint_board(bb)
    self:paint_palette(bb, self.state.palette)
    self:paint_card(bb)
end

function BoardScreen:paint_review(bb)
    self:paint_band(bb, self.state.band)
    self:paint_board(bb)
    self:paint_eval(bb, self.state.eval)
    local rect = self.status_rect
    local shadow = self:px(Style.CARD_SHADOW)
    local card = { x = self:px(10), y = rect.y, w = self.width - 2 * self:px(10) - shadow, h = rect.h - shadow }
    if self.state.progress then
        self:paint_progress_card(bb, card, self.state.progress)
    elseif self.state.panel then
        self:paint_panel(bb, card, self.state.panel)
    end
    self:paint_card(bb)
end

-- The card of a move in a review, in three lines: what move it is, with a tag of who analyzed it; the move large, with its judgment in a tag (solid for a mistake, outlined for a phase that starts there); then the better move, with its arrow on the board, and the evaluation in words. A broadcast puts the clocks on the right instead. panel: title, source, move, tag, tag_solid, detail, evaluation, clocks ({ { label, clock, active }, ... }), each of them optional.
function BoardScreen:paint_panel(bb, card, panel)
    Draw.card(bb, card.x, card.y, card.w, card.h, self.scale)
    local m = card.x + self:px(16)
    local inner = card.w - 2 * self:px(16)
    local top = card.y + self:px(8)
    local right_w = 0
    if panel.clocks then
        right_w = self:px(160)
        local h = self:px(32)
        for index, clock in ipairs(panel.clocks) do
            local x, y = m + inner - right_w, card.y + self:px(12) + (index - 1) * (h + self:px(10))
            Draw.pill(bb, x, y, right_w, h, self.scale * 0.8, clock.active)
            local color = clock.active and WHITE or BLACK
            self:paint_text(bb, clock.label, REGULAR, 13, x + self:px(12), y, self:px(60), h, "left", color)
            self:paint_text(bb, clock.clock, BOLD, 18, x + self:px(70), y, right_w - self:px(82), h, "right", color)
        end
        right_w = right_w + self:px(10)
    end
    local source_w = 0
    if panel.source and not panel.clocks then
        local h = self:px(20)
        source_w = math.min(math.floor(inner / 2), MoveText.width(panel.source, BOLD, 12 * self.scale) + self:px(20))
        Draw.pill(bb, m + inner - source_w, top + self:px(1), source_w, h, self.scale * 0.6, false)
        self:paint_text(bb, panel.source, BOLD, 12, m + inner - source_w + self:px(10), top + self:px(1), source_w - self:px(20), h, "center")
        source_w = source_w + self:px(10)
    end
    self:paint_text(bb, panel.title, REGULAR, 13, m, top, inner - source_w - right_w, self:px(22), "left", Style.DARK)
    local line = top + self:px(24)
    local tag_w = 0
    if panel.tag and not panel.clocks then
        local h = self:px(32)
        tag_w = math.min(self:px(190), MoveText.width(panel.tag, BOLD, 16 * self.scale) + self:px(28))
        local x = m + inner - tag_w
        Draw.pill(bb, x, line + self:px(3), tag_w, h, self.scale, panel.tag_solid)
        self:paint_text(bb, panel.tag, BOLD, 16, x + self:px(6), line + self:px(3), tag_w - self:px(12), h, "center", panel.tag_solid and WHITE or BLACK)
        tag_w = tag_w + self:px(10)
    end
    if panel.move then
        MoveText.paint(self, bb, panel.move, BOLD, 24, m, line, inner - tag_w - right_w, self:px(38), "left")
    end
    local bottom = line + self:px(40)
    local evaluation_w = 0
    if panel.evaluation and not panel.clocks then
        evaluation_w = math.min(math.floor(inner / 2), MoveText.width(panel.evaluation, BOLD, 15 * self.scale) + self:px(4))
        self:paint_text(bb, panel.evaluation, BOLD, 15, m + inner - evaluation_w, bottom, evaluation_w, self:px(26), "right", Style.DARK)
        evaluation_w = evaluation_w + self:px(10)
    end
    if panel.detail then
        MoveText.paint(self, bb, panel.detail, REGULAR, 15, m, bottom, inner - evaluation_w - right_w, self:px(26), "left")
    end
end

-- The card over the board, and the rectangles of its buttons, in the same place on every paint.
-- card: title, text, detail, icon (an icon of ui/draw.lua) or piece, in a black circle on top, and buttons.
function BoardScreen:card_layout()
    local card = self.state.card
    if not card then
        return nil
    end
    local board = self.board_rect
    local m = self:px(20)
    local w = math.min(board.w - math.floor(self.square / 2), self:px(470))
    local x = board.x + math.floor((board.w - w) / 2)
    local primary_h, secondary_h, gap = self:px(Style.BUTTON), self:px(46), self:px(12)
    local secondary = {}
    local primary
    for _, button in ipairs(card.buttons or {}) do
        if button.primary and not primary then
            primary = button
        else
            secondary[#secondary + 1] = button
        end
    end
    local head = (card.icon or card.piece) and self:px(64) or 0
    local body = self:px(70) + (card.text and self:px(36) or 0) + (card.detail and self:px(30) or 0) + self:px(10)
    local h = self:px(14) + head + body + (primary and (primary_h + gap) or 0) + (#secondary > 0 and (secondary_h + gap) or 0) + self:px(8)
    -- Low on the board, so the top ranks, where a mated king often stands, stay in sight.
    local y = math.max(board.y + self:px(8), board.y + board.h - h - math.floor(self.square / 2))
    local rects = {}
    local cursor = y + self:px(14) + head + body
    local inner = w - 2 * m
    if primary then
        rects[#rects + 1] = { id = primary.id, label = primary.label, primary = true, x = x + m, y = cursor, w = inner, h = primary_h }
        cursor = cursor + primary_h + gap
    end
    local count = #secondary
    if count > 0 then
        local each = math.floor((inner - (count - 1) * self:px(12)) / count)
        for index, button in ipairs(secondary) do
            rects[#rects + 1] = { id = button.id, label = button.label, x = x + m + (index - 1) * (each + self:px(12)), y = cursor, w = each, h = secondary_h }
        end
    end
    return { x = x, y = y, w = w, h = h, head = head, buttons = rects }
end

function BoardScreen:paint_card(bb)
    local layout = self:card_layout()
    if not layout then
        return
    end
    local card = self.state.card
    local x, y, w = layout.x, layout.y, layout.w
    Draw.card(bb, x, y, w, layout.h, self.scale)
    local top = y + self:px(14)
    if layout.head > 0 then
        local radius = self:px(28)
        local cx = x + math.floor(w / 2)
        bb:paintCircle(cx, top + radius, radius, BLACK)
        if card.icon then
            Draw.icon(bb, card.icon, cx, top + radius, self:px(28), WHITE)
        else
            BoardScreen.paint_piece_fit(bb, self.piece_set, card.piece, cx, top + radius, math.floor(radius * 1.4))
        end
        top = top + layout.head
    end
    local title_size = 44
    while title_size > 26 and MoveText.width(card.title or "", BOLD, title_size * self.scale) > w - self:px(24) do
        title_size = title_size - 2
    end
    self:paint_text(bb, card.title, BOLD, title_size, x + self:px(12), top, w - self:px(24), self:px(64), "center")
    local line = top + self:px(66)
    if card.text then
        self:paint_text(bb, card.text, BOLD, 20, x + self:px(12), line, w - self:px(24), self:px(34), "center")
        line = line + self:px(36)
    end
    self:paint_text(bb, card.detail, REGULAR, 15, x + self:px(12), line, w - self:px(24), self:px(28), "center", Style.DARK)
    for _, rect in ipairs(layout.buttons) do
        Draw.pill(bb, rect.x, rect.y, rect.w, rect.h, self.scale, rect.primary)
        self:paint_text(bb, rect.label, BOLD, rect.primary and 20 or 17, rect.x + self:px(10), rect.y, rect.w - self:px(20), rect.h, "center", rect.primary and WHITE or BLACK)
    end
end

function BoardScreen:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(0, 0, self.width, self.height, Style.PAPER)
    -- The game comes from Lichess or from a save. If it cannot be drawn, a short message takes its place, and the
    -- buttons below, with the way back, still work.
    local ok, err = pcall(self.paint_game, self, bb)
    if not ok then
        logger.warn("Ink Knight: could not draw the board", err)
        local bottom = self.buttons_rect.y
        bb:paintRect(0, 0, self.width, bottom, Style.PAPER)
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
    Sleep.dirty(self, function() return Refresh.settle(mode), region end)
end

function BoardScreen:dirty_rect(mode, rect)
    self:dirty(mode, rect.x, rect.y, rect.w, rect.h)
end

-- Sends to the screen only what changed: each square on its own, so a move does not redraw what lies between.
-- The clock changes every second when it is short, so it stays out of the count, with "fast" on its bars.
function BoardScreen:refresh(what)
    local shown = BoardDiff.snapshot(self.state, self:shown_material())
    local changes = BoardDiff.changes(self.shown, shown)
    self.shown = shown
    if what == "clock" then
        self:dirty_rect("fast", self.top_bar)
        self:dirty_rect("fast", self.bottom_bar)
        return
    end
    -- A change of the whole screen (the game arriving, a card, the board turned) goes with a flash: a flash waits
    -- for the update before it, where an update without one would collide with it on the Kindle and lose a part,
    -- as the bar of buttons was lost when a game came right after the flash of its opening.
    if what == "full" or changes.whole then
        self.refresh_count:reset()
    end
    local mode = self.refresh_count:mode("cells")
    if mode == "full" then
        Sleep.dirty(self, function() return mode, self.dimen end)
        return
    end
    -- Each square changed on its own, without a flash. A square that loses a dark mark can keep a light ghost of it until the flash of the count clears it: flashing those squares, the e-ink of the Kindle flashed the four squares around a short diagonal move, or the squares one after the other, or, sent together, the gray ground beside them too (tried on the Kindle, 2026-11-14), and the reader chose no flash.
    if #changes.squares > MAX_SEPARATE_SQUARES then
        self:dirty("ui", self.board_x, self.board_y, self.square * 8, self.square * 8)
    else
        for _, square in ipairs(changes.squares) do
            local x, y = self:square_position(square)
            self:dirty("ui", x, y, self.square, self.square)
        end
    end
    if changes.top then self:dirty_rect("ui", self.top_bar) end
    if changes.eval and self.eval_rect then self:dirty_rect("ui", self.eval_rect) end
    if changes.palette and self.palette_area then self:dirty_rect("ui", self.palette_area) end
    if changes.bottom then self:dirty_rect("ui", self.bottom_bar) end
    if changes.status then
        -- Without a line of text, the status shows only in the card of a work under way, over the bottom plate.
        self:dirty_rect("ui", self.status_rect.h > 0 and self.status_rect or self.bottom_bar)
    end
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
            if self.on_button and not rect.disabled then
                self.on_button(rect.id)
            end
            return true
        end
    end
    if self.palette and self.on_button then
        for _, rect in ipairs(self.palette_rects) do
            if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
                self.on_button("tool:" .. rect.tool)
                return true
            end
        end
        if y < self.band_rect.h and x < self:px(80) then
            self.on_button("back")
            return true
        end
    end
    local banner = self.top_bar
    if self.banner_lines and self.banner_tap and self.on_button and x >= banner.x and x < banner.x + banner.w and y >= banner.y and y < banner.y + banner.h then
        self.on_button(self.banner_tap)
        return true
    end
    local card = self:card_layout()
    if card then
        for _, rect in ipairs(card.buttons) do
            if x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h then
                if self.on_button then
                    self.on_button(rect.id)
                end
                return true
            end
        end
        -- The card covers the board: a tap beside its buttons does nothing.
        return true
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
    self.shown = BoardDiff.snapshot(self.state, self:shown_material())
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
