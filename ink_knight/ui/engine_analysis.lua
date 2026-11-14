-- A game analyzed by Stockfish on the device: each position searched in turn, a little at a time between the frames
-- of the screen, then each move judged as Lichess judges it (engine_review.lua). Only where the plugin has a Stockfish
-- for the device (stockfish.lua) and it runs there; elsewhere the offline games keep the small engine.
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("ffi/util")

local Chess = require("ink_knight/chess")
local EngineReview = require("ink_knight/engine_review")
local Sleep = require("ink_knight/sleep")
local Stockfish = require("ink_knight/stockfish")

local EngineAnalysis = {}
EngineAnalysis.__index = EngineAnalysis

-- Each position gets this long: depth 11 to 13 on the Kindle, a game of 40 moves in about a minute.
EngineAnalysis.MILLISECONDS = 700
local POLL_SECONDS = 0.15
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

-- The answer of check for each binary in this session.
local checked = {}

-- Whether the plugin's Stockfish can be used here, asked by everything that would use it. The first time on a device the engine is started to see (0.6 s on the Kindle, at most CHECK_SECONDS where it hangs). Only a yes is kept in the settings, with the binary's path, size and date, so it is not asked again until an update brings another binary; a no lasts this session only, since it may come from a busy moment, and the next session asks again.
function EngineAnalysis.available(app)
    local binary = app.plugin_dir and Stockfish.find(app.plugin_dir)
    if not binary then
        return false
    end
    if checked[binary] == nil then
        local key = { binary = binary, size = Stockfish.size(binary), modified = lfs.attributes(binary, "modification") }
        local saved = app.settings:readSetting("engine_check")
        if type(saved) == "table" and saved.binary == key.binary and saved.size == key.size and saved.modified == key.modified then
            checked[binary] = true
        else
            checked[binary] = EngineAnalysis.check(binary, app:engine_dir())
            if checked[binary] then
                app:save_setting("engine_check", key)
            else
                logger.warn("Ink Knight: Stockfish did not answer on this device, the small engine stays for this session")
            end
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
    local self = setmetatable({ opts = opts, engine = engine, positions = {}, movers = {}, scores = {}, best = {}, index = 0 }, EngineAnalysis)
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
    -- From the start with the moves played, so the engine sees the repetitions.
    self.engine:search(self.start_fen, EngineAnalysis.MILLISECONDS, table.concat(self.opts.moves, " ", 1, self.index))
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
        self.scores[self.index] = { cp = result.cp, mate = result.mate }
        self.best[self.index + 1] = result.best
        self.index = self.index + 1
    end
    self:next_position()
end

function EngineAnalysis:finish()
    self.engine:stop()
    local judged, summary = EngineReview.judge(self.scores, self.movers)
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
