-- Random touches through the real screens of Ink Knight: the first page, a game against the engine, a game between
-- two people and the online part with an invented Lichess, in the three languages. Nothing reaches the network:
-- the requests get invented answers, and the token page is given a public address, so it never listens.
-- Usage: KOREADER_DIR=<desktop KOReader> tools/koreader/run_headless.sh tools/koreader/fuzz_ui.lua
-- (ACTIONS, SEED, ONLY and MAX_ERRORS as in tools/koreader/fuzz.lua)
local Fuzz = dofile(os.getenv("PLUGIN_DIR") .. "/tools/koreader/fuzz.lua")

local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")

local Chess = require("ink_knight/chess")
local Net = require("ink_knight/net")
local SavedState = require("ink_knight/saved_state")

require("ink_knight/awake").install("ink_knight")
require("ink_knight/lan").install("ink_knight")
require("ink_knight/ui/token_screen").local_ip = "203.0.113.7"

-- The invented Lichess: the account, a game waiting for the reader, a puzzle batch and an empty answer for the rest.
-- Streams end at once, so they come back by themselves, as after a dropped connection.
local GAME = '{"gameId":"fuzzgame","fullId":"fuzzgamexxxx","color":"white","isMyTurn":true,"secondsLeft":259200,'
    .. '"fen":"' .. Chess.START_FEN .. '",'
    .. '"opponent":{"id":"helena","username":"Helena","rating":1612},"speed":"correspondence"}'
local ANSWERS = {
    ["/api/account"] = '{"id":"reader","username":"Reader","perfs":{"rapid":{"rating":1500}}}',
    ["/api/account/playing"] = '{"nowPlaying":[' .. GAME .. ']}',
    ["/api/puzzle/batch/mix"] = '{"puzzles":[{"game":{"id":"g1","pgn":"e4 e5 Bc4 Nc6 Qh5 Nf6"},'
        .. '"puzzle":{"id":"fuzz1","rating":1400,"solution":["h5f7"],"themes":["mateIn1"]}}]}',
}
local real_new = Net.new
Net.new = function(opts)
    opts.ca_file = Fuzz.plugin_dir .. "/LICENSE"
    opts.spawn = function(spec)
        local path = spec.url:gsub("^https://[^/]+", ""):gsub("%?.*$", "")
        local out = io.open(spec.out_path, "wb")
        out:write(ANSWERS[path] or "{}")
        out:close()
        local code = io.open(spec.code_path, "wb")
        code:write("200")
        code:close()
        return 1
    end
    opts.done = function() return true end
    opts.kill = function() end
    return real_new(opts)
end

-- How many touches reached each kind of screen, to see that the runs go somewhere.
local reached = {}
local function count_taps(module, name)
    local class = require(module)
    local on_tap = class.onTap
    class.onTap = function(...)
        reached[name] = (reached[name] or 0) + 1
        return on_tap(...)
    end
end
count_taps("ink_knight/ui/page", "pages")
count_taps("ink_knight/ui/board_screen", "board")

local settings_path = DataStorage:getSettingsDir() .. "/ink_knight.lua"

