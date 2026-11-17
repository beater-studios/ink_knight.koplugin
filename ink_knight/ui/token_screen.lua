-- Receives the Lichess token from another device on the same network, so nobody has to type it on an e-ink
-- keyboard. The session (code, address, firewall) is the one of lan.lua, and the server the one of http_server.lua.
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Draw = require("ink_knight/ui/draw")
local Lan = require("ink_knight/lan")
local Page = require("ink_knight/ui/page")
local Portrait = require("ink_knight/portrait")
local Refresh = require("ink_knight/refresh")
local Server = require("ink_knight/http_server")
local Sleep = require("ink_knight/sleep")
local StatusStrip = require("ink_knight/ui/status_strip")
local Style = require("ink_knight/ui/style")
local TokenAccess = require("ink_knight/token_access")

local Screen = Device.screen

local PORT = 8644
-- Quick while a browser is connected, calm while it waits.
local TICK_BUSY, TICK_IDLE = 0.05, 0.25
local IDLE_LIMIT = 300
local REGULAR, BOLD = Style.REGULAR, Style.BOLD

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
    self.scale = math.min(self.width / 600, self.height / 800)
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
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

-- The question can outlast the session (the device sleeps, the page times out), so each answer checks that the session is still the one that asked. It is the card of a question over the page; going back, or a tap beside it, refuses, since the phone waits for an answer. self.answer keeps both answers, for the checks.
function TokenScreen:ask_permission(client)
    local s = self.strings
    local access = self.access
    local function approve()
        self.confirm = nil
        if self.server and self.access == access then
            access:approve(client)
            self:show_message(s.connected_phone)
        end
    end
    local function deny()
        self.confirm = nil
        if self.server and self.access == access then
            access:deny(client)
        end
    end
    self.answer = { ok = approve, cancel = deny }
    self.confirm = Page:new{
        dialog = "center",
        title = string.format(s.allow_question, client),
        close_on_tap = true,
        rows = {
            { kind = "primary", text = s.allow_button, callback = approve },
            { kind = "secondary", text = s.deny_button, callback = deny },
        },
        on_back = function(page)
            UIManager:close(page)
            deny()
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

function TokenScreen:px(value)
    return math.floor(value * self.scale + 0.5)
end

-- kind: the layout now on the screen. The same one again is a change inside it.
function TokenScreen:set_view(view, kind)
    self.view = view
    Sleep.dirty(self, function()
        return self.refresh:mode(kind), self.dimen
    end)
end

function TokenScreen:show_waiting()
    self:set_view({ kind = "waiting" }, "waiting")
end

function TokenScreen:show_message(message)
    self:set_view({ kind = "message", text = message }, "message")
end

function TokenScreen:text(bb, text, name, size, x, y, w, h, color, align)
    local widget = TextWidget:new{ text = text, face = Font:getFace(name, size * self.scale * 1000 / Screen:scaleBySize(1000)), fgcolor = color or Style.BLACK, max_width = w }
    local measured = widget:getSize()
    local left = align == "left" and x or x + math.floor((w - measured.w) / 2)
    widget:paintTo(bb, left, y + math.floor((h - measured.h) / 2))
    widget:free()
end

-- Wrapped text, drawn at x, y; returns its height.
function TokenScreen:paragraph(bb, text, size, x, y, w, color, align)
    local box = TextBoxWidget:new{ text = text, face = Font:getFace(REGULAR, size * self.scale * 1000 / Screen:scaleBySize(1000)), width = w, alignment = align or "left", fgcolor = color or Style.BLACK, bgcolor = Style.WHITE }
    local h = box:getSize().h
    if bb then
        box:paintTo(bb, x, y)
    end
    box:free()
    return h
end

-- The code, made once for its address and size, and kept until the page closes.
function TokenScreen:code(size)
    if not self.qr or self.qr_size ~= size or self.qr_url ~= self.url then
        if self.qr then
            self.qr:free()
        end
        self.qr, self.qr_size, self.qr_url = QRWidget:new{ text = self.url, width = size, height = size }, size, self.url
    end
    return self.qr
end

-- The page: a black band with the title and the way back; a card with what to do, the code, the address in a pill and the state; the note of the network under it; Cancel in a pill.
function TokenScreen:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local s, px = self.strings, function(v) return self:px(v) end
    local width = self.width
    bb:paintRect(0, 0, width, self.height, Style.PAPER)
    local band = px(Style.BAND)
    bb:paintRect(0, 0, width, band, Style.BLACK)
    Draw.icon(bb, "back", px(26), math.floor(band / 2), px(24), Style.WHITE)
    self:text(bb, s.token_server_title, BOLD, Style.TITLE, px(52), 0, width - px(68), band, Style.WHITE, "left")
    local view = self.view or { kind = "message", text = "" }
    local m, pad = px(16), px(16)
    local shadow = px(Style.CARD_SHADOW)
    local card_w = width - 2 * m - shadow
    local inner = card_w - 2 * pad
    local top = band + px(16)
    local cursor = top + pad
    local function card_height()
        if view.kind == "waiting" then
            local qr = math.min(inner, px(220))
            return pad + self:paragraph(nil, s.scan_hint, 16, 0, 0, inner) + px(12) + qr + px(14) + px(44) + px(12) + px(32) + pad
        end
        return pad + self:paragraph(nil, view.text, 18, 0, 0, inner, nil, "center") + pad
    end
    local h = card_height()
    Draw.card(bb, m, top, card_w, h, self.scale)
    if view.kind == "waiting" then
        cursor = cursor + self:paragraph(bb, s.scan_hint, 16, m + pad, cursor, inner) + px(12)
        local qr = math.min(inner, px(220))
        self:code(qr):paintTo(bb, m + math.floor((card_w - qr) / 2), cursor)
        cursor = cursor + qr + px(14)
        local address = self.url:gsub("^http://", ""):gsub("/$", "")
        Draw.pill(bb, m + pad, cursor, inner, px(44), self.scale, false)
        self:text(bb, address, BOLD, 17, m + pad + px(12), cursor, inner - px(24), px(44))
        cursor = cursor + px(44) + px(12)
        local wait_w = math.min(inner, Draw.text_width(s.waiting, BOLD, 14 * self.scale) + px(60))
        local wait_x = m + math.floor((card_w - wait_w) / 2)
        Draw.pill(bb, wait_x, cursor, wait_w, px(32), self.scale, true)
        bb:paintCircle(wait_x + px(20), cursor + px(16), px(5), Style.WHITE)
        self:text(bb, s.waiting, BOLD, 14, wait_x + px(32), cursor, wait_w - px(44), px(32), Style.WHITE)
        local note_y = top + h + shadow + px(14)
        self:note(bb, s.privacy_note, m + px(4), note_y, width - 2 * m - px(8))
    else
        self:paragraph(bb, view.text, 18, m + pad, cursor, inner, nil, "center")
    end
    local bw, bh = px(300), px(52)
    self.cancel_rect = { x = math.floor((width - bw) / 2), y = self.height - StatusStrip.height() - px(40) - bh, w = bw, h = bh }
    local r = self.cancel_rect
    Draw.pill(bb, r.x, r.y, r.w, r.h, self.scale, false)
    self:text(bb, s.stop_button, BOLD, 18, r.x, r.y, r.w, r.h)
    StatusStrip.paint(bb, self.width, self.height)
end

-- A line of note on the gray ground.
function TokenScreen:note(bb, text, x, y, w)
    local box = TextBoxWidget:new{ text = text, face = Font:getFace(REGULAR, 13 * self.scale * 1000 / Screen:scaleBySize(1000)), width = w, fgcolor = Style.DARK, bgcolor = Style.PAPER }
    box:paintTo(bb, x, y)
    box:free()
end

function TokenScreen:onTap(_, ges)
    local x, y = ges.pos.x, ges.pos.y
    local r = self.cancel_rect
    if (y < self:px(Style.BAND) and x < self:px(80)) or (r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h) then
        UIManager:close(self)
    end
    return true
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
    if self.qr then
        self.qr:free()
        self.qr = nil
    end
    Portrait.close(self)
    UIManager:setDirty(nil, "full")
end

return TokenScreen
