-- The plugin's Stockfish for one screen that asks it for moves, as the opponent or for a hint: started on the first one, kept while the screen is open (starting it again would cost half a second on the Kindle each time), and read a little at a time between the frames, so the screen never freezes. Where Stockfish does not run, or once it stops answering, it says so and the screen goes on with the small engine.
local Chess = require("ink_knight/chess")
local EngineAnalysis = require("ink_knight/ui/engine_analysis")
local Sleep = require("ink_knight/sleep")
local Stockfish = require("ink_knight/stockfish")

local EnginePlayer = {}
EnginePlayer.__index = EnginePlayer

-- The levels of the opponent, from a beginner to the full engine: Stockfish's own weakening (Skill Level, which picks worse moves the lower it is), with less depth and time for the lower ones. Like the 8 of the computer of Lichess, which a reader who plays there already knows.
EnginePlayer.LEVELS = {
    { skill = 0, depth = 1, milliseconds = 100 },
    { skill = 3, depth = 2, milliseconds = 150 },
    { skill = 6, depth = 3, milliseconds = 200 },
    { skill = 9, depth = 5, milliseconds = 300 },
    { skill = 11, depth = 7, milliseconds = 400 },
    { skill = 14, depth = 9, milliseconds = 600 },
    { skill = 17, depth = 12, milliseconds = 900 },
    { skill = 20, milliseconds = 1500 },
}

local POLL_SECONDS = 0.1
-- Past the time asked for, this long without an answer means the engine is gone.
local GIVE_UP_SECONDS = 10

-- nil where the plugin's Stockfish cannot be used. window: the screen whose timers it uses.
function EnginePlayer.new(app, window)
    if not EngineAnalysis.available(app) then
        return nil
    end
    return setmetatable({ app = app, window = window }, EnginePlayer)
end

-- The one of a screen (owner.engine_player, created on the first call), or nil where Stockfish does not run or once it stopped answering: then the screen goes on with the small engine.
function EnginePlayer.of(owner, app, window)
    if owner.engine_player == nil then
        owner.engine_player = EnginePlayer.new(app, window) or false
    end
    local player = owner.engine_player
    return player and player:usable() and player or nil
end

-- Whether it can still be asked: false once the engine could not start or stopped answering.
function EnginePlayer:usable()
    return not self.failed and not self.closed
end

-- Asks for the best move of a position: initial_fen (nil for the usual start) and moves (UCI, separated by spaces) after it, so the engine sees the repetitions; or only fen. opts: milliseconds, skill (0 to 20, 20 by default), depth (no limit by default). on_done(move, result) gets the move of the position and what the engine said ({ cp or mate for the side to move, depth }), or nothing when the engine failed; a search asked again or cancelled never calls it.
function EnginePlayer:best_move(opts, on_done)
    self:cancel()
    if not self:usable() then
        on_done(nil)
        return
    end
    if not self.engine then
        local binary = Stockfish.find(self.app.plugin_dir)
        self.engine = binary and Stockfish.start(binary, self.app:engine_dir())
        if not self.engine then
            self.failed = true
            on_done(nil)
            return
        end
    end
    local fen = opts.fen or Chess.to_fen(Chess.start_position(opts.initial_fen))
    local position = Chess.from_moves(opts.fen or opts.initial_fen, opts.moves or "")
    self.engine:set_chess960(position.chess960 == true)
    self.engine:set_option("Skill Level", opts.skill or 20)
    self.engine:search(fen, opts.milliseconds, opts.moves, opts.depth)
    local asked = {}
    self.asked = asked
    local deadline = os.time() + math.ceil(opts.milliseconds / 1000) + GIVE_UP_SECONDS
    local function step()
        if self.asked ~= asked or self.closed then
            return
        end
        local result = self.engine:poll()
        if result then
            self.asked = nil
            on_done(result.best and Chess.parse_uci(position, result.best) or nil, result)
            return
        end
        if self.engine.ended or os.time() > deadline then
            self.asked = nil
            self:fail()
            on_done(nil)
            return
        end
        Sleep.schedule(self.window, POLL_SECONDS, step)
    end
    self.tick = step
    Sleep.schedule(self.window, POLL_SECONDS, step)
end

-- Drops the search under way, for a position that is gone (a move taken back, the game left).
function EnginePlayer:cancel()
    if self.asked then
        self.asked = nil
        if self.tick then
            Sleep.unschedule(self.window, self.tick)
        end
        if self.engine then
            self.engine:cancel()
        end
    end
end

function EnginePlayer:fail()
    self.failed = true
    if self.engine then
        self.engine:stop()
        self.engine = nil
    end
end

function EnginePlayer:close()
    self:cancel()
    self.closed = true
    if self.engine then
        self.engine:stop()
        self.engine = nil
    end
end

return EnginePlayer
