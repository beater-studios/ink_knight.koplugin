-- Takes the reader to the page of Lichess that creates a token, with the permissions already marked.
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local StatusStrip = require("ink_knight/ui/status_strip")
local TokenScopes = require("ink_knight/token_scopes")

local Screen = Device.screen

local SERIF = "noto/NotoSerif-Regular.ttf"
local SERIF_BOLD = "noto/NotoSerif-Bold.ttf"

local CreateTokenScreen = InputContainer:extend{
    name = "ink_knight_create_token",
    covers_fullscreen = true,
    stop_events_propagation = true,
    strings = nil,
    on_ready = nil,
}

function CreateTokenScreen:init()
    local s = self.strings
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    local text_width = self.width - 2 * Screen:scaleBySize(24)
    local gap = Screen:scaleBySize(10)
    local qr_size = math.floor(math.min(self.width, self.height) * 0.56)
    local function paragraph(text, face, size)
        return TextBoxWidget:new{ text = text, face = Font:getFace(face, size), width = text_width, alignment = "center" }
    end
    local function button(text, callback)
        return Button:new{
            text = text,
            width = text_width,
            padding_v = Screen:scaleBySize(8),
            radius = Screen:scaleBySize(8),
            bordersize = Screen:scaleBySize(2),
            text_font_face = "cfont",
            text_font_size = 19,
            callback = callback,
        }
    end
    local manual = string.format(s.token_create_manual, TokenScopes.CREATE_URL:gsub("^https://", ""), table.concat(TokenScopes.SUGGESTED, ", "))
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        width = self.width,
        height = self.height,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height - StatusStrip.height() },
            VerticalGroup:new{
                align = "center",
                paragraph(s.token_create_title, SERIF_BOLD, 24),
                VerticalSpan:new{ width = gap },
                paragraph(s.token_create_steps, SERIF, 15),
                VerticalSpan:new{ width = gap },
                QRWidget:new{ text = TokenScopes.create_url(), width = qr_size, height = qr_size },
                VerticalSpan:new{ width = gap },
                paragraph(manual, SERIF, 12),
                VerticalSpan:new{ width = gap },
                button(s.token_create_done, function()
                    UIManager:close(self)
                    self.on_ready()
                end),
                VerticalSpan:new{ width = gap },
                button(s.back, function() UIManager:close(self) end),
            },
        },
    }
end

function CreateTokenScreen:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)
    StatusStrip.paint(bb, self.width, self.height)
end

function CreateTokenScreen:strip_region()
    return StatusStrip.region(self.width, self.height)
end

function CreateTokenScreen:onClose()
    UIManager:close(self)
    return true
end

function CreateTokenScreen:onShow()
    UIManager:setDirty(self, "full")
    return true
end

function CreateTokenScreen:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

return CreateTokenScreen
