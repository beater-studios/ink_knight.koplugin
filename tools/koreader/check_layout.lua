-- The layout of Ink Knight in one screen size, run by tools/koreader/check_all_sizes.sh in four: every page and the
-- board fit the screen in the three languages, the texts of a fixed width fit at their size, the About page shows
-- the version of _meta.lua, a game without internet continues in a new screen, the e-ink updates come in the order
-- they should, and the Back key goes back. The network is invented, and the token page never listens.
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=<desktop KOReader> tools/koreader/run_headless.sh tools/koreader/check_layout.lua
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))
local out_dir = assert(os.getenv("OUTPUT_DIR"))
require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path
local Device = require("device")
local Screen = Device.screen
Device.hasBattery = function() return true end
Device.getPowerDevice = function() return { getCapacity = function() return 87 end } end
require("document/canvascontext"):init(Device)
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
UIManager:init()
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")

local BoardScreen = require("ink_knight/ui/board_screen")
local Chess = require("ink_knight/chess")
local Home = require("ink_knight/ui/home")
local LiveGame = require("ink_knight/ui/live_game")
local Net = require("ink_knight/net")
local OfflineGame = require("ink_knight/ui/offline_game")
local Page = require("ink_knight/ui/page")
local SavedState = require("ink_knight/saved_state")
local StatusStrip = require("ink_knight/ui/status_strip")

require("ink_knight/awake").install("ink_knight")
require("ink_knight/lan").install("ink_knight")
require("ink_knight/ui/token_screen").local_ip = "203.0.113.7"
local meta = dofile(plugin_dir .. "/_meta.lua")
local size = string.format("%dx%d", Screen:getWidth(), Screen:getHeight())

local problems = 0
local function problem(text)
    problems = problems + 1
    print("PROBLEM " .. size .. ": " .. text)
end

-- The invented Lichess, with names as long as the ones Lichess allows (20 letters).
local LONG_NAME = "Alessandra_Vasconcel"
local GAME = string.format('{"gameId":"layoutgm","fullId":"layoutgmxxxx","color":"white","isMyTurn":true,"secondsLeft":259200,'
    .. '"opponent":{"id":"%s","username":"%s","rating":2999},"speed":"correspondence"}', LONG_NAME:lower(), LONG_NAME)
local ANSWERS = {
    ["/api/account"] = string.format('{"id":"%s","username":"%s","perfs":{"rapid":{"rating":1500}}}', LONG_NAME:lower(), LONG_NAME),
    ["/api/account/playing"] = '{"nowPlaying":[' .. string.rep(GAME .. ",", 5) .. GAME .. ']}',
}
-- A player with every part of the profile: activity, notes, a linked FIDE player and Puzzle Storm.
local OTHER = "Bartholomew_Vasconce"
ANSWERS["/api/user/" .. OTHER:lower()] = string.format('{"id":"%s","username":"%s","following":true,"fideId":35009192,"perfs":{"rapid":{"rating":2999,"games":9999},'
    .. '"storm":{"runs":999,"score":99}}}', OTHER:lower(), OTHER)
ANSWERS["/api/user/" .. OTHER:lower() .. "/activity"] = '[{"interval":{"start":1792972800000,"end":1793059200000},'
    .. '"games":{"correspondence":{"win":999,"loss":999,"draw":999,"rp":{"before":2999,"after":2999}}},'
    .. '"puzzles":{"score":{"win":999,"loss":999,"draw":0,"rp":{"before":2999,"after":2999}}},"storm":{"runs":999,"score":99},'
    .. '"correspondenceMoves":{"nb":999,"games":[]},"tournaments":{"nb":99},"follows":{"in":{"ids":["a"]},"out":{"ids":["b"]}}}]'
ANSWERS["/api/user/" .. OTHER:lower() .. "/note"] = '[{"text":"' .. string.rep("A note long enough to wrap over several lines. ", 6) .. '","date":1790000000000}]'
ANSWERS["/api/fide/player/35009192"] = '{"id":35009192,"name":"Vasconcelos Alessandra Bartholomew","federation":"BRA","title":"WGM","standard":2999,"rapid":2999,"blitz":2999,"year":1999}'
ANSWERS["/api/storm/dashboard/" .. OTHER:lower()] = '{"high":{"day":99,"week":99,"month":99,"allTime":99},"days":[{"_id":"2026/11/12","score":99,"runs":999}]}'
-- The explorers, with the longest opening name of the list of Lichess, large counts and a draw-heavy move.
local EXPLORER = '{"opening":{"name":"Queen\'s Gambit Declined: Semi-Tarrasch Defense, Pillsbury Variation"},"moves":['
    .. '{"san":"Nxe5+","white":9999999,"draws":5000000,"black":4000000},{"san":"O-O-O","white":1,"draws":98,"black":1},'
    .. '{"san":"exd8=Q+","white":0,"draws":0,"black":120000},{"san":"Kf1","white":50000,"draws":0,"black":0}]}'