-- A clean start for each run: no saved games, options or puzzles, everything on screen closed, the language set
-- and the plugin's own random draws tied to the seed.
local function fresh_home(fuzz, language)
    fuzz:close_above()
    local stack = UIManager._window_stack
    while #stack > 0 do
        UIManager:close(stack[#stack].widget)
    end
    SavedState.remove_file(settings_path)
    G_reader_settings:saveSetting("language", language)
    math.randomseed(fuzz.seed)
    local Home = require("ink_knight/ui/home")
    local home = Home:new{ plugin_dir = Fuzz.plugin_dir, version = "0" }
    UIManager:show(home)
    return home
end

local Home = require("ink_knight/ui/home")
local OfflineGame = require("ink_knight/ui/offline_game")
local first = Home:new{ plugin_dir = Fuzz.plugin_dir, version = "0" }
local fuzz = Fuzz.new{ screen = first }

local function tap_square(f, screen, name)
    local x, y = screen:square_position(Chess.square_from_name(name))
    f:tap(x + math.floor(screen.square / 2), y + math.floor(screen.square / 2))
end

-- One time in three, a legal move played through the board, so games go far; otherwise a random touch.
local function game_step(f, game)
    if game.current and not game.current.is_closed and f.random(1, 3) == 1 then
        local moves = Chess.legal_moves(game.current.position)
        if #moves > 0 then
            local move = moves[f.random(1, #moves)]
            tap_square(f, game.current.screen, Chess.square_name(move.from))
            tap_square(f, game.current.screen, Chess.square_name(move.to))
            return
        end
    end
    f:touch()
end

for _, language in ipairs({ "en", "pt", "es" }) do
    fuzz:run{
        label = "first page " .. language,
        setup = function(f) return fresh_home(f, language) end,
    }

    local engine = {}
    fuzz:run{
        label = "game against the engine " .. language,
        setup = function(f)
            local home = fresh_home(f, language)
            engine.current = OfflineGame.open(home, { level = 1, color_choice = "white" })
            return engine.current.screen
        end,
        step = function(f) game_step(f, engine) end,
    }

    fuzz:run{
        label = "online " .. language,
        setup = function(f)
            local home = fresh_home(f, language)
            -- A token kept in memory only, which disconnecting forgets as the real store would.
            local token = "lip_" .. string.rep("0", 20)
            home.token_store = {
                load = function() return token, token and true end,
                save = function(_, new_token) token = new_token; return true, true end,
                clear = function() token = nil end,
            }
            home.token = token
            home:open_hub()
            for _ = 1, 10 do
                if home.net then
                    home.net:tick()
                end
            end
            return home
        end,
    }
end

local two = {}
fuzz:run{
    label = "two players",
    setup = function(f)
        local home = fresh_home(f, "en")
        two.current = OfflineGame.open(home, { two_players = true })
        return two.current.screen
    end,
    step = function(f) game_step(f, two) end,
}

-- A game between two people with a clock, moving through the board.
local timed = {}
fuzz:run{
    label = "two players with a clock",
    setup = function(f)
        local home = fresh_home(f, "en")
        timed.current = OfflineGame.open(home, { two_players = true, clock = "3+2" })
        return timed.current.screen
    end,
    step = function(f) game_step(f, timed) end,
}

-- The chess clock for a physical board.
fuzz:run{
    label = "chess clock",
    setup = function(f)
        local home = fresh_home(f, "en")
        return require("ink_knight/ui/clock_screen").open(home, "3+2")
    end,
}

-- Learn chess: a level with the opponent's moves and captures that fail it, and one with stars.
fuzz:run{
    label = "learn chess",
    setup = function(f)
        local home = fresh_home(f, "en")
        local categories = require("ink_knight/data/learn_stages")
        local stage = f.random(1, 2) == 1 and categories[2].stages[3] or categories[1].stages[f.random(1, 6)]
        return require("ink_knight/ui/learn_screen").open(home, stage, f.random(1, #stage.levels)).screen
    end,
}

-- A game between two people that just ended in mate, so the analysis and its review get touched.
fuzz:run{
    label = "analysis after a game",
    setup = function(f)
        local home = fresh_home(f, "en")
        local game = OfflineGame.open(home, { two_players = true })
        for _, uci in ipairs({ "e2e4", "e7e5", "d1h5", "b8c6", "f1c4", "g8f6", "h5f7" }) do
            game:on_square(Chess.square_from_name(uci:sub(1, 2)))
            game:on_square(Chess.square_from_name(uci:sub(3, 4)))
        end
        return game.screen
    end,
}

-- The position editor, from the starting position.
fuzz:run{
    label = "position editor",
    setup = function(f)
        local home = fresh_home(f, "en")
        return require("ink_knight/ui/editor_screen").open(home).screen
    end,
}

-- The coordinate training, naming squares against the clock.
fuzz:run{
    label = "coordinates",
    setup = function(f)
        local home = fresh_home(f, "en")
        home:save_setting("coordinates_mode", f.random(1, 2) == 1 and "find" or "name")
        local training = require("ink_knight/ui/coordinates_screen").open(home)
        training:start()
        return training.screen
    end,
}

-- A correspondence game kept offline, on the reader's turn, from its board.
fuzz:run{
    label = "correspondence offline",
    setup = function(f)
        local home = fresh_home(f, "en")
        local Correspondence = require("ink_knight/correspondence")
        local game = Correspondence.from_playing({ gameId = "fuzzcorr", color = "white", fen = Chess.START_FEN,
            speed = "correspondence", secondsLeft = 259200, opponent = { username = "Helena" } }, os.time())
        home:save_correspondence({ account = "reader", name = "Reader", games = { game } })
        return require("ink_knight/ui/correspondence_screen").open(home, "fuzzcorr").screen
    end,
}

local parts = {}
for name, count in pairs(reached) do
    parts[#parts + 1] = name .. " " .. count
end
table.sort(parts)
print("touches that reached: " .. table.concat(parts, ", "))
fuzz:finish()
