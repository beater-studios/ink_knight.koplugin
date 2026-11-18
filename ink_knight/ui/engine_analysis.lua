-- A game analyzed by Stockfish on the device: each position searched in turn, and the move played from it searched alone when it is not the best one, a little at a time between the frames of the screen, then each move judged as Lichess judges it (engine_review.lua). Only where the plugin has a Stockfish for the device (stockfish.lua) and it runs there; elsewhere the offline games keep the small engine.
local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("ffi/util")

local Chess = require("ink_knight/chess")
local EngineReview = require("ink_knight/engine_review")
local Sleep = require("ink_knight/sleep")
local Stockfish = require("ink_knight/stockfish")

local EngineAnalysis = {}
EngineAnalysis.__index = EngineAnalysis

-- How deep each position is searched, by the level the reader chose (the option analysis_level, whose values are the keys here); how long a move takes at each on the Kindle, its two searches counted (measured on 2026-11-18: 32, 67 and 109 s for a game of 53 moves, both sides counted, and 1.27 s a move at normal over 6 games); and the longest a search may take, a few times what the Kindle needs, so a slower device is held to a few seconds for each move instead of to a depth it cannot reach in time. A depth and not a time, so every position is searched alike and the same game gets the same marks; with 0.7 s for each, as before, two analyses of a game differed.
EngineAnalysis.LEVELS = {
    quick = { depth = 10, seconds = 0.6, milliseconds = 2500 },
    normal = { depth = 12, seconds = 1.25, milliseconds = 5000 },
    deep = { depth = 14, seconds = 2, milliseconds = 8000 },
}

function EngineAnalysis.level(app)
    return EngineAnalysis.LEVELS[app:option("analysis_level")]
end

-- A length of time in words: "about 35 seconds", "about 2 minutes".
function EngineAnalysis.time_text(s, seconds)
    if seconds < 55 then
        return string.format(s.about_seconds, math.max(5, math.floor(seconds / 5 + 0.5) * 5))
    end
    local minutes = math.floor(seconds / 60 + 0.5)
    return minutes <= 1 and s.about_minute or string.format(s.about_minutes, minutes)
end

