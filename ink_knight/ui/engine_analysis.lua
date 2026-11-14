-- A game analyzed by Stockfish on the device: each position searched in turn, a little at a time between the frames
-- of the screen, then each move judged as Lichess judges it (engine_review.lua). Only where the plugin has a Stockfish
-- for the device (stockfish.lua); elsewhere the offline games keep the small engine.
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

function EngineAnalysis.available(app)
    return app.plugin_dir ~= nil and Stockfish.find(app.plugin_dir) ~= nil
end

-- opts: app, window (the screen whose timers it uses), initial_fen, moves (UCI, as a list), on_progress(position, total),
-- counted from 1, on_done(result): result is { moves = { { judgment, eval_text, best, white_cp } }, summary = { white, black } },
-- or nil when the engine stopped answering.
function EngineAnalysis.start(opts)
    local binary = Stockfish.find(opts.app.plugin_dir)
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
            local dead = false
            if waited > CHECK_AFTER_SECONDS and now - (self.checked_at or 0) >= CHECK_EVERY_SECONDS then
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
