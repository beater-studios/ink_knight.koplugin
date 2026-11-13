-- Pattern "download". This file is copied unchanged into every plugin that downloads files in the background, as
-- <id>/download_worker.lua: change the pattern first, then copy it again.
--
-- Runs inside a child process: downloads a list of files one by one, so the screen never waits for the network.
-- The list has one "url<TAB>path" per line. After each file the progress file gets "done failed total". A file named
-- like the progress file plus ".stop" ends the work early. After STOP_AFTER failures in a row (no Wi-Fi, the server
-- down) it gives up and ends with "stopped", so it never waits on every file. The files go through one session of the
-- HTTPS pattern, so the connection stays open between them (one TLS handshake per child, not per file), only to the
-- hosts given.
local MODULE = ...
assert(type(MODULE) == "string", "download_worker: load it with require")
local ID = MODULE:match("^(.*)/[^/]+$")
local Request = require(ID .. "/https_request")

local Worker = {}

Worker.STOP_AFTER = 8

local function write_atomic(path, text)
    local tmp = path .. ".tmp"
    local file = io.open(tmp, "wb")
    if file then
        file:write(text)
        file:close()
        os.rename(tmp, path)
    end
end

local function exists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

-- Whether a file may come from url: https, and one of the hosts, as the HTTPS pattern reads the host.
function Worker.allowed(url, hosts)
    local host = Request.host(url)
    for _, allowed in ipairs(hosts or {}) do
        if host ~= nil and host == allowed then
            return true
        end
    end
    return false
end

-- Waits, a second at a time, so a request to stop still ends the work soon.
function Worker.sleep(seconds)
    require("socket").sleep(seconds)
end

-- One file; true when it was saved, and the HTTP code. It arrives as <path>.part and gets its name only when complete.
function Worker.fetch(url, path, settings, session)
    if not Worker.allowed(url, settings.hosts) then
        return false
    end
    local headers = {}
    for name, value in pairs(settings.headers or {}) do
        headers[name:lower()] = value
    end
    headers["user-agent"] = settings.user_agent
    local spec = {
        url = url,
        headers = headers,
        ca_file = settings.ca_file,
        timeout = settings.timeout or 30,
        out_path = path .. ".part",
        code_path = path .. ".code",
    }
    local code
    if session then
        code = session:run(spec)
    else
        code = Request.run(spec)
    end
    os.remove(spec.code_path)
    if code == 200 then
        os.rename(spec.out_path, path)
        return true, code
    end
    os.remove(spec.out_path)
    return false, code
end

-- settings: list, progress, ca_file, user_agent, hosts, headers, and wait_429: the seconds to wait after a server says
-- 429 (too many requests) before trying the same file again, for servers that ask for it.
function Worker.run(settings)
    local jobs = {}
    for line in io.lines(settings.list) do
        local url, path = line:match("^([^\t]+)\t(.+)$")
        if url then
            jobs[#jobs + 1] = { url, path }
        end
    end
    local done, failed, in_a_row = 0, 0, 0
    local stopped = false
    local progress = settings.progress
    local stop_path = progress .. ".stop"
    write_atomic(progress, string.format("%d %d %d", done, failed, #jobs))
    local session = Request.session()
    for _, job in ipairs(jobs) do
        if exists(stop_path) then
            break
        end
        if exists(job[2]) then
            done = done + 1
        else
            local ok, _, code = pcall(Worker.fetch, job[1], job[2], settings, session)
            if code == 429 and settings.wait_429 then
                for _ = 1, settings.wait_429 do
                    if exists(stop_path) then
                        break
                    end
                    Worker.sleep(1)
                end
            end
            -- A second try covers a connection that dropped once, or the wait a server asked for.
            if not (ok and exists(job[2])) and not exists(stop_path) then
                ok = pcall(Worker.fetch, job[1], job[2], settings, session)
            end
            if ok and exists(job[2]) then
                done = done + 1
                in_a_row = 0
            else
                failed = failed + 1
                in_a_row = in_a_row + 1
            end
        end
        write_atomic(progress, string.format("%d %d %d", done, failed, #jobs))
        if in_a_row >= Worker.STOP_AFTER then
            stopped = true
            break
        end
    end
    session:close()
    write_atomic(progress, string.format("%d %d %d end%s", done, failed, #jobs, stopped and " stopped" or ""))
end

return Worker
