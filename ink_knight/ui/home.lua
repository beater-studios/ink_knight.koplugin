-- The first page, and what ties everything together: the account, the network, the games and the menus.
-- Lichess is only contacted after the reader chooses to play online, and no longer after leaving that part.
local DataStorage = require("datastorage")
local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local rapidjson = require("rapidjson")

local Api = require("ink_knight/api")
local BoardScreen = require("ink_knight/ui/board_screen")
local CreateTokenScreen = require("ink_knight/ui/create_token_screen")
local Game = require("ink_knight/game")
local I18n = require("ink_knight/i18n")
local LiveGame = require("ink_knight/ui/live_game")
local Net = require("ink_knight/net")
local OfflineGame = require("ink_knight/ui/offline_game")
local Page = require("ink_knight/ui/page")
local Pgn = require("ink_knight/pgn")
local Players = require("ink_knight/ui/players")
local PuzzleScreen = require("ink_knight/ui/puzzle_screen")
local Puzzles = require("ink_knight/puzzles")
local ReviewScreen = require("ink_knight/ui/review_screen")
local TokenAccess = require("ink_knight/token_access")
local TokenScreen = require("ink_knight/ui/token_screen")
local TokenScopes = require("ink_knight/token_scopes")
local TokenStore = require("ink_knight/token_store")
local Toast = require("ink_knight/ui/toast")

local TICK_BUSY, TICK_IDLE = 0.3, 1
-- A new request does not wait for the next check, and the screen still paints the tap before the child starts.
local TICK_SOON = 0.05
local REFRESH_CHOICES = { 1, 5, 15, 0 }
local EVENT_RECONNECT = 10
-- Lichess also closes a seek when it finds an opponent, and the start of the game comes on the other stream,
-- so an ended seek only counts as refused if no game started in this time.
local SEEK_GRACE = 6
-- With no connection yet, how often the online part tries again by itself.
local ACCOUNT_RETRY = 30

-- The chess symbols of FreeSerif, which comes with KOReader, stand in for icons.
local ICON_KING, ICON_QUEEN, ICON_ROOK, ICON_BISHOP, ICON_KNIGHT, ICON_PAWN =
    "\226\153\154", "\226\153\155", "\226\153\156", "\226\153\157", "\226\153\158", "\226\153\159"
local MAX_GAMES_ON_HOME = 4

local Home = Page:extend{
    name = "ink_knight_home",
    header = false,
    version = "0",
    plugin_dir = nil,
}

local function decode(text)
    local ok, value = pcall(rapidjson.decode, text)
    if ok and type(value) == "table" then
        return Api.without_nulls(value, rapidjson.null)
    end
    return nil
end

local function new_token_store()
    return TokenStore.new{
        settings_dir = DataStorage:getSettingsDir(),
        private_dir = TokenStore.private_dir_for(Device:isKindle()),
        permissions_of = function(path) return lfs.attributes(path, "permissions") end,
    }
end

-- A private folder outside the shared storage of the device, when there is one.
local function net_dir()
    local probe = io.open("/tmp/.ink_knight_probe", "wb")
    if probe then
        probe:close()
        os.remove("/tmp/.ink_knight_probe")
        return "/tmp/ink_knight"
    end
    return DataStorage:getDataDir() .. "/cache/ink_knight"
end

function Home:init()
    self.strings = I18n[I18n.language_from(G_reader_settings:readSetting("language"))]
    self.title = self.strings.games_title
    self.decode = decode
    self.token_store = new_token_store()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/ink_knight.lua")
    self:apply_board_look()
    self.games, self.challenges, self.sent = {}, {}, {}
    self.open_games = {}
    self.fetching_puzzles = {}
    self.pages = {}
    self.tick_callback = function() self:tick() end
    self.minute_callback = function() self:on_minute() end
    self.token, self.token_protected = self.token_store:load()
    self.build = function() return self:build_rows() end
    Page.init(self)
    self:schedule_minute()
end

-- One clock for all the screens: only the one on top shows the new minute.
function Home:schedule_minute()
    UIManager:unschedule(self.minute_callback)
    if not self.is_closed then
        UIManager:scheduleIn(60 - os.date("*t").sec, self.minute_callback)
    end
end

function Home:on_minute()
    local top = UIManager:getTopmostVisibleWidget()
    if top and top.strip_region then
        local region = top:strip_region()
        UIManager:setDirty(top, function() return "fast", region end)
    end
    self:schedule_minute()
end

function Home:info(text, timeout)
    Toast.show(text, timeout)
end

function Home:error_text(status)
    local s = self.strings
    if not status then
        return s.no_network
    elseif status == 401 then
        return s.bad_token
    elseif status == 403 then
        return s.no_permission
    elseif status == 429 then
        return s.rate_limited
    end
    return s.action_failed
end

function Home:connect_account()
    self:stop_network()
    self.token_rejected = nil
    self.token, self.token_protected = self.token_store:load()
    if not self.token then
        self:refresh_list()
        return
    end
    self.net = Net.new{
        token = self.token, dir = net_dir(), version = self.version,
        on_request = function() self:tick_soon() end,
        on_unauthorized = function() self:on_token_rejected() end,
    }
    if not self.net:start() then
        self.net = nil
        self:info(self.strings.start_failed, 5)
        self:refresh_list()
        return
    end
    self:schedule_tick()
    self:load_account()
    self:refresh_list()
end

function Home:load_account()
    self.account_tried_at = os.time()
    local problem_before = self.account_problem
    self.net:request(Api.account(), function(status, body, scopes)
        if status == 200 then
            self.account_problem = nil
            self.scopes = TokenScopes.parse(scopes)
            self.account = decode(body)
            self.my_id = self.account and self.account.id
            self.my_name = self.account and self.account.username
            self:open_events()
            self:reload_games()
            self:flush_puzzles()
            self:ensure_puzzles()
        elseif status == 401 then
            return
        else
            self.account_problem = self:error_text(status)
            -- Trying again in the background only redraws the page if there is something new to say.
            if self.account_problem == problem_before then
                return
            end
        end
        self:refresh_list()
    end)
end

-- From any request, at any moment. The token stays until the reader goes to connect another one.
function Home:on_token_rejected()
    if self.token_rejected then
        return
    end
    self.token_rejected = true
    self.account_problem = nil
    self:close_pages()
    self:info(self.strings.bad_token, 6)
    self:refresh_list()
end

function Home:should_retry_account()
    return not self.my_id and self.account_problem and not self.token_rejected
        and not self.suspended and not self.net:has_pending_request()
        and os.time() - (self.account_tried_at or 0) >= ACCOUNT_RETRY
end

function Home:schedule_tick()
    UIManager:unschedule(self.tick_callback)
    if self.is_closed or not self.net then
        return
    end
    UIManager:scheduleIn(self.net:has_pending_request() and TICK_BUSY or TICK_IDLE, self.tick_callback)
end

function Home:tick_soon()
    UIManager:unschedule(self.tick_callback)
    if not self.is_closed and self.net then
        UIManager:scheduleIn(TICK_SOON, self.tick_callback)
    end
end

