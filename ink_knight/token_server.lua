-- The small server behind the page that receives the token. It never waits on the network.
local socket = require("socket")

local TokenAccess = require("ink_knight/token_access")

local Server = {}
Server.__index = Server

local MAX_CONNECTIONS = 6
local MAX_ACCEPTS = 4
local TIMEOUT = 15

function Server.new(opts)
    return setmetatable({ access = opts.access, ip = opts.ip, port = opts.port, connections = {}, last_activity = os.time() }, Server)
end

function Server:start()
    local listener, err = socket.bind(self.ip, self.port)
    if not listener then
        return false, err
    end
    listener:settimeout(0)
    self.listener = listener
    return true
end

function Server:stop()
    for _, conn in ipairs(self.connections) do
        conn.client:close()
    end
    self.connections = {}
    if self.listener then
        self.listener:close()
        self.listener = nil
    end
end

function Server:respond(conn, head, body)
    local result = self.access:handle(head, body, conn.ip)
    if result.close_only then
        conn.done = true
        return
    end
    conn.outgoing = TokenAccess.response_head(result, #result.body) .. result.body
    conn.sent = 0
    if conn.ip == self.access.client_ip then
        self.last_activity = os.time()
    end
end

function Server:step(conn)
    if conn.outgoing then
        local last, err, partial = conn.client:send(conn.outgoing, conn.sent + 1)
        conn.sent = last or partial or conn.sent
        if conn.sent >= #conn.outgoing or err == "closed" then
            conn.done = true
        end
        return
    end
    local data, err, partial = conn.client:receive(1024)
    local received = data or partial
    if received and #received > 0 then
        conn.buffer = conn.buffer .. received
    end
    local _, head_end = conn.buffer:find("\r?\n\r?\n")
    if head_end then
        local head = conn.buffer:sub(1, head_end)
        local size = tonumber(head:match("\n[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%-[Ll][Ee][Nn][Gg][Tt][Hh]:[ \t]*(%d+)")) or 0
        if size > TokenAccess.MAX_BODY_BYTES then
            conn.done = true
        elseif #conn.buffer - head_end >= size then
            self:respond(conn, head, conn.buffer:sub(head_end + 1, head_end + size))
        end
    elseif #conn.buffer > TokenAccess.MAX_REQUEST_BYTES then
        conn.done = true
    end
    if err == "closed" then
        conn.done = true
    end
end

function Server:tick()
    if not self.listener then
        return
    end
    for _ = 1, MAX_ACCEPTS do
        local client = self.listener:accept()
        if not client then
            break
        end
        client:settimeout(0)
        local ip = client:getpeername()
        if self.access:is_denied(ip) or #self.connections >= MAX_CONNECTIONS then
            client:close()
        else
            table.insert(self.connections, { client = client, ip = ip, buffer = "", deadline = os.time() + TIMEOUT })
        end
    end
    local now = os.time()
    for index = #self.connections, 1, -1 do
        local conn = self.connections[index]
        -- An error in one request ends that connection only, and is not logged, because it could carry the token.
        local ok = pcall(self.step, self, conn)
        if not ok or conn.done or now > conn.deadline then
            conn.client:close()
            table.remove(self.connections, index)
        end
    end
end

return Server
