-- Pattern "https". This file is copied unchanged into every
-- plugin that makes requests to the internet, as <id>/https_request.lua: change the pattern first, then copy
-- it again.
--
-- One HTTPS request in a child process, written to files that the screen reads without waiting, so a TLS
-- handshake or a slow network never freezes the interface. The child is the only place that holds a
-- connection open.
--
-- spec: url, method, headers, body, timeout (seconds a silent connection may wait), ca_file, and the files
-- out_path (the body), code_path (the HTTP code, written last) and, when wanted, headers_path (the response
-- headers as JSON). Request.paths(prefix) gives the three files for a prefix.
local MODULE = ...
assert(type(MODULE) == "string", "https_request: load it with require")
local ID = MODULE:match("^(.*)/[^/]+$")
local PLUGIN_DIR = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("/[^/]+/[^/]+$", "")

local Request = {}

-- Where KOReader keeps the certificates it trusts, relative to its own folder.
Request.CA_FILE = "data/ca-bundle.crt"

local function read_file(path)
    local file = path and io.open(path, "rb")
    if not file then
        return nil
    end
    local data = file:read("*a")
    file:close()
    return data
end

local function write_file(path, text)
    local file = io.open(path, "wb")
    if file then
        file:write(text)
        file:close()
    end
end

local function quote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function is_macos()
    return jit and jit.os == "OSX"
end

function Request.paths(prefix)
    return { out_path = prefix .. ".out", code_path = prefix .. ".code", headers_path = prefix .. ".headers" }
end

-- The host of an https:// address, in lowercase, or nil for any other form: another scheme, credentials
-- before the host, an IPv6 literal or any character a host name does not have. Decide which servers get the
-- credentials with this, never with a pattern of your own: LuaSocket reads "https://a.org:x@b.org/" as b.org.
function Request.host(address)
    if type(address) ~= "string" then
        return nil
    end
    local host, port, rest = address:match("^https://([%w%.%-]+)(:?%d*)(.*)$")
    if not host or not (port == "" or port:match("^:%d+$")) or not (rest == "" or rest:match("^[/?#]")) then
        return nil
    end
    return host:lower()
end

-- The parsed address and its host. The credentials were chosen for Request.host, so the connection must go to
-- that same host, as LuaSocket reads the address.
local function target(spec)
    local url = require("socket.url")
    local host = Request.host(spec.url)
    local parsed = host and url.parse(spec.url, { port = 443 })
    if not parsed or parsed.userinfo or type(parsed.host) ~= "string" or parsed.host:lower() ~= host then
        return nil, "address refused: " .. tostring(spec.url)
    end
    return parsed, host
end

local function send(spec, sink)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local url = require("socket.url")
    local Tls = require(ID .. "/tls")
    local parsed, err = target(spec)
    if not parsed then
        return nil, err
    end
    -- A proxy set in KOReader would see the request, credentials included, so it is never used here.
    http.PROXY = nil
    return http.request({
        url = url.build(parsed),
        method = spec.method or "GET",
        headers = spec.headers,
        source = spec.body and ltn12.source.string(spec.body) or nil,
        sink = sink,
        create = Tls.create{ ca_file = spec.ca_file or Request.CA_FILE, timeout = spec.timeout or 30 },
        -- A redirect would carry the headers, credentials included, to wherever the answer points.
        redirect = false,
    })
end

-- Runs inside the child. Returns the HTTP code, or the reason there is none. Whatever fails on the way, the
-- code file is written last, so the screen is never left waiting.
function Request.run(spec)
    local out
    local ok, first, code, headers = pcall(function()
        out = assert(io.open(spec.out_path, "wb"))
        -- Each piece goes straight to the file, so a long answer can be read while it still arrives.
        return send(spec, function(chunk)
            if chunk then
                out:write(chunk)
                out:flush()
            end
            return 1
        end)
    end)
    if out then
        out:close()
    end
    if not ok then
        code = first
    end
    if ok and spec.headers_path and type(headers) == "table" then
        pcall(function() write_file(spec.headers_path, require("rapidjson").encode(headers)) end)
    end
    write_file(spec.code_path, type(code) == "number" and tostring(code) or "0")
    return code
end

-- A batch of requests in one child keeps the connection open between them (HTTP/1.1), so the TCP and TLS
-- handshakes happen once per server instead of once per request. Only for answers of known length that end:
-- a stream that never closes belongs to Request.run.

