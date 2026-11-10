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

local function send(spec, sink)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local url = require("socket.url")
    local Tls = require(ID .. "/tls")
    -- The credentials were chosen for Request.host, so LuaSocket must connect to that same host.
    local host = Request.host(spec.url)
    local parsed = host and url.parse(spec.url, { port = 443 })
    if not parsed or parsed.userinfo or type(parsed.host) ~= "string" or parsed.host:lower() ~= host then
        return nil, "address refused: " .. tostring(spec.url)
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