ANSWERS["/lichess"] = EXPLORER
ANSWERS["/masters"] = EXPLORER
ANSWERS["/api/account/preferences"] = '{"prefs":{"autoQueen":3,"coords":1,"submitMove":2,"pieceSet":"merida"},"language":"en-US"}'
ANSWERS["/api/cloud-eval"] = '{"depth":99,"pvs":[{"moves":"e2e4 e7e5 g1f3 b8c6 f1b5 a7a6","mate":-12}]}'
-- Broadcasts with the longest names: a tournament live, coming and past, its rounds and standings, a round of 16
-- games and one game in PGN with clocks.
local BROADCAST_TOUR = "FIDE World Senior Chess Championships 2026 | Open 50+ | Group Stage | Combined Standings"
local BROADCAST_NAME = "Vasconcelos, Alessandra Bartholomew Maximiliana"
local BROADCAST_ITEM = '{"tour":{"id":"BcastTour","name":"' .. BROADCAST_TOUR .. '"},"round":{"id":"BcastRnd1","name":"Round 10 (Tiebreaks)","startsAt":1794600000000}}'
ANSWERS["/api/broadcast/top"] = '{"active":[' .. BROADCAST_ITEM .. '],"upcoming":[' .. BROADCAST_ITEM .. '],"past":{"currentPageResults":[' .. BROADCAST_ITEM .. '],"nextPage":2}}'
local rounds = {}
for index = 1, 11 do
    rounds[index] = string.format('{"id":"BcastRnd%d","name":"Round %d (Tiebreaks)","finished":%s,"ongoing":%s,"startsAt":1794600000000}', index, index, index < 10 and "true" or "false", index == 10 and "true" or "false")
end
ANSWERS["/api/broadcast/BcastTour"] = '{"tour":{"id":"BcastTour","name":"' .. BROADCAST_TOUR .. '","info":{"format":"11-round Swiss with Armageddon tiebreaks","tc":"90 min / 40 moves + 30 min + 30 sec / move","location":"Banja Koviljaca, Loznica, Serbia"}},"rounds":[' .. table.concat(rounds, ",") .. '],"defaultRoundId":"BcastRnd10"}'
local standings, round_games = {}, {}
for index = 1, 16 do
    standings[index] = string.format('{"name":"%s","title":"WGM","rating":2999,"score":10.5,"played":11,"rank":%d}', BROADCAST_NAME, index)
    round_games[index] = string.format('{"id":"Game%d","status":"%s","players":[{"name":"%s","title":"WGM","rating":2999,"clock":3599900},{"name":"%s","title":"WCM","rating":2999,"clock":3599900}]}', index, index % 2 == 0 and "*" or "1/2-1/2", BROADCAST_NAME, BROADCAST_NAME)
end
ANSWERS["/broadcast/BcastTour/players"] = "[" .. table.concat(standings, ",") .. "]"
ANSWERS["/api/broadcast/-/-/BcastRnd10"] = '{"round":{"id":"BcastRnd10","name":"Round 10"},"games":[' .. table.concat(round_games, ",") .. ']}'
ANSWERS["/api/broadcast/round/BcastRnd10.pgn"] = '[Event "Round 10"]\n[White "' .. BROADCAST_NAME .. '"]\n[Black "' .. BROADCAST_NAME .. '"]\n[WhiteTitle "WGM"]\n[BlackTitle "WCM"]\n[WhiteElo "2999"]\n[BlackElo "2999"]\n[Result "*"]\n[Opening "Nimzo-Indian Defense: Sämisch Variation, Keres Variation"]\n[GameURL "https://lichess.org/broadcast/x/round-10/BcastRnd10/Game2"]\n\n1. d4 { [%clk 9:59:59] } 1... Nf6 { [%clk 9:59:58] } 2. c4 { [%clk 1:28:54] } *\n'
ANSWERS["/api/player"] = '{"correspondence":[{"id":"' .. OTHER:lower() .. '","username":"' .. OTHER .. '","title":"WCM","perfs":{"correspondence":{"rating":2999}}}]}'

local real_new = Net.new
Net.new = function(opts)
    opts.ca_file = plugin_dir .. "/LICENSE"
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

-- Texts drawn in a fixed width: measured at their size without the cut, they must fit.
local where = "?"
local function wrap_paint_text(class)
    local paint_text = class.paint_text
    class.paint_text = function(self, bb, text, name, font_size, x, y, w, ...)
        if text and text ~= "" then
            local Font = require("ui/font")
            local widget = TextWidget:new{ text = text, face = Font:getFace(name, font_size * self.scale * 1000 / Screen:scaleBySize(1000)) }
            local natural = widget:getSize().w
            widget:free()
            if natural > w then
                problem(string.format("%s: \"%s\" needs %d px and has %d", where, text, natural, w))
            end
        end
        return paint_text(self, bb, text, name, font_size, x, y, w, ...)
    end
end
wrap_paint_text(Page)
wrap_paint_text(BoardScreen)

local function shot(name)
    UIManager:forceRePaint()
    Screen.bb:writePNG(out_dir .. "/" .. name .. ".png")
end

-- Every sheet of a page fits between its header and the status strip, and each one is drawn.
local function check_page(page, name)
    where = name
    local room = Screen:getHeight() - StatusStrip.height() - page:content_top()
    for index, sheet in ipairs(page.sheets) do
        local used = 0
        for _, line in ipairs(sheet) do
            used = used + page.heights_of[line]
        end
        local limit = #page.sheets > 1 and room - page:px(58) or room
        if used > limit then
            problem(string.format("%s, sheet %d: %d px of rows in %d", name, index, used, limit))
        end
        page.sheet = index
        UIManager:setDirty(page, "ui")
        shot(name:gsub("[^%w]+", "_") .. "_" .. index)
    end
    page.sheet = 1
