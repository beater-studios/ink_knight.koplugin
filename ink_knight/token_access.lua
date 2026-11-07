-- Decides what each request gets on the page that receives the token. No network and no disk here, so each rule can be tested.
local TokenAccess = {}
TokenAccess.__index = TokenAccess

TokenAccess.MAX_BAD_REQUESTS = 20
TokenAccess.MAX_REQUEST_BYTES = 8192
TokenAccess.MAX_BODY_BYTES = 512

local function escape_html(text)
    return (tostring(text):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;",
    }))
end

function TokenAccess.is_private_ip(ip)
    local a, b = tostring(ip):match("^(%d+)%.(%d+)%.%d+%.%d+$")
    a, b = tonumber(a), tonumber(b)
    if not a then
        return false
    end
    return a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168)
end

function TokenAccess.is_valid_token(token)
    return type(token) == "string" and #token >= 8 and #token <= 128 and token:match("^lip_[%w_]+$") ~= nil
end

-- opts: code (the secret in the address), host (the "ip:port" this server answers to), strings, on_new_client(ip), on_token(token).
function TokenAccess.new(opts)
    return setmetatable({
        code = opts.code,
        host = opts.host,
        strings = opts.strings,
        on_new_client = opts.on_new_client,
        on_token = opts.on_token,
        denied = {},
        strikes = {},
    }, TokenAccess)
end

function TokenAccess:approve(ip)
    if self.pending_ip == ip then
        self.client_ip, self.pending_ip = ip, nil
    end
end

function TokenAccess:deny(ip)
    self.denied[ip] = true
    if self.pending_ip == ip then
        self.pending_ip = nil
    end
end

function TokenAccess:is_denied(ip)
    return self.denied[ip] == true
end

function TokenAccess:reject(ip)
    if ip ~= self.client_ip then
        self.strikes[ip] = (self.strikes[ip] or 0) + 1
        if self.strikes[ip] >= TokenAccess.MAX_BAD_REQUESTS then
            self.denied[ip] = true
        end
    end
    return { status = 404, body = self.strings.not_found, content_type = "text/plain; charset=utf-8" }
end

function TokenAccess:page(title, body, refresh)
    return {
        status = 200,
        content_type = "text/html; charset=utf-8",
        body = table.concat{
            string.format('<!doctype html><html lang="%s"><head><meta charset="utf-8">', self.strings.html_lang),
            '<meta name="viewport" content="width=device-width, initial-scale=1">',
            refresh and '<meta http-equiv="refresh" content="2">' or "",
            '<link rel="icon" href="data:,"><title>', escape_html(title), "</title><style>",
            "body{font-family:system-ui,sans-serif;margin:0 auto;max-width:460px;padding:20px;color:#111;background:#fff;line-height:1.45}",
            "h1{font-size:24px;margin:8px 0}label{display:block;margin:18px 0 6px;font-weight:600}",
            "input{display:block;width:100%;box-sizing:border-box;font-size:16px;padding:12px;border:2px solid #111;border-radius:8px}",
            "button{display:block;width:100%;margin:14px 0;padding:14px;font:600 16px system-ui,sans-serif;color:#fff;background:#111;border:0;border-radius:8px}",
            ".bad{color:#a00;font-weight:600}",
            "</style></head><body>", body, "</body></html>",
        },
    }
end

function TokenAccess:form_page(problem)
    local s = self.strings
    return self:page(s.token_page_title, table.concat{
        "<h1>", escape_html(s.token_page_title), "</h1><p>", escape_html(s.token_page_text), "</p>",
        problem and ('<p class="bad">' .. escape_html(problem) .. "</p>") or "",
        string.format('<form method="post" action="/%s/save" autocomplete="off">', self.code),
        '<label for="t">', escape_html(s.token_page_label), "</label>",
        '<input id="t" name="token" type="password" required autocapitalize="off" autocorrect="off" spellcheck="false" maxlength="128">',
        "<button>", escape_html(s.token_page_button), "</button></form>",
    })
end

local function form_value(body, key)
    for pair in tostring(body):gmatch("[^&]+") do
        local name, value = pair:match("^([^=]*)=(.*)$")
        if name == key then
            return (value:gsub("%+", " "):gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
        end
    end
end

-- request: the raw head. body: what came after it. ip: the address of the connection.
function TokenAccess:handle(request, body, ip)
    if self.denied[ip] then
        return { status = 503, body = "", content_type = "text/plain", close_only = true }
    end
    if #request > TokenAccess.MAX_REQUEST_BYTES or not TokenAccess.is_private_ip(ip) then
        return self:reject(ip)
    end
    local method, target = request:match("^(%u+) ([^%s]+) HTTP/1%.[01]\r?\n")
    if method ~= "GET" and method ~= "POST" then
        return self:reject(ip)
    end
    local host = request:match("\n[Hh][Oo][Ss][Tt]:[ \t]*([^\r\n]+)")
    if host ~= self.host then
        return self:reject(ip)
    end
    local code, rest = target:match("^/([%w]+)(/?.*)$")
    if code ~= self.code then
        return self:reject(ip)
    end
    if not self.client_ip then
        if method ~= "GET" then
            return self:reject(ip)
        end
        if not self.pending_ip then
            self.pending_ip = ip
            self.on_new_client(ip)
        end
        if self.pending_ip ~= ip then
            return self:reject(ip)
        end
        return self:page(self.strings.token_page_title, string.format("<h1>%s</h1><p>%s</p>", escape_html(self.strings.confirm_heading), escape_html(self.strings.confirm_text)), true)
    end
    if ip ~= self.client_ip then
        return self:reject(ip)
    end
    if method == "GET" and (rest == "" or rest == "/") then
        return self:form_page()
    end
    if method == "POST" and rest == "/save" then
        -- Another site's page could post here, so the origin must be this page when the browser says it.
        local origin = request:match("\n[Oo][Rr][Ii][Gg][Ii][Nn]:[ \t]*([^\r\n]+)")
        if origin and origin ~= "http://" .. self.host then
            return self:reject(ip)
        end
        local token = form_value(body, "token")
        token = token and token:gsub("^%s+", ""):gsub("%s+$", "")
        if not TokenAccess.is_valid_token(token) then
            return self:form_page(self.strings.token_invalid)
        end
        self.on_token(token)
        return self:page(self.strings.token_page_title, string.format("<h1>%s</h1><p>%s</p>", escape_html(self.strings.token_saved_heading), escape_html(self.strings.token_saved_text)))
    end
    return self:reject(ip)
end

local STATUS_TEXT = { [200] = "OK", [404] = "Not Found", [503] = "Service Unavailable" }

function TokenAccess.response_head(result, size)
    return table.concat({
        string.format("HTTP/1.1 %d %s", result.status, STATUS_TEXT[result.status] or "Error"),
        "Content-Type: " .. result.content_type,
        "Content-Length: " .. size,
        "Connection: close",
        "Cache-Control: no-store",
        -- With no-referrer, a browser sends "Origin: null" when posting the form, and the page refuses its own form.
        "Referrer-Policy: same-origin",
        "X-Content-Type-Options: nosniff",
        "X-Frame-Options: DENY",
        "Content-Security-Policy: default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'self'",
    }, "\r\n") .. "\r\n\r\n"
end

return TokenAccess
