-- Stockfish as a process of its own, spoken to in UCI. The commands go to its input through a pipe, and what it says
-- goes to a file the screen reads a little at a time, so a search never freezes the interface; it runs at the lowest
-- priority (nice 19), since the Kindle has a single core. The plugin carries Stockfish 11 built for the Kindle
-- (bin/stockfish-armhf); elsewhere, INK_KNIGHT_STOCKFISH can name a binary, as the checks on a Mac do. No KOReader
-- here.
local Stockfish = {}
Stockfish.__index = Stockfish

Stockfish.BINARY = "bin/stockfish-armhf"
-- The line the shell adds to the output once the engine ended, however it ended.
Stockfish.ENDED = "ink_knight: the engine ended"
-- Small, as the searches are short: 8 MB of hash, and Stockfish takes about 30 MB in all on the Kindle.
Stockfish.HASH_MB = 8

local function quote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function exists(path)
    local file = path and io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

-- The size of a file, or nil, so a binary replaced by an update is told from the one before.
function Stockfish.size(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local size = file:seek("end")
    file:close()
    return size
end

local found = {}

-- The binary to run, or nil when there is none for this device. Looked for once per folder, since the menus ask often.
function Stockfish.find(plugin_dir)
    if found[plugin_dir] == nil then
        local named = os.getenv("INK_KNIGHT_STOCKFISH")
        local path = plugin_dir .. "/" .. Stockfish.BINARY
        if named and named ~= "" then
            found[plugin_dir] = exists(named) and named or false
        elseif jit and jit.arch == "arm" and exists(path) then
            -- A copy over USB or from a zip may lose the execute bit.
            os.execute("chmod +x " .. quote(path) .. " 2>/dev/null")
            found[plugin_dir] = path
        else
            found[plugin_dir] = false
        end
    end
    return found[plugin_dir] or nil
end

-- Each process has files of its own, so two analyses at once never read each other's.
local started = 0

-- dir: a private folder for its output. Returns the process, or nil when it cannot start.
function Stockfish.start(binary, dir)
    os.execute("mkdir -p " .. quote(dir) .. " && chmod 700 " .. quote(dir))
    -- What a session that ended without stopping its engines left, and the single pair of names of earlier versions.
    if started == 0 then
        os.execute("rm -f " .. quote(dir) .. "/stockfish.out " .. quote(dir) .. "/stockfish.pid " .. quote(dir) .. "/stockfish-*.out " .. quote(dir) .. "/stockfish-*.pid")
    end
    started = started + 1
    local base = string.format("%s/stockfish-%d", dir, started)
    local self = setmetatable({ out_path = base .. ".out", pid_path = base .. ".pid", offset = 0, partial = "" }, Stockfish)
    os.remove(self.out_path)
    os.remove(self.pid_path)
    -- Stockfish runs beside the shell, which keeps reading the pipe after it ends: a write to an engine that died never meets a closed pipe, whose signal would close KOReader. The pid is Stockfish's own (nice runs it in place), and its file goes once the shell sees it end, so a number the system gives to another process is never killed. The shell then writes ENDED on a line of its own, even after a line the engine left unfinished when it was killed, which tells an engine that died at once from one still thinking. The pipe reaches it through descriptor 3: a POSIX shell such as busybox's on the Kindle, unlike bash, gives a job in the background /dev/null as its input before any redirection, so "<&0" would hand it /dev/null and it would quit at once. What else KOReader has open (pipes, sockets) is closed first where /proc lists it, so the engine holds none of it; numbers of two digits only where the shell can close them (busybox can, dash cannot, and would end at the attempt). Only the job's "Killed", after stop(), is kept out of KOReader's log.
    local script = string.format("exec 3<&0; big=; (eval 'exec 10<&-') 2>/dev/null && big=1; "
        .. "for fd in /proc/$$/fd/*; do n=${fd##*/}; [ \"$n\" -gt 3 ] 2>/dev/null || continue; "
        .. "[ ${#n} -gt 1 ] && [ -z \"$big\" ] && continue; eval \"exec $n<&-\"; done; "
        .. "nice -n 19 %s <&3 3<&- > %s 2>&1 & echo $! > %s; wait $! 2>/dev/null; rm -f %s; { echo; echo %s; } >> %s; cat > /dev/null",
        quote(binary), quote(self.out_path), quote(self.pid_path), quote(self.pid_path), quote(Stockfish.ENDED), quote(self.out_path))
    self.pipe = io.popen("sh -c " .. quote(script), "w")
    if not self.pipe then
        return nil
    end
    self:send("uci")
    self:send("setoption name Threads value 1")
    self:send("setoption name Hash value " .. Stockfish.HASH_MB)
    self:send("isready")
    return self
end

function Stockfish:send(line)
    if self.pipe then
        self.pipe:write(line, "\n")
        self.pipe:flush()
    end
end

-- The complete lines it wrote since the last call.
function Stockfish:read_lines()
    local file = io.open(self.out_path, "rb")
    if not file then
        return {}
    end
    file:seek("set", self.offset)
    local chunk = file:read("*a") or ""
    file:close()
    self.offset = self.offset + #chunk
    local text = self.partial .. chunk
    local lines = {}
    local last = 1
    for line, stop in text:gmatch("([^\n]*)\n()") do
        lines[#lines + 1] = line
        last = stop
    end
    self.partial = text:sub(last)
    return lines
end

-- Starts a search of the position after moves (UCI, separated by spaces) from fen, for so many milliseconds; with the
-- moves Stockfish sees the repetitions. poll() gives the result.
function Stockfish:search(fen, milliseconds, moves)
    self.result = { depth = 0 }
    self.searching = true
    self:send("position fen " .. fen .. (moves and moves ~= "" and (" moves " .. moves) or ""))
    self:send("go movetime " .. math.floor(milliseconds))
end

-- Whether the process still runs, asked of the system only when a search takes too long.
function Stockfish:alive()
    local file = io.open(self.pid_path, "rb")
    local pid = file and tonumber(file:read("*a"))
    if file then
        file:close()
    end
    if not pid then
        return false
    end
    local result = os.execute(string.format("kill -0 %d 2>/dev/null", pid))
    return result == 0 or result == true
end

-- Chess960, for a game that is one: castling then goes as the king taking its rook, as the plugin writes it.
function Stockfish:set_chess960(on)
    self:send("setoption name UCI_Chess960 value " .. (on and "true" or "false"))
end

-- What a line of "info" says about the best line: depth, score (centipawns or mate, for the side to move) and the
-- first moves.
function Stockfish.read_info(line, into)
    if not line:match("^info ") or line:find(" upperbound", 1, true) or line:find(" lowerbound", 1, true) then
        return false
    end
    local multipv = tonumber(line:match(" multipv (%d+)"))
    if multipv and multipv ~= 1 then
        return false
    end
    local depth = tonumber(line:match(" depth (%d+)"))
    local cp = tonumber(line:match(" score cp (%-?%d+)"))
    local mate = tonumber(line:match(" score mate (%-?%d+)"))
    local pv = line:match(" pv (.+)$")
    if not depth or not (cp or mate) or not pv then
        return false
    end
    into.depth, into.cp, into.mate, into.pv = depth, cp, mate, pv
    return true
end

-- nil while it thinks; then { best, cp or mate, depth, pv } for the side to move, best being nil when the position has
-- no move.
function Stockfish:poll()
    if not self.searching then
        return nil
    end
    -- Every line read is looked at, so the end of an engine that died right after answering is not lost with the rest of the batch.
    local answer
    for _, line in ipairs(self:read_lines()) do
        if line == Stockfish.ENDED then
            self.ended = true
        elseif not answer and not Stockfish.read_info(line, self.result) then
            local best = line:match("^bestmove (%S+)")
            if best then
                self.searching = false
                self.result.best = best ~= "(none)" and best or nil
                answer = self.result
            end
        end
    end
    return answer
end

-- Ends the process: asked to quit, then killed if it has not, so closing never waits on it.
function Stockfish:stop()
    if not self.pipe then
        return
    end
    self:send("quit")
    local file = io.open(self.pid_path, "rb")
    local pid = file and tonumber(file:read("*a"))
    if file then
        file:close()
    end
    if pid then
        os.execute(string.format("kill -9 %d 2>/dev/null", pid))
    end
    self.pipe:close()
    self.pipe = nil
    os.remove(self.out_path)
    os.remove(self.pid_path)
end

return Stockfish
