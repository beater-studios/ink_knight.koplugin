-- Receives the Lichess token from a phone, so nobody has to type it on an e-ink keyboard.
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
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
local socket = require("socket")

local TokenAccess = require("ink_knight/token_access")
local TokenServer = require("ink_knight/token_server")
local StatusStrip = require("ink_knight/ui/status_strip")

local Screen = Device.screen

local PORT = 8644
local TICK = 0.25
local IDLE_LIMIT = 300
local CODE_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"
local CODE_LENGTH = 16
local SERIF = "noto/NotoSerif-Regular.ttf"
local SERIF_BOLD = "noto/NotoSerif-Bold.ttf"

local TokenScreen = InputContainer:extend{
    name = "ink_knight_token",
    covers_fullscreen = true,
    stop_events_propagation = true,
    strings = nil,
    on_token = nil,
    port = PORT,
    local_ip = nil,
}

local function random_code()
    local source = io.open("/dev/urandom", "rb")
    if not source then
        return nil
    end
    local bytes = source:read(CODE_LENGTH)
    source:close()
    if not bytes or #bytes < CODE_LENGTH then
        return nil
    end
    local out = {}
    for i = 1, CODE_LENGTH do
        local index = bytes:byte(i) % #CODE_ALPHABET + 1
        out[i] = CODE_ALPHABET:sub(index, index)
    end
    return table.concat(out)
end

local function detect_local_ip()
    local udp = socket.udp()
    if not udp then
        return nil
    end
    udp:setpeername("10.255.255.255", 9)
    local ip = udp:getsockname()
    udp:close()
    return ip
end

local function firewall(action, port)
    if Device:isKindle() then
        os.execute(string.format("iptables -%s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null", action, port))
        os.execute(string.format("iptables -%s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null", action, port))
    end
end

function TokenScreen:init()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.text_width = self.width - 2 * Screen:scaleBySize(30)
    self.tick_callback = function() self:tick() end
    self:start()
end

function TokenScreen:start()
    local s = self.strings
    local ip = self.local_ip or detect_local_ip()
    if not ip or not TokenAccess.is_private_ip(ip) then
        self:show_message(s.no_local_network)
        return
    end
    local code = random_code()
    if not code then
        self:show_message(s.start_failed)
        return
    end
    self.url = string.format("http://%s:%d/%s/", ip, self.port, code)
    self.access = TokenAccess.new{
        code = code,
        host = string.format("%s:%d", ip, self.port),
        strings = s,
        on_new_client = function(client) self:ask_permission(client) end,
        on_token = function(token) self:got_token(token) end,
    }
    self.server = TokenServer.new{ access = self.access, ip = ip, port = self.port }
    firewall("D", self.port)
    local ok, err = self.server:start()
    if not ok then
        self.server = nil
        self:show_message(tostring(err))
        return
    end
    firewall("A", self.port)
    self.firewall_open = true
    self:show_waiting()
    UIManager:scheduleIn(TICK, self.tick_callback)
end

function TokenScreen:ask_permission(client)
    local s = self.strings
    self.confirm = ConfirmBox:new{
        text = string.format(s.allow_question, client),
        ok_text = s.allow_button,
        cancel_text = s.deny_button,
        dismissable = false,
        ok_callback = function()
            self.confirm = nil
            if self.server then
                self.access:approve(client)
                self:show_message(s.connected_phone)
            end
        end,
        cancel_callback = function()
            self.confirm = nil
            if self.server then
                self.access:deny(client)
            end
        end,
    }
    UIManager:show(self.confirm)
end

-- The answer to the browser still has to go out, so the screen closes on a later tick.
function TokenScreen:got_token(token)
    self.received = token
    self.close_at = os.time() + 2
end

function TokenScreen:tick()
    if not self.server then
        return
    end
    self.server:tick()
    if self.close_at and os.time() >= self.close_at then
        local token = self.received
        UIManager:close(self)
        if self.on_token then
            self.on_token(token)
        end
        return
    end
    if os.time() - self.server.last_activity > IDLE_LIMIT then
        UIManager:close(self)
        return
    end
    UIManager:scheduleIn(TICK, self.tick_callback)
end

function TokenScreen:paragraph(text, face, size)
    return TextBoxWidget:new{ text = text, face = Font:getFace(face, size), width = self.text_width, alignment = "center" }
end

function TokenScreen:button(text)
    return Button:new{
        text = text,
        width = self.text_width,
        padding_v = Screen:scaleBySize(10),
        radius = Screen:scaleBySize(8),
        bordersize = Screen:scaleBySize(2),
        text_font_face = "cfont",
        text_font_size = 19,
        callback = function() UIManager:close(self) end,
    }
end

function TokenScreen:set_group(group)
    if self[1] then
        self[1]:free()
    end
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        width = self.width,
        height = self.height,
        CenterContainer:new{ dimen = Geom:new{ w = self.width, h = self.height - StatusStrip.height() }, group },
    }
    UIManager:setDirty(self, function()
        return "full", self.dimen
    end)
end

function TokenScreen:show_waiting()
    local s = self.strings
    local gap = Screen:scaleBySize(12)
    local qr_size = math.floor(math.min(self.width, self.height) * 0.62)
    self:set_group(VerticalGroup:new{
        align = "center",
        self:paragraph(s.token_server_title, SERIF_BOLD, 28),
        VerticalSpan:new{ width = gap },
        self:paragraph(s.scan_hint, SERIF, 17),
        VerticalSpan:new{ width = gap },
        QRWidget:new{ text = self.url, width = qr_size, height = qr_size },
        VerticalSpan:new{ width = gap },
        self:paragraph(self.url, SERIF, 14),
        VerticalSpan:new{ width = gap },
        self:paragraph(s.waiting, SERIF_BOLD, 17),
        VerticalSpan:new{ width = gap },
        self:paragraph(s.privacy_note, SERIF, 14),
        VerticalSpan:new{ width = gap },
        self:button(s.stop_button),
    })
end

function TokenScreen:show_message(message)
    local gap = Screen:scaleBySize(16)
    self:set_group(VerticalGroup:new{
        align = "center",
        self:paragraph(self.strings.token_server_title, SERIF_BOLD, 28),
        VerticalSpan:new{ width = gap },
        self:paragraph(message, SERIF, 18),
        VerticalSpan:new{ width = gap * 2 },
        self:button(self.strings.stop_button),
    })
end

function TokenScreen:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)
    StatusStrip.paint(bb, self.width, self.height)
end

function TokenScreen:strip_region()
    return StatusStrip.region(self.width, self.height)
end

function TokenScreen:onSuspend()
    UIManager:close(self)
end

function TokenScreen:onCloseWidget()
    UIManager:unschedule(self.tick_callback)
    if self.confirm then
        UIManager:close(self.confirm)
        self.confirm = nil
    end
    if self.server then
        self.server:stop()
        self.server = nil
    end
    if self.firewall_open then
        firewall("D", self.port)
        self.firewall_open = false
    end
    UIManager:setDirty(nil, "full")
end

return TokenScreen
