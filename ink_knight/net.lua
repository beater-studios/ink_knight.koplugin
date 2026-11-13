-- Talks to Lichess through child processes, so a TLS handshake or a slow network never freezes the screen.
-- Each request writes to its own files, which tick() reads without waiting. The child processes, the
-- connection and the files are the ones of https_request.lua.
local Api = require("ink_knight/api")
local Request = require("ink_knight/https_request")

local Net = {}
Net.__index = Net

-- How long a silent connection may wait, and how long a request may take in all.
local REQUEST_BLOCK_TIMEOUT = 30
local REQUEST_DEADLINE = 45
local STREAM_BLOCK_TIMEOUT = 600
-- What Lichess asks for after a 429.
local RATE_LIMIT_PAUSE = 60

-- The servers of Lichess that ask for the token. The one for endgames does not, so it never gets it.
local TOKEN_HOSTS = {
    [Request.host(Api.BASE)] = true,
    [Request.host(Api.EXPLORER)] = true,
}

local function exists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

local function quote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

-- opts: token, dir (private folder for the files), version, ca_file, and for the tests
-- spawn(spec), done(pid, wait), kill(pid), file_size(path), shell(command) and clock().
-- on_request() is called whenever a request joins the queue, so the screen can check sooner.
-- on_unauthorized() is called before on_done when Lichess refuses the token.
function Net.new(opts)
    return setmetatable({
        token = opts.token,
        dir = opts.dir,
        version = opts.version or "0",
        ca_file = opts.ca_file or Request.CA_FILE,
        spawn = opts.spawn or Request.spawn,
        done = opts.done or Request.done,
        kill = opts.kill or Request.kill,
        file_size = opts.file_size or Net.file_size,
        shell = opts.shell or os.execute,
        clock = opts.clock or os.time,
        on_request = opts.on_request,
        on_unauthorized = opts.on_unauthorized,
        queue = {},
        streams = {},
        finished = {},
        serial = 0,
    }, Net)
end

function Net.file_size(path)
    return require("libs/libkoreader-lfs").attributes(path, "size")
end

-- Without the certificates there is no way to know who is on the other side, so it does not start at all.
function Net:start()
    if not self.token:match("^[%w_]+$") or not exists(self.ca_file) then
        return false
    end
    -- KOReader's LuaJIT answers with the exit code, as Lua 5.1 does, and Lua 5.2 with true or nil: both are taken.
    local result = self.shell(string.format("mkdir -p %s && chmod 700 %s", quote(self.dir), quote(self.dir)))
    if result ~= 0 and result ~= true then
        return false
    end
    -- A connection that was killed can leave its files behind.
    self.shell("rm -f " .. quote(self.dir) .. "/r[0-9]*")
    return true
end

function Net:next_prefix()
    self.serial = self.serial + 1
    return string.format("%s/r%d", self.dir, self.serial)
end

local function url_of(request)
    return (request.base or Api.BASE) .. request.path
end

-- The token only ever goes to the servers of Lichess that ask for it. The server is the one LuaSocket will
-- connect to, read by Request.host, never by a pattern of this file.
local function sends_token(request)
    local host = Request.host(url_of(request))
    return host ~= nil and TOKEN_HOSTS[host] == true
end

