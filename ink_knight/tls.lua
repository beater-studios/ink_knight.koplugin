-- Pattern "https". This file is copied unchanged into every
-- plugin that makes requests to the internet, as <id>/tls.lua: change the pattern first, then copy it again.
--
-- The secure connection of every request. KOReader's own HTTPS module only checks the name of the server in
-- recent versions, and without that any valid certificate, for any site, would be accepted. So the check lives
-- here, the same on every version.
local Tls = {}

local function name_matches(pattern, host)
    pattern, host = pattern:lower(), host:lower()
    if pattern == host then
        return true
    end
    -- A wildcard stands for one whole label on the left, and never for a top-level domain.
    local parent = pattern:match("^%*%.(.+)$")
    if not parent or not parent:find(".", 1, true) then
        return false
    end
    local rest = host:match("^[^.]+%.(.+)$")
    return rest == parent
end

function Tls.host_matches(names, host)
    if type(host) ~= "string" or host == "" then
        return false
    end
    for _, name in ipairs(names or {}) do
        if name_matches(name, host) then
            return true
        end
    end
    return false
end

-- Only the alternative names count. The common name is out of use, and a certificate without them is refused.
function Tls.certificate_names(certificate)
    local extensions = certificate and certificate:extensions()
    local alternatives = extensions and extensions["2.5.29.17"]
    return alternatives and alternatives.dNSName or {}
end

-- One context per list of certificates, kept for the life of the process. Building it reads the whole list,
-- which takes 220 to 300 ms on the Kindle, more than the handshake itself; ssl.wrap with a table of
-- parameters would build a new one for every connection.
local contexts = {}

function Tls.context(ca_file)
    local key = ca_file or ""
    local ctx = contexts[key]
    if not ctx then
        local err
        ctx, err = require("ssl").newcontext({
            mode = "client",
            protocol = "any",
            options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
            verify = "peer",
            cafile = ca_file,
        })
        if not ctx then
            return nil, err
        end
        contexts[key] = ctx
    end
    return ctx
end

-- What LuaSocket calls to open a connection. opts: ca_file, timeout.
function Tls.create(opts)
    local socket = require("socket")
    local ssl = require("ssl")
    local try = socket.try
    return function()
        local conn = { sock = try(socket.tcp()) }
        local set_timeout = getmetatable(conn.sock).__index.settimeout
        function conn:settimeout()
            return set_timeout(self.sock, opts.timeout)
        end
        function conn:connect(host, port)
            try(self.sock:connect(host, port))
            self.sock = try(ssl.wrap(self.sock, try(Tls.context(opts.ca_file))))
            self.sock:sni(host)
            self.sock:settimeout(opts.timeout)
            try(self.sock:dohandshake())
            if not Tls.host_matches(Tls.certificate_names(self.sock:getpeercertificate()), host) then
                self.sock:close()
                try(nil, "hostname does not match certificate")
            end
            for name, method in pairs(getmetatable(self.sock).__index) do
                if type(method) == "function" then
                    self[name] = function(me, ...) return method(me.sock, ...) end
                end
            end
            return 1
        end
        return conn
    end
end

return Tls