function Home:tick()
    if not self.net then
        return
    end
    local ok, err = pcall(self.net.tick, self.net)
    if not ok then
        logger.warn("Ink Knight: network tick failed", err)
        self:info(self.strings.unexpected_error)
    end
    local minutes = self.settings:readSetting("refresh_minutes", 5)
    if minutes > 0 and self.my_id and not self.suspended and os.time() - (self.games_at or 0) >= minutes * 60 and not self:has_game_open() then
        self:reload_games()
    end
    if self:should_retry_account() then
        self:load_account()
    end
    self:schedule_tick()
end

function Home:has_game_open()
    return next(self.open_games) ~= nil
end

-- Lichess announces games and challenges through one stream per token.
function Home:open_events()
    if self.events or not self.net or self.suspended or self.token_rejected or not self:allows("events") then
        return
    end
    -- Lichess sends every pending challenge when the stream opens, and what happened while it was closed, such as
    -- a challenge declined during sleep, never comes. So the lists start over, and the hub redraws as they arrive.
    self.challenges, self.sent = {}, {}
    self.events = self.net:stream(Api.stream_events(), function(line)
        local event = decode(line)
        if event then
            self:on_event(event)
        end
    end, function()
        self.events = nil
        if not self.is_closed and not self.suspended then
            UIManager:scheduleIn(EVENT_RECONNECT, function() self:open_events() end)
        end
    end)
end

function Home:on_event(event)
    if event.type == "gameStart" then
        local game = event.game or {}
        self.seek_attempt = nil
        self:end_seek()
        if self.open_on_start and game.gameId then
            self.open_on_start = false
            self:open_game(game.gameId)
        end
        -- A game started from a challenge has the id of the challenge, so an accepted one leaves the list.
        if game.gameId and self.sent[game.gameId] then
            self.sent[game.gameId] = nil
            self:refresh_list()
        end
        self:reload_games()
    elseif event.type == "gameFinish" then
        self:reload_games()
    elseif event.type == "challenge" then
        local challenge = event.challenge or {}
        if challenge.id and Api.is_incoming(challenge, self.my_id) then
            self.challenges[challenge.id] = challenge
            self:refresh_list()
        elseif challenge.id and Api.is_outgoing(challenge, self.my_id) then
            self.sent[challenge.id] = challenge
            self:refresh_list()
        end
    elseif event.type == "challengeCanceled" or event.type == "challengeDeclined" then
        local challenge = event.challenge or {}
        if challenge.id then
            if self.challenges[challenge.id] then
                self.challenges[challenge.id] = nil
                self:refresh_list()
            elseif event.type == "challengeDeclined" then
                self.open_on_start = false
            end
            if self.sent[challenge.id] then
                self.sent[challenge.id] = nil
                if event.type == "challengeDeclined" then
                    self:info(string.format(self.strings.challenge_declined, self:challenge_target(challenge)), 5)
                end
                self:refresh_list()
            end
        end
    end
end

function Home:reload_games()
    if not self.net or self.token_rejected then
        return
    end
    self.games_at = os.time()
    self.net:request(Api.playing(), function(status, body)
        if status == 200 then
            local data = decode(body)
            self.games = Api.sort_games(data and data.nowPlaying or {})
            self.updated_at = os.date("%H:%M")
            self.load_problem = nil
        else
            self.load_problem = self:error_text(status)
        end
        self:refresh_list()
    end)
end

function Home:open_game(id)
    if self.open_games[id] or not Api.is_safe_id(id) then
        return
    end
    self:with_feature("play", function()
        self.open_games[id] = true
        LiveGame.open(self, id)
    end)
end

function Home:game_closed(id)
    self.open_games[id] = nil
    self:reload_games()
    self:refresh_list()
end

function Home:game_row(game)
    local s = self.strings
    local opponent = game.opponent and (game.opponent.username or (game.opponent.ai and ("Stockfish " .. game.opponent.ai))) or "?"
    return {
        kind = "game",
        text = opponent,
        detail = game.isMyTurn and s.your_turn or s.their_turn,
        value = Api.format_left(game.secondsLeft),
        mine = game.isMyTurn == true,
        callback = function() self:open_game(game.gameId) end,
    }
end