function Net:build_spec(request, prefix, accept, timeout)
    local headers = {
        ["user-agent"] = "InkKnight/" .. self.version,
        accept = request.accept or accept,
    }
    if sends_token(request) then
        headers.authorization = "Bearer " .. self.token
    end
    if request.body then
        headers["content-length"] = tostring(#request.body)
        headers["content-type"] = request.content_type or "application/x-www-form-urlencoded"
    elseif request.method == "POST" then
        headers["content-length"] = "0"
    end
    local paths = Request.paths(prefix)
    return {
        url = url_of(request),
        method = request.method,
        headers = headers,
        body = request.body,
        timeout = timeout,
        ca_file = self.ca_file,
        out_path = paths.out_path,
        code_path = paths.code_path,
        -- Lichess states what the token may do in a header of the answer about the account.
        headers_path = request.want_scopes and paths.headers_path or nil,
    }
end

function Net:launch_request(job)
    job.prefix = self:next_prefix()
    job.deadline = self.clock() + REQUEST_DEADLINE
    job.spec = self:build_spec(job.request, job.prefix, "application/json", REQUEST_BLOCK_TIMEOUT)
    local pid = self.spawn(job.spec)
    job.pid = pid or nil
end

-- Every file a request may leave, also the headers of one that did not ask for them.
function Net:cleanup(prefix)
    Request.remove(Request.paths(prefix))
end

-- A child that ended still has to be collected, or it stays listed as a zombie.
function Net:collect(pid)
    if pid then
        self.finished[#self.finished + 1] = pid
    end
end

function Net:reap()
    for index = #self.finished, 1, -1 do
        if self.done(self.finished[index]) then
            table.remove(self.finished, index)
        end
    end
end

-- on_done(status, body, scopes): status is the HTTP code, or nil when the request did not get an answer.
-- scopes is the list Lichess states for the token (the x-oauth-scopes header), only for a request with want_scopes.
function Net:request(request, on_done)
    table.insert(self.queue, { request = request, on_done = on_done })
    if self.on_request then
        self.on_request()
    end
end

-- on_line(text) gets each line of the answer. on_end(status) is called once when the connection ends by itself,
-- with the HTTP code, or nil when there was no answer.
function Net:stream(request, on_line, on_end)
    local prefix = self:next_prefix()
    local pid = self.spawn(self:build_spec(request, prefix, "application/x-ndjson", STREAM_BLOCK_TIMEOUT))
    local stream = { prefix = prefix, pid = pid or nil, on_line = on_line, on_end = on_end, offset = 0, partial = "" }
    table.insert(self.streams, stream)
    return stream
end

function Net:close_stream(stream)
    for index, other in ipairs(self.streams) do
        if other == stream then
            table.remove(self.streams, index)
            break
        end
    end
    if stream.pid then
        self.kill(stream.pid)
        self:collect(stream.pid)
    end
    self:cleanup(stream.prefix)
end

-- This runs for each stream on every tick, and on a Kindle waking up to open a file costs about 30 ms,
-- so the file is only opened after its size says there is something new.
function Net:read_stream(stream)
    local path = Request.paths(stream.prefix).out_path
    if (self.file_size(path) or 0) <= stream.offset then
        return
    end
    local file = io.open(path, "rb")
    if file then
        file:seek("set", stream.offset)
        local data = file:read("*a")
        file:close()
        if data and #data > 0 then
            stream.offset = stream.offset + #data
            stream.partial = stream.partial .. data
            while true do
                local line, rest = stream.partial:match("^([^\n]*)\n(.*)$")
                if not line then
                    break
                end
                stream.partial = rest
                -- Lichess sends empty lines to keep the connection open.
                if line:match("%S") then
                    stream.on_line(line)
                end
            end
        end
    end
end

function Net:finish_request()
    local job = self.current
    self.current = nil
    local code, body, headers = Request.result(job.spec)
    local scopes = job.request.want_scopes and headers and headers["x-oauth-scopes"] or nil
    self:collect(job.pid)
    self:cleanup(job.prefix)
    if code == 429 then
        self.paused_until = self.clock() + RATE_LIMIT_PAUSE
    end
    if code == 401 and self.on_unauthorized and sends_token(job.request) then
        self.on_unauthorized()
    end
    if job.on_done then
        job.on_done(code, body, scopes)
    end
end

-- Covers a child that finished and one that crashed: what it managed to write tells them apart.
function Net:has_ended(pid)
    return not pid or self.done(pid)
end

-- Called repeatedly by the screen. Lichess asks for one request at a time, so they run in order.
function Net:tick()
    self:reap()
    if self.current then
        if self:has_ended(self.current.pid) then
            self:finish_request()
        elseif self.clock() >= self.current.deadline then
            self.kill(self.current.pid)
            self:finish_request()
        end
    end
    if not self.current and #self.queue > 0 and (not self.paused_until or self.clock() >= self.paused_until) then
        self.current = table.remove(self.queue, 1)
        self:launch_request(self.current)
    end
    for index = #self.streams, 1, -1 do
        local stream = self.streams[index]
        if stream then
            self:read_stream(stream)
            if self.streams[index] == stream and self:has_ended(stream.pid) then
                self:read_stream(stream)
                -- The last line may have no line break after it.
                if stream.partial:match("%S") then
                    stream.on_line(stream.partial)
                end
                stream.partial = ""
                local file = io.open(Request.paths(stream.prefix).code_path, "rb")
                local code = file and tonumber(file:read("*a") or "")
                if file then
                    file:close()
                end
                table.remove(self.streams, index)
                self:collect(stream.pid)
                self:cleanup(stream.prefix)
                if stream.on_end then
                    stream.on_end(code ~= 0 and code or nil)
                end
            end
        end
    end
end

-- An open stream does not count: it may stay open for hours, and its lines can wait for a slower tick.
function Net:has_pending_request()
    return self.current ~= nil or #self.queue > 0
end

-- Ends everything, waits for the children to go, and removes the files.
function Net:stop()
    while #self.streams > 0 do
        self:close_stream(self.streams[1])
    end
    if self.current then
        if self.current.pid then
            self.kill(self.current.pid)
            self:collect(self.current.pid)
        end
        self:cleanup(self.current.prefix)
        self.current = nil
    end
    self.queue = {}
    for _, pid in ipairs(self.finished) do
        self.done(pid, true)
    end
    self.finished = {}
end

return Net