end

local function top_page()
    local stack = UIManager._window_stack
    return stack[#stack].widget
end

local function close_all()
    local stack = UIManager._window_stack
    while #stack > 0 do
        UIManager:close(stack[#stack].widget)
    end
end

-- The buttons of the board wrap their text: it must still fit the height of the button.
local function check_board(board, name)
    where = name
    shot(name:gsub("[^%w]+", "_"))
    local bottom = board.buttons_rect.y + board.buttons_rect.h
    if bottom > Screen:getHeight() - StatusStrip.height() then
        problem(name .. ": the buttons go past the status strip")
    end
    local Font = require("ui/font")
    for _, rect in ipairs(board:button_rects()) do
        local box = TextBoxWidget:new{ text = rect.label, face = Font:getFace("noto/NotoSans-Bold.ttf", 17 * board.scale * 1000 / Screen:scaleBySize(1000)), width = rect.w - board:px(8) }
        local h = box:getSize().h
        box:free()
        if h > rect.h then
            problem(string.format("%s: the button \"%s\" needs %d px of height and has %d", name, rect.label, h, rect.h))
        end
    end
end

local settings_path = DataStorage:getSettingsDir() .. "/ink_knight.lua"
local function new_home(language)
    G_reader_settings:saveSetting("language", language)
    local home = Home:new{ plugin_dir = plugin_dir, version = meta.version }
    UIManager:show(home)
    UIManager:forceRePaint()
    return home
end

local function connect(home)
    where = "online, connecting"
    local token = "lip_" .. string.rep("0", 20)
    home.token_store = { load = function() return token, true end, save = function() return true, true end, clear = function() end }
    home.token = token
    home:open_hub()
    for _ = 1, 10 do
        home.net:tick()
    end
    UIManager:forceRePaint()
end

-- Every screen in every language.
for _, language in ipairs({ "en", "pt", "es" }) do
    close_all()
    SavedState.remove_file(settings_path)
    local home = new_home(language)
    check_page(home, language .. " first page")
    for _, open in ipairs({ "offline_menu", "pack_menu", "coordinates_menu", "learn_menu", "practice_menu", "show_about", "connect_menu" }) do
        home[open](home)
        check_page(top_page(), language .. " " .. open)
        UIManager:close(top_page())
    end
    -- The choice of piece sets, each with its sample, and a board with each set.
    home:offline_menu()
    local offline_page = top_page()
    local piece_row
    for _, line in ipairs(offline_page.lines) do
        piece_row = piece_row or (line.text == home.strings.piece_style and line)
    end
    if not piece_row then
        problem(language .. " offline menu: no row to choose the pieces")
    else
        piece_row.callback()
        check_page(top_page(), language .. " piece sets")
        UIManager:close(top_page())
    end
    UIManager:close(offline_page)
    if language == "pt" then
        -- A picture that does not load falls back to the classic pieces without a word, so each one is drawn here.
        local RenderImage = require("ui/renderimage")
        for _, set in ipairs(BoardScreen.piece_set_names()) do
            if set ~= "classic" then
                for _, name in ipairs({ "wK", "wQ", "wR", "wB", "wN", "wP", "bK", "bQ", "bR", "bB", "bN", "bP" }) do
                    local ok, image = pcall(RenderImage.renderSVGImageFile, RenderImage, plugin_dir .. "/ink_knight/pieces/" .. set .. "/" .. name .. ".svg", 64, 64)
                    if not ok or not image then
                        problem("pieces " .. set .. ": " .. name .. " does not draw")
                    else
                        image:free()
                    end
                end
            end
        end
        for _, set in ipairs(BoardScreen.piece_set_names()) do
            home.settings:saveSetting("piece_set", set)
            home:apply_board_look()
            local sample_game = OfflineGame.open(home, { two_players = true, initial_fen = "r1bqkb1r/pp3ppp/2n1pn2/2pp4/3P4/2PBPN2/PP1N1PPP/R1BQK2R w KQkq - 0 7" })
            check_board(sample_game.screen, "pieces " .. set)
            UIManager:close(sample_game.screen)
            home.settings:delSetting("two_player_game")
        end
        home.settings:delSetting("piece_set")
        home:apply_board_look()
    end
    -- The page of Chess960, and a game of it against the engine, with its number before the first move.
    home:chess960_menu(959)
    check_page(top_page(), language .. " chess960")
    UIManager:close(top_page())
    local chess960_game = OfflineGame.open(home, { level = 4, color_choice = "white", initial_fen = Chess.chess960_fen(959) })
    check_board(chess960_game.screen, language .. " chess960 game")
    UIManager:close(chess960_game.screen)
    home.settings:delSetting("offline_game")
    -- Correspondence kept offline, with the longest names, one game with a move waiting.
    local Correspondence = require("ink_knight/correspondence")
    local kept = {}
    for index, fen in ipairs({ "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1", Chess.START_FEN }) do
        kept[index] = Correspondence.from_playing({ gameId = "corr000" .. index, color = "black", fen = fen, speed = "correspondence",
            secondsLeft = 1209600, opponent = { username = LONG_NAME } }, os.time() - 90000)
    end
    Correspondence.play(kept[1], Chess.parse_uci(Chess.parse_fen(kept[1].fen), "e7e5"))
    home:save_correspondence({ account = LONG_NAME:lower(), name = LONG_NAME, games = kept })
    home:offline_menu()
    check_page(top_page(), language .. " offline menu with correspondence")
    -- A game between two people that ended, with the most buttons: undo, moves, flip, analyze and again.
    local ended = OfflineGame.open(home, { two_players = true })
    for _, uci in ipairs({ "e2e4", "e7e5", "d1h5", "b8c6", "f1c4", "g8f6", "h5f7" }) do
        ended:on_square(Chess.square_from_name(uci:sub(1, 2)))
        ended:on_square(Chess.square_from_name(uci:sub(3, 4)))
    end
    check_board(ended.screen, language .. " two players after mate")
    UIManager:close(ended.screen)
    home.settings:delSetting("two_player_game")
    -- The position editor, its palette, its options with castling, and what to do with the position.
    home.settings:saveSetting("editor_fen", Chess.START_FEN)
    local editor = require("ink_knight/ui/editor_screen").open(home)
    check_board(editor.screen, language .. " editor")
    editor:choose_piece()
    check_page(top_page(), language .. " editor palette")
    UIManager:close(top_page())
    editor.position = require("ink_knight/editor").new("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
    editor:options()
    check_page(top_page(), language .. " editor options")
    UIManager:close(top_page())
    editor:done()
    check_page(top_page(), language .. " editor play")
    UIManager:close(top_page())
    UIManager:close(editor.screen)
    home.settings:delSetting("editor_fen")
    -- Learn chess: the longest goal of each language in the banner, and the end of a stage.
    local categories = require("ink_knight/data/learn_stages")
    local pawn_stage = categories[1].stages[6]
    local lesson = require("ink_knight/ui/learn_screen").open(home, pawn_stage, 1)
    check_board(lesson.screen, language .. " learn banner")
    if lesson.screen.banner_overflow then
        problem(language .. " learn banner: the goal does not fit even at the smallest size")
    end
    UIManager:close(lesson.screen)
    home:learn_stage_done(categories[3].stages[2])
    check_page(top_page(), language .. " learn stage done")
    UIManager:close(top_page())
    -- The practice lessons: a study and its end, a chapter with the longest description (with Read, the most
    -- buttons of a chapter with a goal), the guided chapter with the longest name, and the commented game, which has
    -- the most buttons.
    local Practice = require("ink_knight/practice")
    local PracticeScreen = require("ink_knight/ui/practice_screen")
    local practice_sections = require("ink_knight/data/practice")
    local practice_texts = home:practice_texts()
    local longest = {}
    for _, section in ipairs(practice_sections) do
        for _, study in ipairs(section.studies) do
            for index, item in ipairs(study.chapters) do
                local field = item.kind == "goal" and ".d" or ".n"
                local length = #(practice_texts[item.id .. field] or "")
                if length > (longest[item.kind] and longest[item.kind].length or -1) then
                    longest[item.kind] = { study = study, index = index, length = length }
                end
            end
        end
    end
    for _, kind in ipairs({ "goal", "guided", "lesson" }) do
        local chosen = longest[kind]
        home:practice_study(chosen.study)
        check_page(top_page(), language .. " practice study " .. kind)
        UIManager:close(top_page())
        local pages_before = #home.pages
        local chapter_screen = PracticeScreen.open(home, chosen.study, chosen.index)
        -- A guided chapter with a description opens with it on a page.
        if #home.pages > pages_before then
            check_page(top_page(), language .. " practice introduction " .. kind)
            UIManager:close(top_page())
        end
        check_board(chapter_screen.screen, language .. " practice " .. kind)
        UIManager:close(chapter_screen.screen)
    end
    home:practice_study_done(practice_sections[1].studies[1])
    check_page(top_page(), language .. " practice study done")
    UIManager:close(top_page())
    -- The coordinate training in both modes, with no limit, which has the most buttons.
    home:save_setting("coordinates_time", "none")
    for _, mode in ipairs({ "find", "name" }) do
        home:save_setting("coordinates_mode", mode)
        local training = require("ink_knight/ui/coordinates_screen").open(home)
        training:start()
        check_board(training.screen, language .. " coordinates " .. mode)
        UIManager:close(training.screen)
    end
    home.settings:delSetting("coordinates_time")
    home.settings:delSetting("coordinates_mode")
    -- A game between two people with a clock, which adds Pause to the buttons, and the chess clock, whose buttons
    -- and time must fit at a readable size.
    local two = OfflineGame.open(home, { two_players = true, clock = "30+20" })
    two:on_square(Chess.square_from_name("e2"))
    two:on_square(Chess.square_from_name("e4"))
    check_board(two.screen, language .. " two players with a clock")
    UIManager:close(two.screen)
    home.settings:delSetting("two_player_game")
    local clock = require("ink_knight/ui/clock_screen").open(home, "30+20")
    clock:press("w")
    where = language .. " chess clock"
    shot(where:gsub("[^%w]+", "_"))
    local Font = require("ui/font")
    for _, rect in ipairs(clock:button_rects()) do
        local widget = require("ui/widget/textwidget"):new{ text = rect.label, face = Font:getFace("noto/NotoSans-Bold.ttf", 16 * clock.scale * 1000 / Screen:scaleBySize(1000)) }
        local w = widget:getSize().w
        widget:free()
        if w > rect.w - clock.px(12) then
            problem(string.format("%s: the button \"%s\" needs %d px and has %d", where, rect.label, w, rect.w - clock.px(12)))
        end
    end
    UIManager:close(clock)
    local corr = require("ink_knight/ui/correspondence_screen").open(home, "corr0001")
    check_board(corr.screen, language .. " correspondence offline")
    UIManager:close(corr.screen)
    UIManager:close(top_page())
    home.settings:delSetting("correspondence")
    connect(home)
    check_page(home.hub, language .. " online")
    for _, open in ipairs({ "new_game_menu", "seek_menu", "seek_days_menu", "computer_menu", "puzzles_menu", "settings_menu", "all_games_menu" }) do
        home[open](home)
        check_page(top_page(), language .. " " .. open)
        UIManager:close(top_page())
    end
    -- The preferences of the site brought into the options, and what they now are.
    home:settings_menu()
    local settings_page = top_page()
    local import_row
    for _, line in ipairs(settings_page.lines) do
        import_row = import_row or (line.text == home.strings.import_preferences and line)
    end
    if not import_row then
        problem(language .. " settings: no row to bring the preferences")
    else
        import_row.callback()
        for _ = 1, 20 do
            home.net:tick()
        end
        while top_page() and not top_page().content_top do
            UIManager:close(top_page())
        end
        check_page(top_page(), language .. " preferences brought")
        if not (home:option("auto_queen") and home:option("board_coordinates") and home:option("confirm_moves") and home:option("piece_set") == "merida") then
            problem(language .. " the preferences of the site should be in the options")
        end
        UIManager:close(top_page())
        for _, key in ipairs({ "auto_queen", "board_coordinates", "confirm_moves", "piece_set" }) do
            home.settings:delSetting(key)
        end
        home:apply_board_look()
    end
    UIManager:close(settings_page)
    -- The profile of another player with every part, each part, and the rankings.
    local Players = require("ink_knight/ui/players")
    local function settle()
        for _ = 1, 10 do
            home.net:tick()
        end
    end
    Players.show(home, OTHER:lower())
    settle()
    local profile = top_page()
    check_page(profile, language .. " profile")
    for _, name in ipairs({ "profile_activity", "profile_notes", "profile_fide" }) do
        local found
        for _, line in ipairs(profile.lines) do
            if line.text == home.strings[name] then
                found = line
            end
        end
        if not found then
            problem(language .. " profile: no row " .. name)
        else
            found.callback()
            settle()
            check_page(top_page(), language .. " " .. name)
            UIManager:close(top_page())
        end
    end
    -- Blocking asks first, with the longest name.
    local block_row
    for _, line in ipairs(profile.lines) do
        if line.text == home.strings.block_player then
            block_row = line
        end
    end
    if not block_row then
        problem(language .. " profile: no row to block")
    else
        block_row.callback()
        local confirm = top_page()
        check_page(confirm, language .. " block confirm")
        if not confirm.lines[1].text:find(home.strings.block_unfollows, 1, true) then
            problem(language .. " block confirm: a player followed should be told the follow goes too")
        end
        -- Confirmed: the profile asks Lichess again, and the row then offers to unblock.
        local plain = ANSWERS["/api/user/" .. OTHER:lower()]
        ANSWERS["/api/user/" .. OTHER:lower()] = plain:gsub('^{', '{"blocking":true,'):gsub('"following":true,', '')
        for _, line in ipairs(confirm.lines) do
            if line.kind == "primary" then
                line.callback()
            end
        end
        UIManager:close(confirm)
        settle()
        ANSWERS["/api/user/" .. OTHER:lower()] = plain
        local unblock_row
        for _, line in ipairs(profile.lines) do
            unblock_row = unblock_row or (line.text == home.strings.unblock_player and line)
        end
        local follow_row
        for _, line in ipairs(profile.lines) do
            follow_row = follow_row or (line.text == home.strings.follow_player and line)
        end
        if not unblock_row or not follow_row then
            problem(language .. " profile: blocking should leave rows to unblock and to follow again")
        end
        -- The notice that says so is not a page.
        while top_page() and not top_page().content_top do
            UIManager:close(top_page())
        end
        check_page(profile, language .. " profile blocked")
        -- Unblocking asks nothing and gives the row back.
        if unblock_row then
            ANSWERS["/api/user/" .. OTHER:lower()] = plain:gsub('"following":true,', '')
            local pages_before = #home.pages
            unblock_row.callback()
            if #home.pages ~= pages_before then
                problem(language .. " unblock should not ask")
            end
            settle()
            ANSWERS["/api/user/" .. OTHER:lower()] = plain
            local again
            for _, line in ipairs(profile.lines) do
                again = again or (line.text == home.strings.block_player and line)
            end
            if not again then
                problem(language .. " profile: unblocking should give the row to block back")
            end
            while top_page() and not top_page().content_top do
                UIManager:close(top_page())
            end
        end
    end
    Players.show_storm(home, OTHER:lower())
    settle()
    check_page(top_page(), language .. " profile storm")
    UIManager:close(top_page())
    UIManager:close(profile)
    Players.show_rankings(home)
    settle()
    check_page(top_page(), language .. " rankings")
    UIManager:close(top_page())
    -- The broadcasts: the lists, a tournament, its standings, a round being played and a game with its clocks.
    local Broadcasts = require("ink_knight/ui/broadcasts")
    Broadcasts.menu(home)
    settle()
    check_page(top_page(), language .. " broadcasts")
    Broadcasts.tournament(home, "BcastTour")
    settle()
    check_page(top_page(), language .. " broadcast tournament")
    Broadcasts.standings(home, "BcastTour", BROADCAST_TOUR)
    settle()
    check_page(top_page(), language .. " broadcast standings")
    Broadcasts.round(home, "BcastRnd10", "Round 10 (Tiebreaks)")
    settle()
    local round_page = top_page()
    check_page(round_page, language .. " broadcast round")
    Broadcasts.game(home, "BcastRnd10", { id = "Game2" })
    settle()
    local review = top_page()
    if not (review.state and review.state.bottom and review.state.bottom.clock == "1:28:54" and review.state.top.clock == "9:59:58") then
        problem(language .. " broadcast game: the clocks of each side should show on the bars")
    end
    check_board(review, language .. " broadcast game")
    UIManager:close(review)
    home:close_pages()
    -- Keeping a tournament: the row to keep it, its progress, a download cut short to resume, and the kept pages with
    -- no network. The download is invented: a child writes the files and its progress at once.
    local Downloader = require("ink_knight/download")
    local tournament_data = home.decode(ANSWERS["/api/broadcast/BcastTour"])
    local store = home:broadcast_store()
    home:save_broadcast_index({})
    -- Files a previous run left would count as kept.
    store:delete(require("ink_knight/broadcast_store").entry_of(tournament_data, 0))
    local cut_short = true
    home.downloads = Downloader.new{ work_dir = out_dir .. "/downloads", hosts = { "lichess.org" },
        spawn = function(list, progress)
            local count, done = 0, 0
            for line in io.lines(list) do
                count = count + 1
                local path = line:match("\t(.+)$")
                -- The first download stops after one file, as when the Wi-Fi drops.
                if not (cut_short and done >= 1) then
                    local file = io.open(path, "wb")
                    file:write(ANSWERS["/api/broadcast/round/BcastRnd10.pgn"])
                    file:close()
                    done = done + 1
                end
            end
            local file = io.open(progress, "wb")
            file:write(string.format("%d %d %d end%s", done, count - done, count, cut_short and " stopped" or ""))
            file:close()
            return 1
        end,
        is_done = function() return true end,
        kill = function() end,
    }
    home.downloads.parts = 1
    local save = Broadcasts.save_row(home, tournament_data, function() end)
    if save.text ~= home.strings.broadcast_save then
        problem(language .. " keep broadcast: the row should offer to keep the tournament: " .. tostring(save.text))
    end
    save.callback()
    for _ = 1, 5 do home.downloads:tick() end
    home:tick_downloads()
    local resume = Broadcasts.save_row(home, tournament_data, function() end)
    if resume.text ~= string.format(home.strings.broadcast_resume, 9) or resume.detail ~= home.strings.broadcast_stopped then
        problem(language .. " keep broadcast: a download cut short should offer to resume: " .. tostring(resume.text) .. " / " .. tostring(resume.detail))
    end
    cut_short = false
    resume.callback()
    for _ = 1, 5 do home.downloads:tick() end
    local kept = Broadcasts.save_row(home, tournament_data, function() end)
    if kept.text ~= home.strings.broadcast_saved then
        problem(language .. " keep broadcast: everything kept: " .. tostring(kept.text))
    end
    Broadcasts.saved_menu(home)
    check_page(top_page(), language .. " kept broadcasts")
    Broadcasts.saved_tournament(home, home:saved_broadcasts()[1], function() end)
    check_page(top_page(), language .. " kept tournament")
    Broadcasts.saved_round(home, home:saved_broadcasts()[1], home:saved_broadcasts()[1].rounds[1])
    check_page(top_page(), language .. " kept round")
    top_page().lines[1].callback()
    check_board(top_page(), language .. " kept game")
    UIManager:close(top_page())
    home:close_pages()
    store:delete(home:saved_broadcasts()[1])
    home:save_broadcast_index({})
    home.downloads = nil
    -- A game being played: new moves are followed from the last move, and left alone from an earlier one.
    local ReviewScreen = require("ink_knight/ui/review_screen")
    local live_game = { moves = { { uci = "e2e4", san = "e4", clock = 600 }, { uci = "e7e5", san = "e5", clock = 590 } }, white = "A", black = "B" }
    local live = ReviewScreen.open(home, live_game, { refresh = function() end })
    if live.index ~= 2 then
        problem(language .. " live review: should open on the last move, at " .. live.index)
    end
    live:update({ moves = { live_game.moves[1], live_game.moves[2], { uci = "g1f3", san = "Nf3", clock = 580 } }, white = "A", black = "B" })
    if live.index ~= 3 or live.screen.state.bottom.clock ~= "9:40" or live.screen.state.top.clock ~= "9:50" then
        problem(language .. " live review: a new move should be followed, with the clocks")
    end
    live:go(1)
    live:update({ moves = { live_game.moves[1], live_game.moves[2], { uci = "g1f3", san = "Nf3" }, { uci = "b8c6", san = "Nc6" } }, white = "A", black = "B", result_text = "1-0" })
    if live.index ~= 1 or live.available ~= 4 then
        problem(language .. " live review: a reader looking back should stay where they are")
    end
    -- The relay corrects a move it misread: the board keeps only the moves still the same.
    live:go(4)
    live:update({ moves = { live_game.moves[1], live_game.moves[2], { uci = "b1c3", san = "Nc3" } }, white = "A", black = "B" })
    if live.available ~= 3 or live.index ~= 3 or live.game.moves[3].san ~= "Nc3" or not live.positions[3].board[19] then
        problem(language .. " live review: a corrected move should replace the old ones")
    end
    UIManager:close(live.screen)
    -- The summary of the analysis of a game, with the longest names Lichess allows.
    local summary_moves = {}
    for index = 1, 300 do
        summary_moves[index] = index % 2 == 1 and { uci = "g1f3", san = "Nf3" } or { uci = "g8f6", san = "Nf6" }
        if index % 4 == 3 then
            summary_moves[index] = { uci = "f3g1", san = "Ng1" }
        elseif index % 4 == 0 then
            summary_moves[index] = { uci = "f6g8", san = "Ng8" }
        end
    end
    local phases = { opening = 100, middlegame = 100, endgame = 100 }
    local summary_review = require("ink_knight/ui/review_screen").open(home, { moves = summary_moves, white = LONG_NAME, black = LONG_NAME, summary = {
        white = { accuracy = 100, inaccuracy = 99, mistake = 99, blunder = 99, acpl = 999, phases = phases },
        black = { accuracy = 100, inaccuracy = 99, mistake = 99, blunder = 99, acpl = 999, phases = phases },
        middle = 199, ending = 299,
    } })
    summary_review:show_summary()
    check_page(top_page(), language .. " review summary")
    UIManager:close(top_page())
    UIManager:close(summary_review.screen)
    -- The analysis of a position, with the evaluation, the bars of the moves and the way to the other explorers,
    -- and the page of masters.
    local ReviewScreen = require("ink_knight/ui/review_screen")
    local function settle_page()
        for _ = 1, 40 do
            home.net:tick()
        end
        -- The notice that it is asking is not a page.
        while top_page() and not top_page().content_top do
            UIManager:close(top_page())
        end
    end
    ReviewScreen.analyze(home, Chess.parse_fen(Chess.START_FEN), "white")
    settle_page()
    check_page(top_page(), language .. " analysis")
    UIManager:close(top_page())
    ReviewScreen.masters(home, Chess.parse_fen(Chess.START_FEN))
    settle_page()
    check_page(top_page(), language .. " analysis masters")
    UIManager:close(top_page())
    -- The longest status line of a review: a move that starts a phase, with its evaluation, mark and better move.
    local busy = require("ink_knight/ui/review_screen").open(home, {
        moves = { { uci = "e2e4", san = "e4" }, { uci = "e7e5", san = "e5" }, { uci = "g1f3", san = "Nf3" }, { uci = "b8c6", san = "Nc6" },
            { uci = "f1c4", san = "Bc4" }, { uci = "f8c5", san = "Bc5" }, { uci = "b2b4", san = "b4" }, { uci = "c5b4", san = "Bxb4", eval_text = "#-12", judgment = "Inaccuracy", best = "Qxb4+" } },
        white = "A", black = "B",
        summary = { white = { inaccuracy = 0, mistake = 0, blunder = 0 }, black = { inaccuracy = 1, mistake = 0, blunder = 0 }, middle = 8 },
    })
    busy:go(8)
    check_board(busy.screen, language .. " review phase status")
    UIManager:close(busy.screen)
    -- The puzzles by opening, with the longest names of the list of Lichess, the largest count and a recent one.
    home.puzzle_openings = {
        { key = "Sicilian_Defense", name = "Sicilian Defense", count = 207281, openings = {} },
        { key = "Vienna_Gambit_with_Max_Lange_Defense", name = "Vienna Gambit, with Max Lange Defense", count = 1037, openings = {} },
        { key = "Queens_Gambit_Accepted", name = "Queen's Gambit Accepted", count = 13899, openings = {
            { key = "Queens_Gambit_Accepted_Accelerated_Mannheim_Variation", name = "Accelerated Mannheim Variation", count = 197 },
        } },
    }
    home.settings:saveSetting("puzzle_openings_recent", { { key = "Queens_Gambit_Accepted_Accelerated_Mannheim_Variation", name = "Queen's Gambit Accepted: Accelerated Mannheim Variation" } })
    home:show_puzzle_openings()
    check_page(top_page(), language .. " puzzle openings")
    UIManager:close(top_page())
    home:show_opening_family(home.puzzle_openings[3])
    check_page(top_page(), language .. " puzzle opening family")
    UIManager:close(top_page())
    home.settings:delSetting("puzzle_openings_recent")

    -- The board with the longest bar of buttons a live game has, and a name as long as Lichess allows.
    local live = LiveGame.open(home, "layoutgm")
    live.game:on_event({ type = "gameFull", speed = "rapid", clock = { initial = 600000, increment = 0 },
        white = { id = LONG_NAME:lower(), name = LONG_NAME, rating = 2999 }, black = { id = "other", name = LONG_NAME, rating = 2999 },
        state = { moves = "e2e4 e7e5 g1f3", wtime = 3599000, btime = 3599000, status = "started" } }, os.time())
    live:render()
    check_board(live.screen, language .. " live game")
    -- The name of the opening only after the game, as Lichess does for its players.
    live:on_button("moves")
    if top_page().lines[1].kind == "text" then
        problem(language .. " live game: the list of moves names the opening during the game")
    end
    UIManager:close(top_page())
    live.game:on_event({ type = "gameState", moves = "e2e4 e7e5 g1f3", wtime = 3599000, btime = 3599000,
        status = "resign", winner = "white" }, os.time())
    live:on_button("moves")
    if top_page().lines[1].text ~= "King's Knight Opening" then
        problem(language .. " live game: the list of moves should name the opening after the game, got "
            .. tostring(top_page().lines[1].text))
    end
    check_page(top_page(), language .. " moves of a finished game")
    UIManager:close(top_page())
    UIManager:close(live.screen)
    local offline = OfflineGame.open(home, { level = 4, color_choice = "black" })
    check_board(offline.screen, language .. " offline game")
    UIManager:close(offline.screen)
    UIManager:close(home)
end

-- The About page shows the version of _meta.lua.
close_all()
SavedState.remove_file(settings_path)
local home = new_home("en")
home:show_about()
local found = false
for _, line in ipairs(top_page().lines) do
    found = found or (line.detail or ""):find(meta.version, 1, true) ~= nil
end
if not found then
    problem("the About page does not show the version " .. meta.version)
end
UIManager:close(top_page())

-- A game without internet continues in a new screen, with the same moves.
local game = OfflineGame.open(home, { two_players = true })
for _, move in ipairs({ { "e2", "e4" }, { "c7", "c5" } }) do
    game:on_square(Chess.square_from_name(move[1]))
    game:on_square(Chess.square_from_name(move[2]))
end
local moves = game.moves
UIManager:close(game.screen)
UIManager:close(home)
local reopened = new_home("en")
local resumed = reopened:saved_game("two_player_game") and OfflineGame.open(reopened, { resume = true, two_players = true })
if not resumed or resumed.moves ~= moves or moves ~= "e2e4 c7c5" then
    problem("the game between two people did not continue: " .. tostring(resumed and resumed.moves))
end
if resumed then
    UIManager:close(resumed.screen)
end

-- The e-ink updates: the plugin opens with a flash, the pages count together and flash after eight updates
-- without one, the board opens with a flash and a move only touches its squares, and closing the plugin flashes.
close_all()
local real_set_dirty = UIManager.setDirty
local log = {}
UIManager.setDirty = function(_, _, refresh)
    if type(refresh) == "function" then
        refresh = (refresh())
    end
    log[#log + 1] = refresh
end
local first = new_home("en")
for _ = 1, 4 do
    first:offline_menu()
    UIManager:close(top_page())
end
first:offline_menu()
local pages = table.concat(log, ",")
if pages ~= "full,ui,ui,ui,ui,ui,ui,ui,ui,full" then
    problem("updates of the pages: " .. pages)
end
UIManager:close(top_page())
log = {}
local board_game = OfflineGame.open(first, { two_players = true })
board_game:on_square(Chess.square_from_name("e2"))
board_game:on_square(Chess.square_from_name("e4"))
-- Showing the board and drawing its first state both ask for a flash, which KOReader joins into one.
local board = table.concat(log, ",")
local after_opening = board:gsub("^full,", ""):gsub("^full,", "")
if not board:match("^full,") or not after_opening:match("^ui") or after_opening:find("full", 1, true) then
    problem("updates of the board: " .. board)
end
UIManager:close(board_game.screen)
log = {}
UIManager:close(first)
if log[#log] ~= "full" then
    problem("closing the plugin should flash, got " .. table.concat(log, ","))
end
UIManager.setDirty = real_set_dirty

-- The Back key goes back one step: a page closes, a live game with a clock asks first, and KOReader's Close before
-- powering off leaves every window as it is.
close_all()
local back_home = new_home("en")
back_home:offline_menu()
local page = top_page()
page:handleEvent(Event:new("Back"))
if UIManager:isWidgetShown(page) then
    problem("Back did not close a page")
end
back_home:show_about()
page = top_page()
page:handleEvent(Event:new("Close", { keep_screensaver = true }))
if not UIManager:isWidgetShown(page) then
    problem("Close before powering off closed a page")
end
UIManager:close(page)
connect(back_home)
local clock_game = LiveGame.open(back_home, "layoutgm")
clock_game.game:on_event({ type = "gameFull", speed = "rapid", clock = { initial = 600000, increment = 0 },
    white = { id = LONG_NAME:lower(), name = LONG_NAME }, black = { id = "other", name = "Other" },
    state = { moves = "e2e4 e7e5", wtime = 590000, btime = 595000, status = "started" } }, os.time())
clock_game.screen:handleEvent(Event:new("Back"))
if not UIManager:isWidgetShown(clock_game.screen) or top_page() == clock_game.screen then
    problem("Back in a game with a clock should ask before leaving")
end
UIManager:close(top_page())
UIManager:close(clock_game.screen)
local hub = back_home.hub
hub:handleEvent(Event:new("Back"))
if UIManager:isWidgetShown(hub) then
    problem("Back did not leave the online part")
end
back_home:handleEvent(Event:new("Back"))
if UIManager:isWidgetShown(back_home) then
    problem("Back on the first page did not close the plugin")
end
close_all()

print(string.format("layout %s: %s", size, problems == 0 and "ok" or (problems .. " problem(s)")))
os.exit(problems == 0 and 0 or 1)