-- The request as sent. Exposed for the tests. A header with a line break would let one header write others,
-- so it is refused.
function Request.request_text(spec, parsed, host, port)
    local path = parsed.path or ""
    if path == "" then
        path = "/"
    end
    if parsed.params then
        path = path .. ";" .. parsed.params
    end
    if parsed.query then
        path = path .. "?" .. parsed.query
    end
    local lines = { (spec.method or "GET"):upper() .. " " .. path .. " HTTP/1.1",
        "host: " .. host .. (port ~= 443 and (":" .. port) or "") }
    for name, value in pairs(spec.headers or {}) do
        name, value = tostring(name), tostring(value)
        if name:find("[%c:]") or value:find("[\r\n]") then
            return nil, "header refused: " .. name
        end
        local lower = name:lower()
        if lower ~= "host" and lower ~= "connection" and lower ~= "content-length" and lower ~= "transfer-encoding" then
            lines[#lines + 1] = name .. ": " .. value
        end
    end
    if spec.body then
        lines[#lines + 1] = "content-length: " .. #spec.body
    end
    lines[#lines + 1] = "connection: keep-alive"
    return table.concat(lines, "\r\n") .. "\r\n\r\n" .. (spec.body or "")
end

local function read_exact(conn, size, sink)
    local left = size
    while left > 0 do
        local piece, err = conn:receive(math.min(left, 16384))
        if not piece then
            return nil, err
        end
        sink(piece)
        left = left - #piece
    end
    return true
end

-- Reads one answer from an open connection, the body going to sink(piece). Exposed for the tests. Returns the
-- code, the headers (names in lowercase, repeated ones joined with ", ", as LuaSocket gives them) and whether
-- the connection can take the next request; or nil, the reason and whether the status line had arrived.
function Request.read_response(conn, method, sink)
    local status, err = conn:receive("*l")
    if not status then
        return nil, err, false
    end
    local version, code = status:match("^HTTP/(%d%.%d) (%d%d%d)")
    if not code then
        return nil, "bad status line", true
    end
    code = tonumber(code)
    local headers = {}
    while true do
        local line, e = conn:receive("*l")
        if not line then
            return nil, e, true
        end
        if line == "" then
            break
        end
        local name, value = line:match("^([^:%s]+):%s*(.-)%s*$")
        if not name then
            return nil, "bad header", true
        end
        name = name:lower()
        headers[name] = headers[name] and (headers[name] .. ", " .. value) or value
    end
    -- An informational answer (103 Early Hints, for one) comes before the real one, on the same request.
    if code < 200 and code ~= 101 then
        return Request.read_response(conn, method, sink)
    end
    local keep = version == "1.1" and not (headers.connection or ""):lower():find("close", 1, true)
    if method == "HEAD" or code == 204 or code == 304 or code < 200 then
        return code, headers, keep and code >= 200
    end
    if (headers["transfer-encoding"] or ""):lower():find("chunked", 1, true) then
        while true do
            local size_line, e = conn:receive("*l")
            if not size_line then
                return nil, e, true
            end
            local size = tonumber(size_line:match("^%s*(%x+)%s*[;]?") or "", 16)
            if not size then
                return nil, "bad chunk", true
            end
            if size == 0 then
                repeat
                    local trailer, e2 = conn:receive("*l")
                    if not trailer then
                        return nil, e2, true
                    end
                until trailer == ""
                break
            end
            local ok, e2 = read_exact(conn, size, sink)
            if not ok then
                return nil, e2, true
            end
            local crlf, e3 = conn:receive(2)
            if crlf ~= "\r\n" then
                return nil, e3 or "bad chunk", true
            end
        end
    elseif headers["content-length"] then
        -- Two different lengths would mean two readings of where the answer ends, so they are refused.
        local size = headers["content-length"]:match("^%d+$") and tonumber(headers["content-length"])
        if not size then
            return nil, "bad content-length", true
        end
        local ok, e = read_exact(conn, size, sink)
        if not ok then
            return nil, e, true
        end
    else
        -- Without a length the answer ends when the server closes, and the connection goes with it.
        while true do
            local piece, e, partial = conn:receive(16384)
            local data = piece or partial
            if data and #data > 0 then
                sink(data)
            end
            if not piece then
                if e ~= "closed" then
                    return nil, e, true
                end
                break
            end
        end
        keep = false
    end
    return code, headers, keep
end

local Session = {}
Session.__index = Session

-- A session lives inside one child. connections counts the connections it opened.
function Request.session()
    return setmetatable({ connections = 0 }, Session)
end

function Session:close()
    if self.conn then
        pcall(self.conn.close, self.conn)
    end
    self.conn, self.key = nil, nil
end

-- A refused handshake leaves the socket open, and a batch has hundreds of them, so it is closed here.
local function open(spec, host, port)
    local socket = require("socket")
    local Tls = require(ID .. "/tls")
    local conn
    local ok, err = socket.protect(function()
        conn = Tls.create{ ca_file = spec.ca_file or Request.CA_FILE, timeout = spec.timeout or 30 }()
        conn:settimeout()
        conn:connect(host, port)
        return true
    end)()
    if not ok then
        if conn and conn.sock then
            pcall(conn.sock.close, conn.sock)
        end
        return nil, err
    end
    return conn
end

-- Returns the code and the headers, or nil and the reason. A connection kept from an earlier request may have
-- been closed by the server meanwhile: then a GET or HEAD that got nothing back is sent once more on a new
-- connection. Anything else is never sent twice.
function Session:exchange(spec, sink)
    local parsed, host = target(spec)
    if not parsed then
        return nil, host
    end
    local port = tonumber(parsed.port) or 443
    local text, err = Request.request_text(spec, parsed, host, port)
    if not text then
        return nil, err
    end
    local method = (spec.method or "GET"):upper()
    local key = table.concat({ host, port, spec.ca_file or Request.CA_FILE, spec.timeout or 30 }, "|")
    if self.key ~= key then
        self:close()
    end
    for _ = 1, 2 do
        local reused = self.conn ~= nil
        if not reused then
            local conn, e = open(spec, host, port)
            if not conn then
                return nil, e
            end
            self.conn, self.key = conn, key
            self.connections = self.connections + 1
        end
        -- A socket the server closed may raise instead of returning an error.
        local send_ok, sent, e = pcall(self.conn.send, self.conn, text)
        if not send_ok then
            sent, e = nil, sent
        end
        local started = false
        if sent then
            local got = false
            local read_ok, code, headers, keep = pcall(Request.read_response, self.conn, method, function(piece)
                got = true
                sink(piece)
            end)
            if not read_ok then
                code, headers, keep = nil, code, got
            end
            if code then
                if not keep then
                    self:close()
                end
                return code, headers
            end
            e, started = headers, keep
        end
        self:close()
        if not (reused and not started and (method == "GET" or method == "HEAD")) then
            return nil, e
        end
    end
end

-- Like Request.run, with the same files and the same result, on the connection of the session.
function Session:run(spec)
    local out
    local ok, code, headers = pcall(function()
        out = assert(io.open(spec.out_path, "wb"))
        return self:exchange(spec, function(piece)
            out:write(piece)
            out:flush()
        end)
    end)
    if out then
        out:close()
    end
    if not ok then
        self:close()
    elseif not code then
        code, headers = headers, nil
    end
    if spec.headers_path and type(code) == "number" and type(headers) == "table" then
        pcall(function() write_file(spec.headers_path, require("rapidjson").encode(headers)) end)
    end
    write_file(spec.code_path, type(code) == "number" and tostring(code) or "0")
    return code
end

-- macOS kills a forked child that touches the network, so there each request is a new program. The file with
-- the request is created readable only by the user, and the program deletes it as soon as it reads it. The
-- Kindle runs Linux and uses a forked child, where the request never reaches a file.
local function spawn_as_program(spec)
    local spec_path = spec.out_path .. ".spec"
    local pid_path = spec.out_path .. ".pid"
    os.execute("umask 077; : > " .. quote(spec_path))
    local file = io.open(spec_path, "wb")
    if not file then
        return false
    end
    file:write(require("rapidjson").encode(spec))
    file:close()
    os.execute(string.format("./luajit %s %s %s %s >/dev/null 2>&1 & echo $! > %s",
        quote(PLUGIN_DIR .. "/" .. ID .. "/https_main.lua"), quote(PLUGIN_DIR), quote(spec_path),
        quote(spec.code_path), quote(pid_path)))
    local pid = tonumber(read_file(pid_path) or "")
    os.remove(pid_path)
    return pid or false
end

-- Starts the request and returns the process, or false. Without the certificates there is no way to know who
-- is on the other side, so it does not start at all. Files left by an earlier request with the same paths are
-- removed first, so an old code is never read with a new body.
function Request.spawn(spec)
    Request.remove(spec)
    if not read_file(spec.ca_file or Request.CA_FILE) then
        return false
    end
    if is_macos() then
        return spawn_as_program(spec)
    end
    return require("ffi/util").runInSubProcess(function() Request.run(spec) end)
end

-- Whether the child ended. With wait, it waits for it. A child that ended has to be asked again until this is
-- true, or it stays listed as a zombie.
function Request.done(pid, wait)
    if is_macos() then
        local result = os.execute(string.format("kill -0 %d 2>/dev/null", pid))
        return not (result == 0 or result == true)
    end
    return require("ffi/util").isSubProcessDone(pid, wait)
end

function Request.kill(pid)
    if is_macos() then
        os.execute(string.format("kill -9 %d 2>/dev/null", pid))
        return
    end
    require("ffi/util").terminateSubProcess(pid)
end

-- After the child ended: the HTTP code (nil when there was no answer), the body and, when asked, the headers.
function Request.result(spec)
    local code = tonumber(read_file(spec.code_path) or "")
    local headers
    local text = read_file(spec.headers_path)
    if text then
        local ok, decoded = pcall(require("rapidjson").decode, text)
        headers = ok and type(decoded) == "table" and decoded or nil
    end
    return code ~= 0 and code or nil, read_file(spec.out_path) or "", headers
end

-- The files of a request, including what a killed child may leave behind.
function Request.remove(spec)
    for _, path in ipairs({ spec.out_path, spec.code_path, spec.headers_path, spec.out_path .. ".spec", spec.out_path .. ".pid" }) do
        if path then
            os.remove(path)
        end
    end
end

return Request
