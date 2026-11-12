-- The windows of Ink Knight for tools/koreader/check_sleep.lua, each in a state that has timers: the clock of a
-- live game, the engine thinking, the reply of a puzzle, the clock of the coordinate training, the network of the
-- online part, a notice that leaves by itself and the page that receives the token. The network is invented: nothing leaves this computer, apart from
-- the token page, which listens on its private address when it has one.
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local rapidjson = require("rapidjson")

local I18n = require("ink_knight/i18n")

-- Each case starts from an empty screen, so what an earlier one left open does not get the events too.
local function close_all()
    local stack = UIManager._window_stack
    while #stack > 0 do
        UIManager:close(stack[#stack].widget)
    end
end

local function settings()
    local path = DataStorage:getSettingsDir() .. "/ink_knight_sleep_case.lua"
    os.remove(path)
    return LuaSettings:open(path)
end

-- What the game screens ask of the first page, without it.
local function fake_app(net)
    local app = { strings = I18n.en, my_id = "me", net = net, settings = settings() }
    app.decode = function(text) return rapidjson.decode(text) end
    function app:info() end
    function app:error_text() return "" end
    function app:option(key) return require("ink_knight/state").option(key, nil) end
    function app:saved_game() return nil end
    function app:game_closed() end
    function app:refresh_list() end
    function app:add_puzzle_result() end
    function app:return_puzzle() end
    function app:flush_puzzles() end
    return app
end

-- A stream that answers at once with a game under way, white to move after 1.e4 e5, with a clock.
local GAME_FULL = rapidjson.encode({
    type = "gameFull", id = "abcdefgh", speed = "rapid", rated = false,
    clock = { initial = 600000, increment = 0 },
    white = { id = "me", name = "Me", rating = 1500 }, black = { id = "other", name = "Other", rating = 1520 },
    state = { moves = "e2e4 e7e5", wtime = 590000, btime = 595000, status = "started" },
})

local function fake_net()
    local net = {}
    function net:stream(_, on_line)
        on_line(GAME_FULL)
        return {}
    end
    function net:close_stream() end
    function net:request() end
    return net
end

return {
    ["ink_knight/ui/page"] = function(plugin_dir)
        close_all()
        local Page = require("ink_knight/ui/page")
        return Page:new{ plugin_dir = plugin_dir, title = "Page", rows = { { text = "row" } } }
    end,
    ["ink_knight/ui/chart_screen"] = function()
        close_all()
        local ChartScreen = require("ink_knight/ui/chart_screen")
        return ChartScreen:new{ title = "Rapid", points = {}, stats = {}, strings = I18n.en }
    end,
    ["ink_knight/ui/create_token_screen"] = function()
        close_all()
        local CreateTokenScreen = require("ink_knight/ui/create_token_screen")
        return CreateTokenScreen:new{ strings = I18n.en, on_ready = function() end }
    end,
    ["ink_knight/ui/token_screen"] = function()
        close_all()
        require("ink_knight/lan").install("ink_knight")
        local TokenScreen = require("ink_knight/ui/token_screen")
        return TokenScreen:new{ strings = I18n.en, on_token = function() end }
    end,
    ["first page with a notice"] = function(plugin_dir)
        close_all()
        local Home = require("ink_knight/ui/home")
        local home = Home:new{ plugin_dir = plugin_dir, version = "0" }
        UIManager:show(home)
        home:info("A notice that leaves by itself.", 3)
        return home
    end,
    ["online part with the network ticking"] = function(plugin_dir)
        close_all()
        local Net = require("ink_knight/net")
        local real_new = Net.new
        Net.new = function(opts)
            opts.ca_file = plugin_dir .. "/LICENSE"
            opts.spawn = function(spec)
                local file = io.open(spec.code_path, "wb")
                file:write("200")
                file:close()
                file = io.open(spec.out_path, "wb")
                file:write(spec.url:find("/api/account$") and '{"id":"me","username":"Me"}' or "{}")
                file:close()
                return 1
            end
            opts.done = function() return true end
            opts.kill = function() end
            return real_new(opts)
        end
        local Home = require("ink_knight/ui/home")
        local home = Home:new{ plugin_dir = plugin_dir, version = "0" }
        UIManager:show(home)
        home.token_store = { load = function() return "lip_" .. string.rep("0", 20), true end }
        home:open_hub()
        Net.new = real_new
        return home
    end,
    ["live game with a clock"] = function()
        close_all()
        require("ink_knight/awake").install("ink_knight")
        local LiveGame = require("ink_knight/ui/live_game")
        return LiveGame.open(fake_app(fake_net()), "abcdefgh").screen
    end,
    ["offline game with the engine thinking"] = function()
        close_all()
        local OfflineGame = require("ink_knight/ui/offline_game")
        return OfflineGame.open(fake_app(), { level = 2, color_choice = "black" }).screen
    end,
    ["coordinate training with its clock"] = function()
        close_all()
        local CoordinatesScreen = require("ink_knight/ui/coordinates_screen")
        local app = fake_app()
        function app:keep_coordinate_score() return false end
        local screen = CoordinatesScreen.open(app)
        screen:start()
        return screen.screen
    end,
    ["puzzle waiting for the reply"] = function()
        close_all()
        local PuzzleScreen = require("ink_knight/ui/puzzle_screen")
        local puzzle = { id = "case1", played = "e2e4 e7e5", solution = { "g1f3", "b8c6", "f1c4" }, rating = 1400 }
        local screen = PuzzleScreen.open(fake_app(), { puzzle = puzzle })
        screen:play("g1f3")
        return screen.screen
    end,
}