-- About how long the analysis of a game of so many moves (of both sides) takes, in seconds, at a level (the reader's by default).
function EngineAnalysis.seconds_for(app, moves, level)
    return (moves + 1) * (level and EngineAnalysis.LEVELS[level] or EngineAnalysis.level(app)).seconds
end
local POLL_SECONDS = 0.1
-- A search with no answer after this long is looked into: an engine that stopped (killed for memory, or never started)
-- ends the analysis, checked every few seconds; past the last limit it ends anyway, so it never waits forever.
local CHECK_AFTER_SECONDS, CHECK_EVERY_SECONDS, GIVE_UP_SECONDS = 15, 2, 60

-- How long a first start may take to answer, and the pause between looks at what it said. On the Kindle it answers in 0.6 s.
EngineAnalysis.CHECK_SECONDS = 3
local CHECK_POLL_MICROSECONDS = 20000

local function now()
    local seconds, microseconds = util.gettime()
    return seconds + microseconds / 1000000
end

-- Whether the engine runs here: started once, it must answer readyok. The package goes to every device that runs KOReader, and on some the binary cannot run (another processor, a folder where nothing may be executed), so there the small engine stays. One that ended before answering is given up on at once.
function EngineAnalysis.check(binary, dir)
    local engine = Stockfish.start(binary, dir)
    if not engine then
        return false
    end
    local deadline = now() + EngineAnalysis.CHECK_SECONDS
    local ready, ended = false, false
    while not ready and not ended and now() < deadline do
        for _, line in ipairs(engine:read_lines()) do
            ready = ready or line == "readyok"
            ended = ended or line == Stockfish.ENDED
        end
        if not ready and not ended then
            util.usleep(CHECK_POLL_MICROSECONDS)
        end
    end
    engine:stop()
    return ready
end

-- The answer of check for each binary in this session, and the checks under way in the background.
local checked = {}
local probes = {}

local function key_of(binary)
    return { binary = binary, size = Stockfish.size(binary), modified = lfs.attributes(binary, "modification") }
end

local function saved_yes(app, key)
    local saved = app.settings:readSetting("engine_check")
    return type(saved) == "table" and saved.binary == key.binary and saved.size == key.size and saved.modified == key.modified
end

local function keep(app, binary, key, ready)
    checked[binary] = ready
    if ready then
        app:save_setting("engine_check", key)
    else
        logger.warn("Ink Knight: Stockfish did not answer on this device, the small engine stays for this session")
    end
end

-- What a check under way has heard: true once the engine answered, false if it ended or is late, nil while waiting.
local function heard(probe)
    for _, line in ipairs(probe.engine:read_lines()) do
        probe.ready = probe.ready or line == "readyok"
        probe.ended = probe.ended or line == Stockfish.ENDED
    end
    if probe.ready then
        return true
    elseif probe.ended or now() >= probe.deadline then
        return false
    end
    return nil
end

local function finish(app, binary, probe, ready)
    probes[binary] = nil
    probe.engine:stop()
    keep(app, binary, probe.key, ready)
end

-- Starts the check of available without waiting for it, so the first page that needs Stockfish (the levels of the offline menu) opens at once: called when the plugin opens. The engine is looked at between the frames of the screen, and a page that asks before it answered waits only for the rest.
function EngineAnalysis.prepare(app)
    local binary = app.plugin_dir and Stockfish.find(app.plugin_dir)
    if not binary or checked[binary] ~= nil or probes[binary] then
        return
    end
    local key = key_of(binary)
    if saved_yes(app, key) then
        checked[binary] = true
        return
    end
    local engine = Stockfish.start(binary, app:engine_dir())
    if not engine then
        keep(app, binary, key, false)
        return
    end
    local probe = { engine = engine, key = key, deadline = now() + EngineAnalysis.CHECK_SECONDS }
    probes[binary] = probe
    -- Not the timers of a window: the check ends even if the plugin closes first, so the engine never stays running.
    local function look()
        if probes[binary] ~= probe then
            return
        end
        local ready = heard(probe)
        if ready == nil then
            UIManager:scheduleIn(0.1, look)
        else
            finish(app, binary, probe, ready)
        end
    end
    UIManager:scheduleIn(0.1, look)
end

-- Whether the plugin's Stockfish can be used here, asked by everything that would use it. The first time on a device the engine is started to see (0.6 s on the Kindle, at most CHECK_SECONDS where it hangs), usually already done in the background by prepare. Only a yes is kept in the settings, with the binary's path, size and date, so it is not asked again until an update brings another binary; a no lasts this session only, since it may come from a busy moment, and the next session asks again.
function EngineAnalysis.available(app)
    local binary = app.plugin_dir and Stockfish.find(app.plugin_dir)
    if not binary then
        return false
    end
    local probe = probes[binary]
    if probe then
        local ready = heard(probe)
        while ready == nil do
            util.usleep(CHECK_POLL_MICROSECONDS)
            ready = heard(probe)
        end
        finish(app, binary, probe, ready)
    elseif checked[binary] == nil then
        local key = key_of(binary)
        if saved_yes(app, key) then
            checked[binary] = true
        else
            keep(app, binary, key, EngineAnalysis.check(binary, app:engine_dir()))
        end
    end
    return checked[binary]
end

-- opts: app, window (the screen whose timers it uses), initial_fen, moves (UCI, as a list), on_progress(position, total),
-- counted from 1, on_done(result): result is { moves = { { judgment, eval_text, best, best_uci, white_cp, white_score,
-- white_mate } }, summary = { white, black } },
-- or nil when the engine stopped answering.
function EngineAnalysis.start(opts)
    local binary = EngineAnalysis.available(opts.app) and Stockfish.find(opts.app.plugin_dir)
    local engine = binary and Stockfish.start(binary, opts.app:engine_dir())
    if not engine then
        return nil
    end
    local self = setmetatable({ opts = opts, engine = engine, positions = {}, movers = {}, scores = {}, played = {}, best = {}, index = 0, level = EngineAnalysis.level(opts.app) }, EngineAnalysis)
    local position = Chess.start_position(opts.initial_fen)
    self.positions[0] = position
    self.start_fen = Chess.to_fen(position)
    if position.chess960 then
        engine:set_chess960(true)
    end
    for i, uci in ipairs(opts.moves) do
        local after = Chess.apply_uci(position, uci)
        if not after then
            break
        end
        self.movers[i] = position.turn
        self.positions[i] = after
        position = after
    end
    self.total = #self.movers + 1
    self.tick = function() self:step() end
    self:next_position()
    return self
end

function EngineAnalysis:next_position()
    local position = self.positions[self.index]
    if not position then
        self:finish()
        return
    end
    self.opts.on_progress(self.index + 1, self.total)
    local ending = Chess.ending(position)
    if ending == "mate" or ending == "stalemate" then
        self.scores[self.index] = EngineReview.final_score(ending)
        self.index = self.index + 1
        Sleep.schedule(self.opts.window, 0, self.tick)
        return
    end
    self:search(nil, self.level.depth)
end

-- Searches the position of now: all its moves, or only one, the move played from it, to the depth the search of all reached, so the two scores compare even when the time cut that one short. From the start with the moves played, so the engine sees the repetitions.
function EngineAnalysis:search(only, depth)
    self.only = only
    self.engine:search(self.start_fen, self.level.milliseconds, table.concat(self.opts.moves, " ", 1, self.index), depth, only)
    self.searched_at = os.time()
    Sleep.schedule(self.opts.window, POLL_SECONDS, self.tick)
end

function EngineAnalysis:step()
    if self.cancelled then
        return
    end
    if self.engine.searching then
        local result = self.engine:poll()
        if not result then
            local now = os.time()
            local waited = now - self.searched_at
            -- An engine that ended is known at once from its output; one that hangs, by asking the system.
            local dead = self.engine.ended == true
            if not dead and waited > CHECK_AFTER_SECONDS and now - (self.checked_at or 0) >= CHECK_EVERY_SECONDS then
                self.checked_at = now
                dead = not self.engine:alive()
            end
            if dead or waited > GIVE_UP_SECONDS then
                self:cancel()
                self.opts.on_done(nil)
                return
            end
            Sleep.schedule(self.opts.window, POLL_SECONDS, self.tick)
            return
        end
        local score = { cp = result.cp, mate = result.mate }
        local move = self.movers[self.index + 1] and self.opts.moves[self.index + 1]
        if self.only then
            -- The move played, searched alone: its score from the same position and depth as the best one.
            self.played[self.index + 1] = score
        else
            self.scores[self.index] = score
            self.best[self.index + 1] = result.best
            if move and result.best == move then
                self.played[self.index + 1] = score
            elseif move then
                self:search(move, math.max(1, math.min(self.level.depth, tonumber(result.depth) or self.level.depth)))
                return
            end
        end
        self.index = self.index + 1
    end
    self:next_position()
end

function EngineAnalysis:finish()
    self.engine:stop()
    local judged, summary = EngineReview.judge(self.scores, self.movers, self.played)
    local moves = {}
    for i = 1, #self.movers do
        local entry = judged[i] or {}
        local best = self.best[i]
        if entry.judgment and best and best ~= self.opts.moves[i] then
            local move = Chess.parse_uci(self.positions[i - 1], best)
            entry.best = move and Chess.to_san(self.positions[i - 1], move) or nil
            entry.best_uci = move and best or nil
        end
        moves[i] = entry
    end
    self.opts.on_done({ moves = moves, summary = { white = summary.w, black = summary.b, source = "plugin" } })
end

function EngineAnalysis:cancel()
    if not self.cancelled then
        self.cancelled = true
        Sleep.unschedule(self.opts.window, self.tick)
        self.engine:stop()
    end
end

return EngineAnalysis
