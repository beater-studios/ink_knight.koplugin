package.path = "./?.lua;" .. package.path
-- The server only needs these from LuaSocket, so the tests run without a network.
package.loaded.socket = package.loaded.socket or { gettime = os.clock }
local I18n = require("ink_knight/i18n")
local Server = require("ink_knight/http_server")
local TokenAccess = require("ink_knight/token_access")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAILED: " .. name .. "\n  " .. tostring(err))
    end
end
local function eq(actual, expected)
    if actual ~= expected then
        error(string.format("expected %s, got %s", tostring(expected), tostring(actual)), 2)
    end
end

local CODE, HOST, PHONE = "abc123code", "192.168.0.5:8644", "192.168.0.20"

-- A connection that hands out what was queued in `input`, in pieces of the size asked for.
local function fake_client(ip, input)
    local client = { ip = ip, input = input or "", output = {}, closed = false }
    function client:getpeername() return self.ip end
    function client:settimeout() end
    function client:receive(size)
        if #self.input == 0 then
            if self.eof then return nil, "closed", "" end
            return nil, "timeout", ""
        end
        local chunk = self.input:sub(1, size)
        self.input = self.input:sub(size + 1)
        if #chunk == size then return chunk end
        return nil, "timeout", chunk
    end
    function client:send(data, first)
        first = first or 1
        self.output[#self.output + 1] = data:sub(first)
        return #data
    end
    function client:close() self.closed = true end
    function client:response() return table.concat(self.output) end
    return client
end

local function new_server(opts)
    opts = opts or {}
    local got = {}
    local access = TokenAccess.new{
        code = CODE, host = HOST, strings = I18n.en,
        on_new_client = function(ip) got.client = ip end,
        on_token = function(token) got.token = token end,
    }
    local server = Server.new{ access = access, ip = "192.168.0.5", port = 8644, name = "Ink Knight", log = opts.log or function() end }
    local queue = {}
    server.listener = {
        accept = function() return table.remove(queue, 1) end,
        close = function() end,
    }
    server.queue = queue
    return server, access, got
end

local function request(path, method, extra)
    return string.format("%s /%s%s HTTP/1.1\r\nHost: %s\r\n%s\r\n", method or "GET", CODE, path, HOST, extra or "")
end

local function approve(access)
    access:handle(request("/"), PHONE)
    access:approve(PHONE)
end

local function connect(server, client)
    table.insert(server.queue, client)
    return client
end

local function ticks(server, count)
    for _ = 1, count or 20 do server:tick() end
end

local function from(server, ip)
    local count = 0
    for _, conn in ipairs(server.connections) do
        if conn.ip == ip then count = count + 1 end
    end
    return count
end

local function post(body, extra)
    return request("/save", "POST", string.format("Content-Length: %d\r\n%s", #body, extra or "")) .. body
end

test("other addresses cannot take the places of the device in use", function()
    local server, access = new_server()
    approve(access)
    for host = 101, 106 do
        for _ = 1, 3 do connect(server, fake_client("192.168.0." .. host)) end
    end
    ticks(server, 30)
    eq(#server.connections, 6)
    for _ = 1, 6 do connect(server, fake_client(PHONE)) end
    ticks(server, 10)
    eq(from(server, PHONE), 6)
end)

test("a blocked address is dropped as soon as it connects", function()
    local server, access = new_server()
    approve(access)
    access:deny("192.168.0.99")
    local client = connect(server, fake_client("192.168.0.99"))
    ticks(server, 2)
    eq(client.closed, true)
    eq(from(server, "192.168.0.99"), 0)
end)

test("the token comes in a form, and the answer does not repeat it", function()
    local server, access, got = new_server()
    approve(access)
    local client = connect(server, fake_client(PHONE, post("token=lip_abcdefgh123")))
    ticks(server, 10)
    eq(got.token, "lip_abcdefgh123")
    local response = client:response()
    eq(response:find("HTTP/1.1 200 OK", 1, true), 1)
    eq(response:find("lip_abcdefgh123", 1, true), nil)
    eq(client.closed, true)
end)

test("a form that arrives in pieces is read whole", function()
    local server, access, got = new_server()
    approve(access)
    local whole = post("token=lip_abcdefgh123")
    local client = connect(server, fake_client(PHONE, whole:sub(1, #whole - 8)))
    ticks(server, 5)
    eq(got.token, nil)
    client.input = whole:sub(#whole - 7)
    ticks(server, 5)
    eq(got.token, "lip_abcdefgh123")
end)

test("a form from a device not approved is never read", function()
    local server, access, got = new_server()
    approve(access)
    local client = connect(server, fake_client("192.168.0.99", post("token=lip_abcdefgh123")))
    ticks(server, 10)
    eq(got.token, nil)
    eq(client:response():find("HTTP/1.1 404", 1, true), 1)
end)

test("a body longer than the page accepts closes the connection without an answer", function()
    local server, access, got = new_server()
    approve(access)
    local client = connect(server, fake_client(PHONE, request("/save", "POST", "Content-Length: 99999\r\n") .. "token=x"))
    ticks(server, 10)
    eq(client.closed, true)
    eq(#client:response(), 0)
    eq(got.token, nil)
end)

test("an error in a request ends only that connection, and is logged without the request", function()
    local logged = {}
    local server, access = new_server{ log = function(...) logged[#logged + 1] = table.concat({ ... }, " ") end }
    approve(access)
    local form_page = access.form_page
    access.form_page = function() error("broken page") end
    local broken = connect(server, fake_client(PHONE, request("/")))
    ticks(server, 5)
    access.form_page = form_page
    local fine = connect(server, fake_client(PHONE, request("/")))
    ticks(server, 5)
    eq(broken.closed, true)
    eq(#broken:response(), 0)
    eq(fine:response():find("HTTP/1.1 200 OK", 1, true), 1)
    eq(#logged, 1)
    eq(logged[1]:find("broken page", 1, true) ~= nil, true)
    eq(logged[1]:find(CODE, 1, true), nil)
end)

test("only the approved device keeps the page open", function()
    local server, access = new_server()
    access:handle(request("/"), PHONE)
    local before = server.last_activity
    server.last_activity = before - 100
    connect(server, fake_client("192.168.0.99", request("/")))
    ticks(server, 5)
    eq(server.last_activity, before - 100)
    access:approve(PHONE)
    connect(server, fake_client(PHONE, request("/")))
    ticks(server, 5)
    eq(server.last_activity >= before, true)
end)

-- os.time stands in for the clock, so a test can let seconds pass without waiting for them.
local function with_clock(fn)
    local real_time, now = os.time, os.time()
    os.time = function(date) return date and real_time(date) or now end
    local ok, err = pcall(fn, function(seconds) now = now + seconds end)
    os.time = real_time
    if not ok then error(err, 0) end
end

test("a connection that sends no request is closed after its deadline", function()
    with_clock(function(advance)
        local server = new_server()
        local silent = connect(server, fake_client(PHONE))
        for _ = 1, 9 do advance(1); server:tick() end
        eq(silent.closed, false)
        for _ = 1, 3 do advance(1); server:tick() end
        eq(silent.closed, true)
        eq(#server.connections, 0)
    end)
end)

test("a request head larger than the limit is closed without reaching the access", function()
    local server, access = new_server()
    approve(access)
    local reached = 0
    local handle = access.handle
    access.handle = function(...) reached = reached + 1; return handle(...) end
    local client = connect(server, fake_client(PHONE, "GET /" .. CODE .. "/ HTTP/1.1\r\nX: " .. string.rep("a", TokenAccess.MAX_REQUEST_BYTES + 10)))
    ticks(server, 20)
    eq(client.closed, true)
    eq(#client:response(), 0)
    eq(reached, 0)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
