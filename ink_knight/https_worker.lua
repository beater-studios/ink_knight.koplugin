-- Runs inside a child process: one HTTPS request, written to files that the screen reads without waiting.
-- This is the only place that holds a connection open, so the wait never reaches the interface.
local http = require("socket.http")
local ltn12 = require("ltn12")
local url = require("socket.url")

local Tls = require("ink_knight/tls")

local Worker = {}

local function write_file(path, text)
    local file = io.open(path, "wb")
    if file then
        file:write(text)
        file:close()
    end
end

-- spec: url, method, headers, body, timeout, ca_file, and the paths out_path, code_path and, when asked, scopes_path.
-- Returns the HTTP code, or the reason there is none.
function Worker.run(spec)
    local out = assert(io.open(spec.out_path, "wb"))
    -- Each piece goes straight to the file, so a stream can be read while it still arrives.
    local function sink(chunk)
        if chunk then
            out:write(chunk)
            out:flush()
        end
        return 1
    end
    -- A proxy set in KOReader would see the request, token included, so it is never used here.
    http.PROXY = nil
    local _, code, headers = http.request{
        url = url.build(url.parse(spec.url, { port = 443 })),
        method = spec.method,
        headers = spec.headers,
        source = spec.body and ltn12.source.string(spec.body) or nil,
        sink = sink,
        create = Tls.create{ ca_file = spec.ca_file, timeout = spec.timeout },
        -- A redirect would carry the token somewhere else.
        redirect = false,
    }
    out:close()
    if spec.scopes_path and type(headers) == "table" and headers["x-oauth-scopes"] then
        write_file(spec.scopes_path, headers["x-oauth-scopes"])
    end
    write_file(spec.code_path, type(code) == "number" and tostring(code) or "0")
    return code
end

return Worker
