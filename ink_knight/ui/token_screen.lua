-- Receives the Lichess token from another device on the same network, so nobody has to type it on an e-ink
-- keyboard. The session (code, address, firewall) is the one of lan.lua, and the server the one of http_server.lua.
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
local logger = require("logger")

local Lan = require("ink_knight/lan")
local Portrait = require("ink_knight/portrait")
local Refresh = require("ink_knight/refresh")
local Server = require("ink_knight/http_server")
local Sleep = require("ink_knight/sleep")
local StatusStrip = require("ink_knight/ui/status_strip")
local TokenAccess = require("ink_knight/token_access")

local Screen = Device.screen

local PORT = 8644
-- Quick while a browser is connected, calm while it waits.
local TICK_BUSY, TICK_IDLE = 0.05, 0.25
local IDLE_LIMIT = 300
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

function TokenScreen:init()
    Portrait.open(self, self.setup)
end

function TokenScreen:setup()
    self.width, self.height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.text_width = self.width - 2 * Screen:scaleBySize(30)
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
    end
    -- Waiting, connected and each message are layouts of their own: a change inside one does not flash.
    self.refresh = Refresh.new(8)
    self.tick_callback = function() self:tick() end
    Sleep.watch(self)
    self:start()
end

function TokenScreen:start()
    local s = self.strings
    local ip = self.local_ip or Lan.local_ip()
    if not ip or not Lan.is_private_ip(ip) then
        self:show_message(s.no_local_network)
        return
    end
    local code = Lan.random_token()
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
    -- It listens on the address of the Wi-Fi only, so nothing reaches it through the USB network.
    self.server = Server.new{ access = self.access, ip = ip, port = self.port, name = "Ink Knight" }
    local ok, err = self.server:start()
    if not ok then
        self.server = nil
        self:show_message(tostring(err))
        return
    end
    -- Only once the server is up, so a port is never left open with nobody behind it.
    if not Lan.open_firewall(self.port) then
        self.server:stop()
        self.server = nil
        self:show_message(s.start_failed)
        return
    end
    self.firewall_open = true
    self:show_waiting()
    Sleep.schedule(self, TICK_IDLE, self.tick_callback)
end

-- Ends the session, in this order: no more ticks, no more connections, the port closed. The screen stays.
function TokenScreen:stop_session()
    Sleep.unschedule(self, self.tick_callback)
    if self.confirm then
        UIManager:close(self.confirm)
        self.confirm = nil
    end
    if self.server then
        self.server:stop()
        self.server = nil
    end
    if self.firewall_open then
        self.firewall_open = false
        -- The port stays listed, and the next start of KOReader closes it.
        if not Lan.close_firewall(self.port) then
            logger.warn("Ink Knight: the port of the token page could not be closed")
        end
    end
    self.access = nil
end

-- The question can outlast the session (the device sleeps, the page times out), so each answer checks that the
-- session is still the one that asked.
function TokenScreen:ask_permission(client)
    local s = self.strings
    local access = self.access
    self.confirm = ConfirmBox:new{
        text = string.format(s.allow_question, client),
        ok_text = s.allow_button,
        cancel_text = s.deny_button,
        -- A tap outside would count as a refusal.
        dismissable = false,
        ok_callback = function()
            self.confirm = nil
            if self.server and self.access == access then
                access:approve(client)
                self:show_message(s.connected_phone)
            end
        end,
        cancel_callback = function()
            self.confirm = nil
            if self.server and self.access == access then
                access:deny(client)
            end
        end,
    }
    Sleep.show(self, self.confirm)
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
    local busy = self.server:tick()
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
    Sleep.schedule(self, busy and TICK_BUSY or TICK_IDLE, self.tick_callback)
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

-- kind: the layout now on the screen. The same one again is a change inside it.
function TokenScreen:set_group(group, kind)
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
    Sleep.dirty(self, function()
        return self.refresh:mode(kind), self.dimen
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
    }, "waiting")
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
    }, "message")
end

function TokenScreen:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)
    StatusStrip.paint(bb, self.width, self.height)
end

function TokenScreen:strip_region()
    return StatusStrip.region(self.width, self.height)
end

function TokenScreen:onBack()
    UIManager:close(self)
    return true
end

-- KOReader sends Close to every window before it quits, and with keep_screensaver before powering off, when the
-- window stays so the sleep screen is left alone.
function TokenScreen:onClose(arg)
    if not (arg and arg.keep_screensaver) then
        UIManager:close(self)
    end
end

TokenScreen.onSetRotationMode = Portrait.ignore_rotation

-- Asleep, the Wi-Fi goes, so the session ends at once. What it says is drawn when the device wakes up.
function TokenScreen:onSuspend()
    if self.server then
        self:stop_session()
        self:show_message(self.strings.token_page_slept)
    end
end

function TokenScreen:onCloseWidget()
    self:stop_session()
    Portrait.close(self)
    UIManager:setDirty(nil, "full")
end

return TokenScreen
