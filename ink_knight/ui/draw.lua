-- The shapes of the redesign every screen draws: cards with a shadow, pills, tags and the icons of the bar of buttons. Sizes are given in pixels already scaled by the screen, but for the strokes, which it scales itself with scale. The icons are SVG in ink_knight/icons, drawn through their alpha, so the same icon comes in black on a white button and in white on a black one.
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local ffi = require("ffi")
local logger = require("logger")

local MoveText = require("ink_knight/ui/move_text")
local Style = require("ink_knight/ui/style")

local Screen = Device.screen
local Draw = {}

local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("/ink_knight/ui/draw%.lua$", "")

local function round(value)
    return math.floor(value + 0.5)
end

-- A card: its shadow below and to the right, then the card, white or solid, with its border.
function Draw.card(bb, x, y, w, h, scale, solid)
    local shadow = round(Style.CARD_SHADOW * scale)
    local radius = round(Style.CARD_RADIUS * scale)
    bb:paintRoundedRect(x + shadow, y + shadow, w, h, Style.MID, radius)
    bb:paintRoundedRect(x, y, w, h, solid and Style.BLACK or Style.WHITE, radius)
    bb:paintBorder(x, y, w, h, math.max(1, round(Style.CARD_BORDER * scale)), Style.BLACK, radius)
end

-- A pill: a button, a clock or a choice; solid in black, or white with a black border.
function Draw.pill(bb, x, y, w, h, scale, solid)
    local radius = math.floor(h / 2)
    bb:paintRoundedRect(x, y, w, h, solid and Style.BLACK or Style.WHITE, radius)
    if not solid then
        bb:paintBorder(x, y, w, h, math.max(1, round(Style.BUTTON_BORDER * scale)), Style.BLACK, radius)
    end
end

-- A box with rounded corners and a border: the buttons of the bar.
function Draw.box(bb, x, y, w, h, scale, solid, edge)
    local radius = round(Style.CARD_RADIUS * scale)
    bb:paintRoundedRect(x, y, w, h, solid and Style.BLACK or Style.WHITE, radius)
    bb:paintBorder(x, y, w, h, math.max(1, round(2 * scale)), edge or Style.BLACK, radius)
end

-- Paints color outside the rounded corners of a box of radius r, for shapes drawn in parts, such as a bar split
-- in three, that the KOReader cannot paint rounded by themselves.
function Draw.round_corners(bb, x, y, w, h, r, color)
    for row = 0, r - 1 do
        local dy = r - row - 0.5
        local cut = r - math.floor(math.sqrt(math.max(0, r * r - dy * dy)) + 0.5)
        if cut > 0 then
            bb:paintRect(x, y + row, cut, 1, color)
            bb:paintRect(x + w - cut, y + row, cut, 1, color)
            bb:paintRect(x, y + h - 1 - row, cut, 1, color)
            bb:paintRect(x + w - cut, y + h - 1 - row, cut, 1, color)
        end
    end
end

-- Letters in capitals, the accented ones of Portuguese and Spanish too, for the headings of the sections.
function Draw.upper(text)
    return (text:upper():gsub("\195([\160-\190])", function(c)
        if c == "\183" then
            return "\195" .. c
        end
        return "\195" .. string.char(c:byte() - 32)
    end))
end

local function face(name, size)
    return Font:getFace(name, size * 1000 / Screen:scaleBySize(1000))
end

-- Text in a box: align is "left", "center" or "right"; the text is cut at the width of the box.
function Draw.text(bb, text, name, size, x, y, w, h, align, color)
    if not text or text == "" then
        return
    end
    local widget = TextWidget:new{ text = text, face = face(name, size), fgcolor = color or Style.BLACK, max_width = w }
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

-- The same measure as the moves, kept in its cache.
function Draw.text_width(text, name, size)
    return MoveText.width(text, name, size)
end

-- A tag: a short state in a small pill, solid or outlined, its width from its text. Returns the width.
function Draw.tag(bb, text, x, y, h, scale, solid)
    local size = 12 * scale
    local w = Draw.text_width(text, Style.BOLD, size) + round(20 * scale)
    Draw.pill(bb, x, y, w, h, scale * 0.6, solid)
    Draw.text(bb, text, Style.BOLD, size, x, y, w, h, "center", solid and Style.WHITE or Style.BLACK)
    return w
end

-- The icons, kept as masks by name and size.
local masks = {}

-- The alpha of an image as a mask of 8 bits, read straight from its memory: getPixel makes an object per pixel.
local function alpha_mask(image)
    local w, h = image:getWidth(), image:getHeight()
    local mask = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    local out = ffi.cast("uint8_t*", mask.data)
    local out_stride = tonumber(mask.stride)
    if image:getType() == Blitbuffer.TYPE_BBRGB32 then
        local data = ffi.cast("uint8_t*", image.data)
        local stride = tonumber(image.stride)
        for row = 0, h - 1 do
            for column = 0, w - 1 do
                out[row * out_stride + column] = data[row * stride + column * 4 + 3]
            end
        end
    else
        for row = 0, h - 1 do
            for column = 0, w - 1 do
                out[row * out_stride + column] = image:getPixel(column, row).alpha or 255
            end
        end
    end
    return mask
end

local function icon_mask(name, size)
    local key = name .. ":" .. size
    if masks[key] == nil then
        local RenderImage = require("ui/renderimage")
        local ok, image = pcall(RenderImage.renderSVGImageFile, RenderImage, PLUGIN_DIR .. "/ink_knight/icons/" .. name .. ".svg", size, size)
        if ok and image then
            masks[key] = alpha_mask(image)
            image:free()
        else
            logger.warn("Ink Knight: no icon", name)
            masks[key] = false
        end
    end
    return masks[key] or nil
end

-- An icon centered on cx, cy, size pixels wide, in color. The draw is "½", written, since it is a sign of chess more than a picture.
function Draw.icon(bb, name, cx, cy, size, color)
    color = color or Style.BLACK
    if name == "draw" then
        Draw.text(bb, "\194\189", Style.BOLD, size * 0.95, cx - size, cy - size / 2, 2 * size, size, "center", color)
        return
    end
    size = round(size)
    local mask = icon_mask(name, size)
    if mask then
        bb:colorblitFrom(mask, cx - math.floor(size / 2), cy - math.floor(size / 2), 0, 0, size, size, color)
    end
end

function Draw.clear_cache()
    for key, mask in pairs(masks) do
        if mask then
            mask:free()
        end
        masks[key] = nil
    end
end

return Draw