-- set: self.challenges, the ones received, by default, or self.sent.
function Home:challenge_list(set)
    local list = {}
    for _, challenge in pairs(set or self.challenges) do
        list[#list + 1] = challenge
    end
    table.sort(list, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return list
end

function Home:build_rows()
    local s = self.strings
    return {
        { kind = "hero", fill = true, icon = ICON_KNIGHT, text = s.games_title, detail = s.tagline },
        {
            kind = "primary",
            text = self.token and s.play_online or s.connect,
            callback = function()
                if self.token then
                    self:play_online()
                else
                    self:connect_menu()
                end
            end,
        },
        { kind = "tiles", columns = 2, fill = true, items = {
            { icon = ICON_KING, text = s.offline_game, callback = function() self:offline_menu() end },
            { icon = ICON_PAWN, text = s.about, callback = function() self:show_about() end },
        } },
        { kind = "secondary", text = s.quit, callback = function() UIManager:close(self) end },
    }
end

-- Asks for the Wi-Fi the way KOReader does, and goes on once it is connected.
function Home:play_online()
    require("ui/network/manager"):runWhenConnected(function()
        if not self.is_closed then
            self:open_hub()
        end
    end)
end

function Home:open_hub()
    if self.hub then
        return
    end
    self.hub = Page:new{
        title = self.strings.games_title,
        build = function(page)
            page.subtitle = self.my_name
            return self:hub_rows()
        end,
        on_closed = function()
            self.hub = nil
            self:leave_online()
        end,
    }
    UIManager:show(self.hub)
    self:connect_account()
end

function Home:leave_online()
    self:stop_network()
    self.account, self.my_id, self.my_name, self.scopes = nil, nil, nil, nil
    self.account_problem, self.load_problem, self.updated_at = nil, nil, nil
    self.account_tried_at, self.games_at = nil, nil
    self.token_rejected = nil
    self.games, self.challenges, self.sent = {}, {}, {}
    self.open_on_start = false
    self.seek_attempt = nil
    -- The requests of a review under way end with the network, so it is not left waiting for them.
    self.fetching_review = false
end

-- A row has room for one line, and the full sentence goes in the notice.
function Home:short_problem(text)
    return text == self.strings.no_network and self.strings.no_network_short or text
end

-- For what needs the account: without it, says why instead of doing nothing.
function Home:when_connected(action)
    if self.my_id then
        action()
    else
        self:info(self.account_problem or self.strings.loading)
    end
end

function Home:hub_rows()
    local s = self.strings
    local rows = {}
    if self.account_problem then
        rows[#rows + 1] = { text = self:short_problem(self.account_problem), detail = s.tap_to_retry, bold = true, callback = function() self:load_account() end }
    end
    if not self:allows("play") then
        rows[#rows + 1] = { text = s.token_cannot_play, bold = true, callback = function() self:show_token_scopes() end }
    end
    -- Received and sent share one line when both exist, so the games below keep their room.
    local received, sent = #self:challenge_list(), #self:challenge_list(self.sent)
    local challenge_buttons = {}
    if received > 0 then
        challenge_buttons[#challenge_buttons + 1] = { primary = true, text = string.format(s.challenges, received), callback = function() self:challenges_menu() end }
    end
    if sent > 0 then
        challenge_buttons[#challenge_buttons + 1] = { text = string.format(s.sent_challenges, sent), callback = function() self:sent_menu() end }
    end
    if #challenge_buttons > 0 then
        rows[#rows + 1] = { kind = "buttons", items = challenge_buttons }
    end
    local refreshed = not self.token_rejected and (self.load_problem and self:short_problem(self.load_problem) or (self.updated_at and string.format(s.updated_at, self.updated_at)))
    rows[#rows + 1] = { kind = "section", text = refreshed or s.your_games, action_text = s.refresh, action = function()
        if self.my_id then
            self:reload_games()
        else
            self:load_account()
        end
    end }
    for index, game in ipairs(self.games) do
        if index > MAX_GAMES_ON_HOME then
            break
        end
        rows[#rows + 1] = self:game_row(game)
    end
    if #self.games > MAX_GAMES_ON_HOME then
        rows[#rows + 1] = { text = string.format(s.all_games, #self.games), callback = function() self:all_games_menu() end }
    end
    if #self.games == 0 and self.my_id then
        rows[#rows + 1] = { kind = "text", text = s.no_games, center = true }
    end
    rows[#rows + 1] = { kind = "primary", text = s.new_game, callback = function() self:when_connected(function() self:new_game_menu() end) end }
    rows[#rows + 1] = { kind = "tiles", columns = 2, fill = true, items = {
        { icon = ICON_KING, text = s.computer_short, callback = function() self:computer_menu() end },
        { icon = ICON_KNIGHT, text = s.puzzles, callback = function() self:puzzles_menu() end },
        { icon = ICON_ROOK, text = s.past_short, callback = function() self:when_connected(function() self:past_games_menu() end) end },
        { icon = ICON_QUEEN, text = s.profile, callback = function() self:when_connected(function() Players.show(self, self.my_id) end) end },
        { icon = ICON_PAWN, text = s.players, callback = function() self:when_connected(function() Players.menu(self) end) end },
        { icon = ICON_BISHOP, text = s.settings_short, callback = function() self:settings_menu() end },
    } }
    if self.token_rejected then
        Page.disable_rows(rows)
        table.insert(rows, 1, { text = s.bad_token_short, detail = s.tap_to_connect_again, bold = true, callback = function() self:connect_again() end })
    end
    return rows
end

function Home:all_games_menu()
    self:open_page{ title = self.strings.your_games, build = function()
        local rows = {}
        for _, game in ipairs(self.games) do
            rows[#rows + 1] = self:game_row(game)
        end
        return rows
    end }
end

function Home:refresh_list()
    if self.hub then
        self.hub:reload()
    end
end

function Home:open_page(args)
    local closed = args.on_closed
    args.on_closed = function(page)
        for index = #self.pages, 1, -1 do
            if self.pages[index] == page then
                table.remove(self.pages, index)
            end
        end
        if closed then
            closed(page)
        end
    end
    local page = Page:new(args)
    self.pages[#self.pages + 1] = page
    UIManager:show(page)
    return page
end

function Home:open_list(title, rows)
    return self:open_page{ title = title, rows = rows }
end

-- opts.close_on_tap: for a choice that goes back to where it came from. Otherwise the page stays underneath,
-- and the way back goes one step at a time.
function Home:choose(title, rows, opts)
    return self:open_page{ title = title, rows = rows, close_on_tap = opts and opts.close_on_tap }
end

-- What ends a path through several pages, such as starting a game, closes them all.
function Home:close_pages()
    for index = #self.pages, 1, -1 do
        UIManager:close(self.pages[index])
    end
end

-- args: title, text, ok_text, cancel_text, on_ok, on_cancel. Going back answers nothing.
function Home:ask(args)
    local s = self.strings
    local rows = {}
    if args.text then
        rows[#rows + 1] = { kind = "text", text = args.text, center = true }
    end
    rows[#rows + 1] = { kind = "primary", text = args.ok_text or s.yes, callback = args.on_ok }
    rows[#rows + 1] = { kind = "secondary", text = args.cancel_text or s.cancel, callback = args.on_cancel or function() end }
    return self:open_page{ title = args.title, rows = rows, close_on_tap = true }
end

function Home:choose_promotion(moves, on_move)
    local s = self.strings
    local function tile(label, letter, icon)
        return { icon = icon, text = label, callback = function()
            for _, move in ipairs(moves) do
                if move.promotion == letter then
                    on_move(move)
                    return
                end
            end
        end }
    end
    self:choose(s.promote_to, { { kind = "tiles", columns = 2, fill = true, items = {
        tile(s.queen, "q", ICON_QUEEN), tile(s.rook, "r", ICON_ROOK),
        tile(s.bishop, "b", ICON_BISHOP), tile(s.knight, "n", ICON_KNIGHT),
    } } }, { close_on_tap = true })
end

function Home:is_rated()
    return self.settings:readSetting("rated", false) == true
end

function Home:allows(feature)
    return TokenScopes.allows(self.scopes, feature)
end

-- Runs the action if the token may do it, and otherwise says which permission is missing.
function Home:with_feature(feature, action)
    if self:allows(feature) then
        action()
    else
        self:info(string.format(self.strings.missing_permission, TokenScopes.FEATURES[feature][1]), 8)
    end
end

-- Options that also live next to what they change, so changing one does not mean going to the settings.
function Home:save_setting(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function Home:rated_row(page)
    local s = self.strings
    return { kind = "toggle", text = s.rated_default, on = self:is_rated(), on_text = s.yes, off_text = s.no, callback = function()
        self:save_setting("rated", not self:is_rated())
        page:reload()
    end }
end

function Home:margin_label(margin)
    local s = self.strings
    margin = margin or self.settings:readSetting("rating_margin", 0)
    return margin == 0 and s.margin_any or string.format(s.margin_value, margin)
end

function Home:choose_margin(after)
    local rows = {}
    for _, margin in ipairs(Api.RATING_MARGINS) do
        rows[#rows + 1] = { text = self:margin_label(margin), callback = function()
            self:save_setting("rating_margin", margin)
            after()
        end }
    end
    self:choose(self.strings.rating_margin, rows, { close_on_tap = true })
end

function Home:margin_row(page)
    return {
        text = self.strings.rating_margin, value = self:margin_label(), wide_value = true,
        callback = function() self:choose_margin(function() page:reload() end) end,
    }
end

function Home:refresh_label(minutes)
    local s = self.strings
    minutes = minutes or self.settings:readSetting("refresh_minutes", 5)
    return minutes == 0 and s.manual or string.format(s.every_minutes, minutes)
end

function Home:choose_refresh(after)
    local rows = {}
    for _, minutes in ipairs(REFRESH_CHOICES) do
        rows[#rows + 1] = { text = self:refresh_label(minutes), callback = function()
            self:save_setting("refresh_minutes", minutes)
            after()
        end }
    end
    self:choose(self.strings.refresh_interval, rows, { close_on_tap = true })
end

function Home:report_or(status, success)
    if status == 200 or status == 201 or status == 204 then
        success()
    else
        self:info(self:error_text(status))
    end
end

function Home:new_game_menu()
    local s = self.strings
    self:open_page{ title = s.new_game, build = function(page)
        return {
            { text = s.find_opponent, detail = s.find_opponent_detail, callback = function() self:with_feature("play", function() self:seek_menu() end) end },
            { text = s.correspondence, detail = s.correspondence_detail, callback = function() self:with_feature("play", function() self:seek_days_menu() end) end },
            { text = s.challenge_friend, detail = s.challenge_friend_detail, callback = function() self:with_feature("challenge", function() self:friend_menu() end) end },
            { kind = "section", text = s.options_section },
            self:rated_row(page),
            { text = s.refresh_interval, value = self:refresh_label(), wide_value = true, callback = function() self:choose_refresh(function() page:reload(); self:refresh_list() end) end },
        }
    end }
end

-- Times as tiles: the clock, with the kind of game Lichess will count it as.
function Home:clock_tiles(clocks, on_pick)
    local items = {}
    for _, clock in ipairs(clocks) do
        items[#items + 1] = {
            text = Api.clock_label(clock[1], clock[2]),
            detail = self.strings.perf_names[Api.perf_of_clock(clock[1], clock[2])],
            callback = function() on_pick(clock) end,
        }
    end
    return { kind = "tiles", columns = 3, items = items }
end

function Home:days_tiles(on_pick)
    local items = {}
    for _, days in ipairs(Api.DAYS) do
        items[#items + 1] = {
            text = tostring(days),
            detail = days == 1 and self.strings.day_short or self.strings.days_short,
            callback = function() on_pick(days) end,
        }
    end
    return { kind = "tiles", columns = 3, items = items }
end

-- The rating range of a seek, when the reader set a margin.
function Home:seek_range(perf)
    local account_perf = self.account and self.account.perfs and self.account.perfs[perf]
    return Api.rating_range(account_perf and account_perf.rating, self.settings:readSetting("rating_margin", 0))
end

function Home:seek_menu()
    local s = self.strings
    self:open_page{ title = s.find_opponent, build = function(page)
        return {
            { kind = "section", text = s.choose_time },
            self:clock_tiles(Api.REAL_TIME_SEEK, function(clock) self:start_seek(clock[1], clock[2]) end),
            { kind = "section", text = s.options_section },
            self:rated_row(page),
            self:margin_row(page),
        }
    end }
end

-- A real-time seek lives while its connection does, so the screen waits with the option to give up.
function Home:start_seek(minutes, increment)
    local s = self.strings
    self:close_pages()
    self.open_on_start = true
    local attempt = {}
    self.seek_attempt = attempt
    self.seek = self.net:stream(Api.seek_clock(minutes, increment, self:is_rated(), self:seek_range(Api.perf_of_clock(minutes, increment))), function() end, function()
        -- Lichess ended the search: either it found an opponent, whose game is announced on the event stream,
        -- or it refused the seek, or the network dropped. Only the absence of a game tells them apart.
        self.seek = nil
        self:end_seek()
        UIManager:scheduleIn(SEEK_GRACE, function()
            if self.seek_attempt == attempt and not self.is_closed then
                self.seek_attempt = nil
                self.open_on_start = false
                self:info(s.action_failed)
            end
        end)
    end)
    self.seek_box = self:open_page{
        title = s.find_opponent,
        close_on_tap = true,
        rows = {
            { kind = "hero", icon = ICON_KNIGHT, text = Api.clock_label(minutes, increment), detail = string.format(s.searching, Api.clock_label(minutes, increment)) },
            { kind = "secondary", text = s.cancel, callback = function() end },
        },
        -- Leaving this page, by any way, gives up the search.
        on_closed = function()
            self.seek_box = nil
            if self.seek then
                self.open_on_start = false
                self.seek_attempt = nil
                self:cancel_seek()
            end
        end,
    }
end

function Home:cancel_seek()
    if self.seek then
        self.net:close_stream(self.seek)
        self.seek = nil
    end
end

function Home:end_seek()
    self:cancel_seek()
    if self.seek_box then
        UIManager:close(self.seek_box)
    end
end

function Home:days_label(days)
    return days == 1 and self.strings.correspondence_day or string.format(self.strings.correspondence_days, days)
end

function Home:seek_days_menu()
    local s = self.strings
    self:open_page{ title = s.correspondence, build = function(page)
        return {
            { kind = "section", text = s.days_per_move },
            self:days_tiles(function(days)
                self:close_pages()
                self.net:request(Api.seek_days(days, self:is_rated(), self:seek_range("correspondence")), function(status)
                    self:report_or(status, function() self:info(s.seek_posted, 8) end)
                end)
            end),
            { kind = "section", text = s.options_section },
            self:rated_row(page),
            self:margin_row(page),
        }
    end }
end

function Home:friend_menu()
    Players.pick(self, self.strings.challenge_friend, function(username) self:challenge_time_menu(username) end)
end

function Home:ask_color(on_color)
    local s = self.strings
    local function tile(label, color, icon)
        return { icon = icon, text = label, callback = function() on_color(color) end }
    end
    self:choose(s.your_color, { { kind = "tiles", columns = 3, fill = true, items = {
        tile(s.color_random, "random", ICON_PAWN),
        tile(s.color_white, "white", "\226\153\148"),
        tile(s.color_black, "black", ICON_KING),
    } } })
end

function Home:challenge_time_menu(username)
    local s = self.strings
    self:open_page{ title = string.format(s.challenge_title, username), build = function(page)
        return {
            { text = s.with_clock, detail = s.with_clock_detail, callback = function() self:challenge_clock_menu(username) end },
            { text = s.correspondence, detail = s.correspondence_detail, callback = function() self:challenge_days_menu(username) end },
            { text = s.no_limit, detail = s.no_limit_detail, callback = function()
                self:ask_color(function(color)
                    self:send_challenge(Api.challenge_no_limit(username, color), username)
                end)
            end },
            { kind = "section", text = s.options_section },
            self:rated_row(page),
        }
    end }
end

function Home:challenge_clock_menu(username)
    local s = self.strings
    self:choose(s.with_clock, {
        self:clock_tiles(Api.CHALLENGE_CLOCKS, function(clock)
            self:ask_color(function(color)
                self:send_challenge(Api.challenge_clock(username, clock[1], clock[2], self:is_rated(), color), username)
            end)
        end),
    })
end

function Home:challenge_days_menu(username)
    local s = self.strings
    self:choose(s.days_per_move, {
        self:days_tiles(function(days)
            self:ask_color(function(color)
                self:send_challenge(Api.challenge_days(username, days, self:is_rated(), color), username)
            end)
        end),
    })
end

function Home:send_challenge(request, username)
    self:close_pages()
    self.net:request(request, function(status)
        self:report_or(status, function()
            self.open_on_start = true
            self:info(string.format(self.strings.challenge_sent, username), 5)
        end)
    end)
end

function Home:send_rematch(game, opponent_name)
    local request, starts = game:rematch_request()
    if not request then
        return
    end
    self:with_feature("challenge", function()
        if starts then
            self:start_ai_game(request)
        else
            self:send_challenge(request, opponent_name)
        end
    end)
end

function Home:challenges_menu()
    local s = self.strings
    local rows = {}
    for _, challenge in ipairs(self:challenge_list()) do
        local who = challenge.challenger and (challenge.challenger.name or challenge.challenger.id) or "?"
        local time = Api.time_control_text(challenge.timeControl, s.no_limit, function(days) return self:days_label(days) end)
        rows[#rows + 1] = { text = string.format(s.challenge_row, who, time), callback = function()
            self:with_feature("challenge", function() self:answer_challenge(challenge, who, time) end)
        end }
    end
    self:open_list(string.format(s.challenges, #rows), rows)
end

-- Who a challenge the reader sent goes to: a player, or anyone for an open challenge made on the site.
function Home:challenge_target(challenge)
    local dest = challenge.destUser
    return dest and (dest.name or dest.id) or self.strings.challenge_anyone
end

-- The challenges the reader sent and nobody answered yet, including rematches, each one able to be canceled.
-- A correspondence seek is not here: Lichess has no way to list or cancel one through the API.
function Home:sent_menu()
    local s = self.strings
    local page, open = nil, true
    page = self:open_page{ title = s.sent_challenges_title, on_closed = function() open = false end, build = function()
        local rows = {}
        for _, challenge in ipairs(self:challenge_list(self.sent)) do
            local who = self:challenge_target(challenge)
            local time = Api.time_control_text(challenge.timeControl, s.no_limit, function(days) return self:days_label(days) end)
            rows[#rows + 1] = {
                text = who, detail = challenge.rematchOf and string.format(s.challenge_row, time, s.rematch) or time,
                callback = function() self:ask_cancel_challenge(challenge, who, function() if open then page:reload() end end) end,
            }
        end
        if #rows == 0 then
            rows[1] = { kind = "text", text = s.no_sent_challenges, center = true }
        end
        return rows
    end }
end

-- after(): what to redraw once the challenge is gone.
function Home:ask_cancel_challenge(challenge, who, after)
    local s = self.strings
    self:ask{
        title = string.format(s.cancel_challenge_question, who),
        ok_text = s.cancel_challenge,
        cancel_text = s.back,
        on_ok = function()
            if not Api.is_safe_id(challenge.id) then
                return
            end
            self:with_feature("play", function()
                self.net:request(Api.cancel_challenge(challenge.id), function(status)
                    -- 404: it was already answered or expired, so it is no longer pending either way.
                    if status == 200 or status == 404 then
                        self.sent[challenge.id] = nil
                        self:info(status == 200 and s.challenge_canceled or s.challenge_gone)
                        self:refresh_list()
                        after()
                    else
                        self:info(self:error_text(status))
                    end
                end)
            end)
        end,
    }
end

function Home:answer_challenge(challenge, who, time)
    local s = self.strings
    if not Api.is_safe_id(challenge.id) then
        return
    end
    if not Api.challenge_is_supported(challenge) then
        local name = challenge.variant and challenge.variant.name or ""
        self:info(string.format(s.variant_unsupported, name), 5)
        self.net:request(Api.decline_challenge(challenge.id))
        self.challenges[challenge.id] = nil
        self:refresh_list()
        return
    end
    self:ask{
        title = string.format(s.challenge_from, who),
        text = challenge.rated and string.format("%s · %s", time, s.rated) or time,
        ok_text = s.accept,
        cancel_text = s.decline,
        on_ok = function()
            self.challenges[challenge.id] = nil
            self.open_on_start = true
            self:close_pages()
            self.net:request(Api.accept_challenge(challenge.id), function(status)
                self:report_or(status, function() end)
            end)
            self:refresh_list()
        end,
        on_cancel = function()
            self.challenges[challenge.id] = nil
            self:close_pages()
            self.net:request(Api.decline_challenge(challenge.id))
            self:refresh_list()
        end,
    }
end

function Home:computer_menu()
    local s = self.strings
    self:open_list(s.vs_computer, {
        { text = s.lichess_ai, detail = s.lichess_ai_detail, callback = function() self:with_feature("challenge", function() self:ai_level_menu() end) end },
        { text = s.offline_game, detail = s.offline_detail, callback = function() self:offline_menu() end },
    })
end

function Home:ai_level_menu()
    local s = self.strings
    local items = {}
    for _, level in ipairs(Api.AI_LEVELS) do
        items[#items + 1] = { text = tostring(level), detail = s.level_short, callback = function()
            self:choose(s.choose_time, {
                { text = Api.clock_label(15, 10), detail = s.with_clock_detail, callback = function()
                    self:ask_color(function(color) self:start_ai_game(Api.challenge_ai(level, 15, 10, color)) end)
                end },
                { text = s.no_limit, detail = s.no_limit_detail, callback = function()
                    self:ask_color(function(color) self:start_ai_game(Api.challenge_ai(level, nil, nil, color)) end)
                end },
            })
        end }
    end
    self:open_list(s.lichess_ai, { { kind = "tiles", columns = 4, items = items } })
end

function Home:start_ai_game(request)
    self:close_pages()
    self.net:request(request, function(status, body)
        self:report_or(status, function()
            local game = decode(body)
            if game and game.id then
                self:open_game(game.id)
            end
        end)
    end)
end

local function known_or(name, names, default)
    for _, known in ipairs(names) do
        if known == name then
            return name
        end
    end
    return default
end

-- Every board screen reads these when it paints, so a change shows in the next game without reopening anything.
function Home:apply_board_look()
    BoardScreen.style = known_or(self.settings:readSetting("board_style"), BoardScreen.style_names(), "plain")
    BoardScreen.piece_set = known_or(self.settings:readSetting("piece_set"), BoardScreen.piece_set_names(), "classic")
    BoardScreen.coordinates = self.settings:isTrue("board_coordinates")
end

-- sample(bb, name, x, y, size) draws each choice before its name, two sizes wide, so the drawings line up.
function Home:look_choice_row(page, title, labels, names, key, current, sample)
    return { text = title, value = labels[current], wide_value = true, callback = function()
        local rows = {}
        for _, name in ipairs(names) do
            rows[#rows + 1] = {
                text = labels[name], value = name == current and "✓" or nil,
                preview = function(bb, x, y, size) sample(bb, name, x, y, size) end, preview_columns = 2,
                callback = function()
                    self:save_setting(key, name)
                    self:apply_board_look()
                    page:reload()
                end,
            }
        end
        self:choose(title, rows, { close_on_tap = true })
    end }
end

function Home:board_look_rows(page)
    local s = self.strings
    return {
        self:look_choice_row(page, s.board_style, s.board_styles, BoardScreen.style_names(), "board_style", BoardScreen.style, BoardScreen.paint_style_sample),
        self:look_choice_row(page, s.piece_style, s.piece_styles, BoardScreen.piece_set_names(), "piece_set", BoardScreen.piece_set, BoardScreen.paint_piece_sample),
        { kind = "toggle", text = s.show_coordinates, on = BoardScreen.coordinates, on_text = s.yes, off_text = s.no, callback = function()
            self:save_setting("board_coordinates", not BoardScreen.coordinates)
            self:apply_board_look()
            page:reload()
        end },
    }
end

-- Rows of a page, with a list of rows spliced in where it falls.
local function spliced(rows)
    local out = {}
    for _, row in ipairs(rows) do
        if row.splice then
            for _, inner in ipairs(row.splice) do
                out[#out + 1] = inner
            end
        else
            out[#out + 1] = row
        end
    end
    return out
end

function Home:offline_menu()
    self:open_page{ title = self.strings.offline_game, build = function(page) return self:offline_rows(page) end }
end

function Home:offline_rows(page)
    local s = self.strings
    local rows = {}
    if self.settings:readSetting("offline_game") then
        rows[#rows + 1] = { kind = "primary", text = s.resume_offline, callback = function()
            self:close_pages()
            OfflineGame.open(self, { resume = true })
        end }
    end
    if self.settings:readSetting("two_player_game") then
        rows[#rows + 1] = { kind = "secondary", text = s.resume_two_players, callback = function()
            self:close_pages()
            OfflineGame.open(self, { resume = true, two_players = true })
        end }
    end
    rows[#rows + 1] = { kind = "section", text = s.new_game }
    local items = {}
    for level = 1, 4 do
        items[#items + 1] = { text = tostring(level), detail = s.level_short, callback = function()
            self:ask_color(function(color)
                self:close_pages()
                OfflineGame.open(self, { level = level, color_choice = color })
            end)
        end }
    end
    rows[#rows + 1] = { kind = "tiles", columns = 4, items = items }
    rows[#rows + 1] = { text = s.two_players, detail = s.two_players_detail, callback = function()
        self:close_pages()
        OfflineGame.open(self, { two_players = true })
    end }
    local saved_puzzles = #self:puzzle_pile()
    if saved_puzzles > 0 then
        rows[#rows + 1] = { kind = "section", text = s.puzzles }
        rows[#rows + 1] = {
            text = s.puzzle_next,
            detail = string.format(s.puzzles_saved, saved_puzzles),
            callback = function() PuzzleScreen.open(self, {}) end,
        }
    end
    local saved_reviews = #self:puzzle_pile(Puzzles.REVIEW)
    if saved_reviews > 0 then
        if saved_puzzles == 0 then
            rows[#rows + 1] = { kind = "section", text = s.puzzles }
        end
        rows[#rows + 1] = {
            text = s.puzzle_review,
            detail = string.format(s.puzzles_saved, saved_reviews),
            callback = function() self:open_review_pile() end,
        }
    end
    rows[#rows + 1] = { kind = "section", text = s.board_section }
    for _, row in ipairs(self:board_look_rows(page)) do
        rows[#rows + 1] = row
    end
    return rows
end

-- Puzzles: a pile is kept on the device, so they work with no network. Each theme has its own.
local function pile_key(angle)
    return angle and ("puzzles_" .. angle) or "puzzles"
end

function Home:puzzle_pile(angle)
    return self.settings:readSetting(pile_key(angle), {})
end

-- angle: a theme, or Puzzles.REVIEW for the missed ones, which come from their own list and not from a batch.
function Home:next_puzzle(angle)
    local pile = self:puzzle_pile(angle)
    local puzzle = table.remove(pile, 1)
    self.settings:saveSetting(pile_key(angle), pile)
    self.settings:flush()
    -- Out of the pile while on the screen, and not yet a result, so it is remembered for the next batch.
    self.puzzle_in_play = puzzle
    if angle ~= Puzzles.REVIEW then
        self:ensure_puzzles(angle)
    end
    return puzzle
end

-- The puzzles a new batch must not bring again: the one on the screen and those whose result waits to be sent.
function Home:known_puzzle_ids()
    local known = {}
    for _, result in ipairs(self.settings:readSetting("puzzle_results", {})) do
        known[result.id] = true
    end
    if self.puzzle_in_play then
        known[self.puzzle_in_play.id] = true
    end
    return known
end

function Home:return_puzzle(puzzle)
    local key = puzzle.pile or puzzle.angle
    local pile = self:puzzle_pile(key)
    table.insert(pile, 1, puzzle)
    self.settings:saveSetting(pile_key(key), pile)
    self.settings:flush()
end

function Home:open_review_pile()
    if #self:puzzle_pile(Puzzles.REVIEW) > 0 then
        PuzzleScreen.open(self, { angle = Puzzles.REVIEW, review = true })
    else
        self:info(self.strings.puzzle_review_none)
    end
end

-- Adds a fetched missed puzzle to the kept pile, once, so the screen finds it as soon as it arrives.
function Home:add_review_puzzle(puzzle)
    local pile = self:puzzle_pile(Puzzles.REVIEW)
    for _, kept in ipairs(pile) do
        if kept.id == puzzle.id then
            return
        end
    end
    puzzle.pile = Puzzles.REVIEW
    pile[#pile + 1] = puzzle
    self.settings:saveSetting(pile_key(Puzzles.REVIEW), pile)
    self.settings:flush()
end

-- The puzzles missed in the last days, as Lichess counts them, so mistakes made on the site come too. Online, the
-- pile is brought in line with that list first. Without a connection, or if Lichess does not answer, what is kept
-- is used. Each fetch takes a second or two on a Kindle, so the review opens with the first puzzle it has, and the
-- rest arrive while the reader solves it.
function Home:open_review()
    local s = self.strings
    if not self.net or not self:allows("puzzles") then
        self:open_review_pile()
        return
    end
    if self.fetching_review then
        self:info(s.puzzle_review_loading, 2)
        return
    end
    self.fetching_review = true
    self:info(s.puzzle_review_loading, 2)
    self.net:request(Api.puzzle_replay(Api.PUZZLE_DAYS), function(status, body)
        if status ~= 200 and status ~= 404 then
            self.fetching_review = false
            self:open_review_pile()
            return
        end
        -- 404: nothing left to review.
        local data = status == 200 and decode(body) or {}
        local remaining = data.replay and data.replay.remaining or {}
        local kept, missing = Puzzles.review_plan(self:puzzle_pile(Puzzles.REVIEW), remaining, self:known_puzzle_ids(), Puzzles.REVIEW_FETCH)
        self.settings:saveSetting(pile_key(Puzzles.REVIEW), kept)
        self.settings:flush()
        local opened = #kept > 0 or #missing == 0
        if opened then
            self:open_review_pile()
        end
        local function fetch(index)
            local id = missing[index]
            if not id or self.is_closed or not self.net then
                self.fetching_review = false
                if not opened then
                    self:open_review_pile()
                end
                return
            end
            self.net:request(Api.puzzle_by_id(id), function(puzzle_status, puzzle_body)
                local puzzle = puzzle_status == 200 and Puzzles.prepare(decode(puzzle_body) or {})
                if puzzle then
                    self:add_review_puzzle(puzzle)
                    if not opened then
                        opened = true
                        self:open_review_pile()
                    end
                end
                fetch(index + 1)
            end)
        end
        fetch(1)
    end)
end

function Home:ensure_puzzles(angle, on_done)
    local key = pile_key(angle)
    if not self.net or not self:allows("puzzles") or self.fetching_puzzles[key] or #self:puzzle_pile(angle) > Puzzles.LOW then
        return
    end
    self.fetching_puzzles[key] = true
    self.net:request(Api.puzzle_batch(Puzzles.BATCH_SIZE, angle), function(status, body)
        self.fetching_puzzles[key] = false
        local data = status == 200 and decode(body)
        if data and data.puzzles then
            local pile = self:puzzle_pile(angle)
            local incoming = {}
            for _, raw in ipairs(data.puzzles) do
                local puzzle = Puzzles.prepare(raw, angle)
                if puzzle then
                    incoming[#incoming + 1] = puzzle
                end
            end
            Puzzles.add_new(pile, incoming, self:known_puzzle_ids())
            self.settings:saveSetting(key, pile)
            self.settings:flush()
        end
        if on_done then
            on_done(status)
        end
    end)
end

function Home:add_puzzle_result(result)
    local results = self.settings:readSetting("puzzle_results", {})
    results[#results + 1] = result
    self.settings:saveSetting("puzzle_results", results)
    self.settings:flush()
    self:flush_puzzles()
end

-- Results wait on the device until they get through. A result lost to the network is sent again next time.
function Home:flush_puzzles()
    local results = self.settings:readSetting("puzzle_results", {})
    if not self.net or not self:allows("puzzle_results") or self.sending_results or #results == 0 then
        return
    end
    self.sending_results = true
    local angle, count = Puzzles.first_group(results)
    self.net:request(Api.puzzle_results(Puzzles.results_body(results, count), angle), function(status)
        self.sending_results = false
        if status == 200 then
            local current = self.settings:readSetting("puzzle_results", {})
            for _ = 1, count do
                table.remove(current, 1)
            end
            self.settings:saveSetting("puzzle_results", current)
            self.settings:flush()
            self:flush_puzzles()
        end
    end)
end

function Home:puzzles_menu()
    local s = self.strings
    self:open_list(s.puzzles, {
        { kind = "primary", text = s.puzzle_next, callback = function() PuzzleScreen.open(self, {}) end },
        { text = s.puzzle_daily, callback = function() self:open_daily_puzzle() end },
        { text = s.puzzle_review, detail = string.format(s.puzzle_review_detail, Api.PUZZLE_DAYS), callback = function()
            self:with_feature("puzzles", function() self:open_review() end)
        end },
        { text = s.puzzle_by_theme, callback = function() self:with_feature("puzzles", function() self:puzzle_themes_menu() end) end },
        { text = s.puzzle_stats, callback = function() self:with_feature("puzzles", function() self:show_puzzle_stats() end) end },
        { kind = "text", text = string.format(s.puzzles_saved, #self:puzzle_pile()), center = true },
    })
end

function Home:puzzle_themes_menu()
    local s = self.strings
    local rows = {}
    for _, angle in ipairs(Api.PUZZLE_THEMES) do
        rows[#rows + 1] = { text = s.puzzle_themes[angle], callback = function() self:open_theme_puzzles(angle) end }
    end
    self:open_list(s.puzzle_by_theme, { { kind = "tiles", columns = 2, items = rows } })
end

function Home:open_theme_puzzles(angle)
    if #self:puzzle_pile(angle) > 0 then
        PuzzleScreen.open(self, { angle = angle })
        return
    end
    self:ensure_puzzles(angle, function(status)
        self:report_or(status, function()
            PuzzleScreen.open(self, { angle = angle })
        end)
    end)
end

function Home:show_puzzle_stats()
    local s = self.strings
    self.net:request(Api.puzzle_dashboard(Api.PUZZLE_DAYS), function(status, body)
        self:report_or(status, function()
            local data = decode(body) or {}
            local global = data.global
            if not global or (global.nb or 0) == 0 then
                self:info(s.puzzle_no_stats)
                return
            end
            local function first_try(results)
                return math.floor((results.firstWins or 0) / math.max(results.nb or 1, 1) * 100 + 0.5)
            end
            local rows = {
                { kind = "stat", text = s.puzzle_stat_solved, value = tostring(global.nb) },
                { kind = "stat", text = s.puzzle_stat_first, value = first_try(global) .. "%" },
                { kind = "stat", text = s.puzzle_stat_performance, value = tostring(global.performance or "?") },
            }
            local themes = {}
            for _, theme in pairs(data.themes or {}) do
                if theme.results then
                    themes[#themes + 1] = theme
                end
            end
            table.sort(themes, function(a, b) return (a.results.nb or 0) > (b.results.nb or 0) end)
            if #themes > 0 then
                rows[#rows + 1] = { kind = "section", text = s.puzzle_by_theme }
            end
            for _, theme in ipairs(themes) do
                rows[#rows + 1] = {
                    kind = "stat",
                    text = theme.theme or "?",
                    value = string.format(s.puzzle_stat_theme_row, theme.results.nb or 0, first_try(theme.results)),
                }
            end
            self:open_list(string.format(s.puzzle_stats_title, Api.PUZZLE_DAYS), rows)
        end)
    end)
end

function Home:open_daily_puzzle()
    self.net:request(Api.puzzle_daily(), function(status, body)
        self:report_or(status, function()
            local puzzle = Puzzles.prepare(decode(body) or {})
            if puzzle then
                PuzzleScreen.open(self, { puzzle = puzzle, daily = true })
            else
                self:info(self.strings.action_failed)
            end
        end)
    end)
end

-- Past games.
local function game_result_text(s, game)
    if game.status == "aborted" or game.status == "noStart" then
        return s.outcome_aborted
    end
    if game.winner == "white" then
        return s.white_wins
    elseif game.winner == "black" then
        return s.black_wins
    end
    return s.outcome_draw
end

function Home:past_games_menu()
    local s = self.strings
    self:open_list(s.past_games, {
        { text = s.my_games, callback = function() self:show_past_games(self.my_id) end },
        { text = s.favorites, callback = function() self:show_favorites() end },
    })
end

-- name: whose games they are, when they are not the reader's.
function Home:show_past_games(player_id, name)
    if not player_id then
        return
    end
    local s = self.strings
    local request = Api.past_games(player_id, 30)
    if player_id == self.my_id then
        self:show_game_list(request, player_id, s.my_games, s.no_past_games)
    else
        self:show_game_list(request, player_id, string.format(s.player_games, name), string.format(s.player_no_games, name))
    end
end

function Home:show_favorites()
    if not self.my_id then
        return
    end
    self:show_game_list(Api.bookmarks(30), self.my_id, self.strings.favorites, self.strings.no_favorites, true)
end

-- Evaluations only exist if someone asked Lichess to analyze the game on the site.
local function add_game_analysis(moves, analysis)
    for index, entry in ipairs(analysis or {}) do
        if moves[index] and type(entry) == "table" then
            if entry.eval or entry.mate then
                moves[index].eval_text = Api.eval_text(entry.eval, entry.mate)
            end
            if type(entry.judgment) == "table" then
                moves[index].judgment = entry.judgment.name
            end
        end
    end
end

-- player_id: whose side the list takes, for the results and for which way the board faces.
function Home:show_game_list(request, player_id, title, empty_text, bookmarked)
    local s = self.strings
    self.net:request(request, function(status, body)
        self:report_or(status, function()
            local rows = {}
            for line in tostring(body):gmatch("[^\n]+") do
                local game = decode(line)
                if game and game.moves and (game.variant == "standard" or game.variant == nil) then
                    local players = game.players or {}
                    local white, black = Game.player_name(players.white, s.anonymous), Game.player_name(players.black, s.anonymous)
                    local text, detail, on_black = Game.past_summary(s, game, player_id, self.my_id)
                    rows[#rows + 1] = {
                        kind = "game",
                        text = text,
                        detail = detail,
                        callback = function()
                            local moves = Pgn.san_list_to_moves(game.moves)
                            add_game_analysis(moves, game.analysis)
                            ReviewScreen.open(self, {
                                moves = moves,
                                white = white, black = black,
                                intro = game.opening and game.opening.name,
                                result_text = game_result_text(s, game),
                            }, { flipped = on_black, game_id = Api.is_safe_id(game.id) and game.id or nil, bookmarked = bookmarked })
                        end,
                    }
                end
            end
            if #rows == 0 then
                self:info(empty_text)
            else
                self:open_list(title or s.past_games, rows)
            end
        end)
    end)
end

function Home:settings_menu()
    local s = self.strings
    self:open_page{ title = s.settings, build = function(page)
        return spliced({
            { kind = "section", text = s.options_section },
            self:rated_row(page),
            { kind = "toggle", text = s.confirm_moves, on = self.settings:isTrue("confirm_moves"), on_text = s.yes, off_text = s.no, callback = function()
                self:save_setting("confirm_moves", not self.settings:isTrue("confirm_moves"))
                page:reload()
            end },
            { text = s.refresh_interval, value = self:refresh_label(), wide_value = true, callback = function() self:choose_refresh(function() page:reload(); self:refresh_list() end) end },
            self:margin_row(page),
            { kind = "section", text = s.board_section },
            { splice = self:board_look_rows(page) },
            { kind = "section", text = s.account_section },
            { text = s.token_scopes, value = self:scopes_summary(), callback = function() self:show_token_scopes() end },
            { text = s.token_status, value = self.token_protected and s.token_status_protected or s.token_status_shared, callback = function()
                self:open_list(s.token_status, { { kind = "text", text = self.token_protected and s.token_protected_text or s.token_unprotected } })
            end },
            { text = s.about, callback = function() self:show_about() end },
            { text = s.disconnect, callback = function() self:ask_disconnect() end },
        })
    end }
end

function Home:scopes_summary()
    local s = self.strings
    if not self.scopes then
        return s.token_scopes_unknown
    end
    local missing = TokenScopes.missing_count(self.scopes)
    return missing == 0 and s.token_scopes_all or string.format(s.token_scopes_missing, missing)
end

function Home:show_token_scopes()
    local s = self.strings
    local rows = {}
    for _, feature in ipairs(TokenScopes.LISTED) do
        local scope = TokenScopes.FEATURES[feature][1]
        local allowed = self:allows(feature)
        rows[#rows + 1] = {
            text = s.scope_names[feature],
            value = not self.scopes and "?" or (allowed and "✓" or s.scope_absent),
            callback = function()
                self:info(string.format(allowed and s.scope_present_text or s.missing_permission, scope), 6)
            end,
        }
    end
    rows[#rows + 1] = { kind = "primary", text = s.token_create_other, callback = function() self:open_create_token() end }
    self:open_list(s.token_scopes, rows)
end

function Home:open_create_token()
    UIManager:show(CreateTokenScreen:new{ strings = self.strings, on_ready = function() self:open_token_page() end })
end

function Home:open_token_page()
    local s = self.strings
    UIManager:show(TokenScreen:new{ strings = s, on_token = function(token) self:accept_token(token) end })
end

function Home:show_about()
    local s = self.strings
    self:open_list(s.about, {
        { kind = "hero", icon = ICON_KNIGHT, text = s.games_title, detail = string.format(s.about_version, self.version) },
        { kind = "text", text = s.about_text, center = true },
    })
end

function Home:ask_disconnect()
    self:ask{
        title = self.strings.disconnect,
        text = self.strings.disconnect_question,
        ok_text = self.strings.disconnect,
        on_ok = function() self:forget_token() end,
    }
end

function Home:forget_token()
    self.token_store:clear()
    self.token, self.token_protected = nil, nil
    self:close_pages()
    if self.hub then
        UIManager:close(self.hub)
    end
    self:reload()
end

-- The refused token goes first, so leaving without connecting comes back to the first page asking for an account.
function Home:connect_again()
    self:forget_token()
    self:connect_menu()
end

function Home:connect_menu()
    local s = self.strings
    self:open_list(s.connect, {
        { kind = "text", text = s.token_steps },
        { kind = "primary", text = s.token_create, callback = function() self:open_create_token() end },
        { kind = "secondary", text = s.token_from_phone, callback = function() self:open_token_page() end },
        { kind = "secondary", text = s.token_type, callback = function() self:type_token() end },
    })
end

function Home:type_token()
    local s = self.strings
    local dialog
    dialog = InputDialog:new{
        title = s.token_input_title,
        buttons = { {
            { text = s.cancel, id = "close", callback = function() UIManager:close(dialog) end },
            { text = s.send, is_enter_default = true, callback = function()
                local token = (dialog:getInputText() or ""):gsub("%s+", "")
                UIManager:close(dialog)
                if TokenAccess.is_valid_token(token) then
                    self:accept_token(token)
                else
                    self:info(s.token_invalid)
                end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Home:accept_token(token)
    self.account_problem = nil
    self:close_pages()
    local saved, protected = self.token_store:save(token)
    if saved then
        self.token, self.token_protected = token, protected
        self:reload()
        if self.hub then
            self:connect_account()
        else
            self:open_hub()
        end
        if not protected then
            self:info(self.strings.token_unprotected, 8)
        end
    else
        self:info(self.strings.start_failed)
    end
end

function Home:stop_network()
    UIManager:unschedule(self.tick_callback)
    self.events, self.seek = nil, nil
    if self.net then
        self.net:stop()
        self.net = nil
    end
end

function Home:onSuspend()
    self.suspended = true
    if self.events and self.net then
        self.net:close_stream(self.events)
        self.events = nil
    end
    self.open_on_start = false
    self.seek_attempt = nil
    self:end_seek()
end

function Home:onResume()
    self.suspended = false
    if self.net and self.my_id then
        self:open_events()
        self:reload_games()
    end
end

function Home:onCloseWidget()
    self.is_closed = true
    UIManager:unschedule(self.minute_callback)
    self:stop_network()
    BoardScreen.clear_art_cache()
    Page.onCloseWidget(self)
end

return Home
