-- Text whose moves are drawn with the pieces as symbols (figurine.lua), for the board and the pages. The widths are
-- kept once measured, since a screen paints its texts again on every update.
local Device = require("device")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")

local Figurine = require("ink_knight/figurine")

local Screen = Device.screen

local MoveText = {}

local widths, count = {}, 0
-- Enough for the moves of a long game and its texts, without keeping every text ever drawn.
local MAX_WIDTHS = 600

local function face(name, size)
    return Font:getFace(name, size * 1000 / Screen:scaleBySize(1000))
end

function MoveText.width(text, name, size)
    local key = name .. "\0" .. size .. "\0" .. text
    local width = widths[key]
    if not width then
        if count >= MAX_WIDTHS then
            widths, count = {}, 0
        end
        local widget = TextWidget:new{ text = text, face = face(name, size) }
        width = widget:getSize().w
        widget:free()
        widths[key], count = width, count + 1
    end
    return width
end

-- screen: one with paint_text(bb, text, name, size, x, y, w, h, align, color) and scale, as the board and the pages.
function MoveText.paint(screen, bb, text, name, size, x, y, w, h, align, color)
    Figurine.paint(text, name, size, x, w, align,
        function(part, font, part_size) return MoveText.width(part, font, part_size * screen.scale) end,
        function(part, font, part_size, part_x, part_w, part_align)
            screen:paint_text(bb, part, font, part_size, part_x, y, part_w, h, part_align, color)
        end)
end

return MoveText
