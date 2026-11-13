-- Plays games without internet on the real screens: against the engine, choosing a color, taking back and asking for
-- a hint; between two people on the same device; and the list of moves, also in a review.
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=... tools/koreader/run_headless.sh tools/koreader/check_offline_game.lua
local plugin_dir = assert(os.getenv("PLUGIN_DIR"))
local out_dir = assert(os.getenv("OUTPUT_DIR"))
require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path
local Device = require("device")
local Screen = Device.screen
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
UIManager:init()
local Chess = require("ink_knight/chess")
local Home = require("ink_knight/ui/home")
local I18n = require("ink_knight/i18n")
local OfflineGame = require("ink_knight/ui/offline_game")

local s = I18n.en
local failures = 0
local function check(condition, message)
    if not condition then
        failures = failures + 1
        print("FAILED: " .. message)
    end
end

-- The engine works through scheduled slices. Here they run in order, as fast as they can.
local queue = {}
UIManager.scheduleIn = function(_, _, callback)
    queue[#queue + 1] = callback
end
-- The clock of the status strip schedules itself every minute, so it is left out.
local home
-- The timers of a window go through sleep.lua, which schedules a stand-in for each function: this tells whether
-- the stand-in is the one of fn on the window.
local function stands_for(callback, window, fn)
    local state = window and window._sleep
    return state ~= nil and state.tasks[fn] == callback
end
local function run_scheduled()
    local guard = 0
    while #queue > 0 do
        guard = guard + 1
        assert(guard < 100000, "the scheduled work never ended")
        local callback = table.remove(queue, 1)
        if not stands_for(callback, home, home.minute_callback) then
            callback()
        end
    end
end

local function buttons(game)
    local ids = {}
    for _, button in ipairs(game.screen.state.buttons) do
        ids[#ids + 1] = button.id
    end
    return table.concat(ids, " ")
end

local function play(game, from, to)
    game:on_square(Chess.square_from_name(from))
    game:on_square(Chess.square_from_name(to))
end

local function count(moves)
    local total = 0
    for _ in moves:gmatch("%S+") do
        total = total + 1
    end
    return total
end

home = Home:new{ version = "0" }
UIManager:show(home)
home.settings:delSetting("offline_game")

-- White, chosen: nothing to take back at the start, then a move and the answer go back together.
do
    local game = OfflineGame.open(home, { level = 1, color_choice = "white" })
    check(game.my_color == "w", "choosing white should give white")
    check(buttons(game) == "back hint resign", "at the start: " .. buttons(game))
    play(game, "e2", "e4")
    check(game.thinking, "the engine should think after the move")
    run_scheduled()
    check(count(game.moves) == 2, "the engine should answer, moves: " .. game.moves)
    check(buttons(game) == "back undo hint moves resign", "after a move: " .. buttons(game))
    game:on_button("undo")
    check(game.moves == "", "undo should take back the move and the answer, moves: " .. game.moves)
    check(game.position.turn == "w", "it should be white's turn again")
    check(home.settings:readSetting("offline_game").moves == "", "the game should be saved after undo")

    -- Undo while the engine thinks: its move must not land afterwards.
    play(game, "d2", "d4")
    check(game.thinking, "the engine should be thinking")
    game:on_button("undo")
    check(not game.thinking, "undo should stop the engine")
    run_scheduled()
    check(game.moves == "", "the stopped search should not play, moves: " .. game.moves)

    -- A hint marks a move, and a tap on its square plays it.
    game:on_button("hint")
    check(game.hinting, "the hint should be searching")
    check(game.screen.state.status == s.hint_thinking, "the status should say a hint is coming")
    run_scheduled()
    check(game.selected and game.targets, "the hint should mark a piece and a square")
    check(game.hint_text and game.hint_text:find("Suggestion: ", 1, true), "the status should name the move: " .. tostring(game.hint_text))
    game.screen:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/offline_hint.png")
    local target
    for square in pairs(game.targets) do
        target = square
    end
    game:on_square(target)
    check(count(game.moves) == 1, "tapping the hinted square should play it, moves: " .. game.moves)
    check(game.hint_text == nil, "the suggestion should go once the move is played")
    run_scheduled()

    UIManager:close(game.screen)
end

-- Black, chosen: the engine starts, and undo never takes back its first move.
do
    local game = OfflineGame.open(home, { level = 1, color_choice = "black" })
    check(game.my_color == "b", "choosing black should give black")
    run_scheduled()
    check(count(game.moves) == 1, "the engine should open, moves: " .. game.moves)
    check(not buttons(game):find("undo", 1, true), "nothing of black to take back yet: " .. buttons(game))
    local legal = Chess.legal_moves(game.position)[1]
    play(game, Chess.square_name(legal.from), Chess.square_name(legal.to))
    run_scheduled()
    check(count(game.moves) == 3, "after black's move and the answer, moves: " .. game.moves)
    local first = game.moves:match("^%S+")
    game:on_button("undo")
    check(game.moves == first, "undo should keep the engine's first move, moves: " .. game.moves)
    check(game.color_choice == "black", "the choice should be kept")
    -- Playing again keeps the color chosen: the new game is black again, and the engine opens it.
    home.settings:delSetting("offline_game")
    game.resigned = true
    game:on_button("again")
    run_scheduled()
    local again = home.settings:readSetting("offline_game")
    check(again and again.my_color == "b" and again.color_choice == "black", "playing again should keep black")
    UIManager:close(UIManager:getTopmostVisibleWidget())
end

-- Saved games keep the choice, and a game lost by mate can be taken back.
do
    home.settings:saveSetting("offline_game", { level = 2, my_color = "w", color_choice = "white", moves = "f2f3 e7e5 g2g4 d8h4" })
    local game = OfflineGame.open(home, { resume = true })
    check(game.color_choice == "white", "a saved game should keep the choice")
    check(game.ending == "mate", "the saved game should be over by mate")
    check(buttons(game) == "back undo moves analyze again", "after mate: " .. buttons(game))
    game:on_button("undo")
    check(game.moves == "f2f3 e7e5", "undo after mate should go back to white's last move, moves: " .. game.moves)
    check(game.ending == nil, "the game should go on after undo")
    UIManager:close(game.screen)
end

-- Two people on the same device: whoever is to move plays, undo takes back one move, the board turns when asked, and
-- the game is kept apart from the one against the engine.
do
    home.settings:delSetting("two_player_game")
    home.settings:saveSetting("offline_game", { level = 3, my_color = "w", color_choice = "white", moves = "e2e4" })
    local game = OfflineGame.open(home, { two_players = true })
    run_scheduled()
    check(game.screen.state.status == s.local_turn_w, "white should start: " .. tostring(game.screen.state.status))
    check(buttons(game) == "back flip resign", "two players at the start: " .. buttons(game))
    check(game.screen.state.bottom.name == s.color_white and game.screen.state.top.name == s.color_black, "white below, black above")
    play(game, "e2", "e4")
    run_scheduled()
    check(game.moves == "e2e4" and not game.thinking, "no engine should answer, moves: " .. game.moves)
    check(game.screen.state.status == s.local_turn_b, "then black: " .. tostring(game.screen.state.status))
    play(game, "e7", "e5")
    check(game.moves == "e2e4 e7e5", "black should play from the same device, moves: " .. game.moves)
    check(buttons(game) == "back undo moves flip resign", "two players after moves: " .. buttons(game))
    game:on_button("undo")
    check(game.moves == "e2e4", "undo should take back one move, moves: " .. game.moves)
    game:on_button("flip")
    check(game.flipped and game.screen.state.flipped, "flip should turn the board")
    check(game.screen.state.bottom.name == s.color_black, "after flipping, black is below")
    local saved = home.settings:readSetting("two_player_game")
    check(saved and saved.flipped == true and saved.moves == "e2e4", "the game and the way it faces should be saved")
    local engine_game = home.settings:readSetting("offline_game")
    check(engine_game and engine_game.level == 3 and engine_game.moves == "e2e4", "the game against the engine should be untouched")
    UIManager:close(game.screen)

    game = OfflineGame.open(home, { two_players = true, resume = true })
    check(game.flipped and game.moves == "e2e4", "resuming should keep the moves and the way it faces")
    UIManager:close(game.screen)

    -- A mate names the winner, and the finished game is no longer kept.
    game = OfflineGame.open(home, { two_players = true })
    play(game, "f2", "f3")
    play(game, "e7", "e5")
    play(game, "g2", "g4")
    play(game, "d8", "h4")
    check(game.ending == "mate" and game.screen.state.status == s.local_mate_b, "black should win by mate: " .. tostring(game.screen.state.status))
    check(buttons(game) == "back undo moves flip analyze again", "after mate: " .. buttons(game))
    check(home.settings:readSetting("two_player_game") == nil, "a finished game should not be kept")
    game.screen:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/two_players_mate.png")
    UIManager:close(game.screen)

    -- Resigning is for the side to move, and names the other one as the winner.
    game = OfflineGame.open(home, { two_players = true })
    play(game, "d2", "d4")
    game:on_button("resign")
    local question = home.pages[#home.pages]
    check(question and question.title == s.local_resign_question_b, "it should ask black, the side to move")
    for _, line in ipairs(question.lines) do
        if line.kind == "primary" then
            UIManager:close(question)
            line.callback()
        end
    end
    check(game.screen.state.status == s.local_resigned_b, "black resigned: " .. tostring(game.screen.state.status))
    check(not buttons(game):find("undo", 1, true), "no undo after resigning: " .. buttons(game))
    UIManager:close(game.screen)
    home.settings:delSetting("offline_game")
end

-- The move list: in an offline game it opens on the last move, and in a review a tap on a move goes to it.
do
    home.settings:delSetting("offline_game")
    local game = OfflineGame.open(home, { level = 1, color_choice = "white" })
    check(not buttons(game):find("moves", 1, true), "no list before the first move: " .. buttons(game))
    play(game, "e2", "e4")
    run_scheduled()
    check(buttons(game):find("moves", 1, true), "the list should be offered after a move: " .. buttons(game))
    game:on_button("moves")
    local page = home.pages[#home.pages]
    check(page and page.title == s.move_list_title, "the list should open")
    local opening = require("ink_knight/openings").name(nil, game.moves)
    check(opening ~= nil, "1. e4 and any answer have a name: " .. game.moves)
    check(page and page.lines[1].kind == "text" and page.lines[1].text == opening, "the name of the opening should come first")
    check(page and page.lines[2].white == "e4" and page.lines[2].black ~= nil, "the first row of moves should hold both moves")
    page:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/move_list_offline.png")
    UIManager:close(page)
    UIManager:close(game.screen)
    home.settings:delSetting("offline_game")
end

do
    local ReviewScreen = require("ink_knight/ui/review_screen")
    math.randomseed(3)
    local position = Chess.parse_fen(Chess.START_FEN)
    local moves = {}
    while #moves < 70 do
        local legal = Chess.legal_moves(position)
        if #legal == 0 then
            break
        end
        local move = legal[math.random(#legal)]
        moves[#moves + 1] = { uci = Chess.move_to_uci(move), san = Chess.to_san(position, move) }
        position = Chess.play(position, move)
        if Chess.ending(position) then
            break
        end
    end
    local review = ReviewScreen.open(home, { moves = moves, white = "A", black = "B" })
    review:go(40)
    review:show_moves()
    local page = home.pages[#home.pages]
    check(page and #page.sheets > 1, "a long game should take more than one sheet")
    local current_sheet
    for index, sheet in ipairs(page.sheets) do
        for _, line in ipairs(sheet) do
            if line.white_current or line.black_current then
                current_sheet = index
            end
        end
    end
    check(current_sheet and page.sheet == current_sheet, "the list should open on the sheet of the move shown")
    check(page.sheets[1][1].kind == "text" and page.sheets[1][1].text ~= "", "the review should name the opening too")
    page:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/move_list_review.png")
    local target
    for _, hit in ipairs(page.hits) do
        if hit.y > 100 and not target then
            target = hit
        end
    end
    page:press(target)
    check(review.index ~= 40, "a tap on a move should go to it, still at " .. review.index)
    check(home.pages[#home.pages] ~= page, "the list should close after the tap")
    UIManager:close(review.screen)

    -- A game the site analyzed: the start of the middlegame marked on its move, and the summary of both sides.
    local s = home.strings
    local analyzed = ReviewScreen.open(home, { moves = moves, white = "A", black = "B", summary = {
        white = { accuracy = 91, inaccuracy = 2, mistake = 1, blunder = 0, acpl = 25 },
        black = { inaccuracy = 4, mistake = 2, blunder = 1, acpl = 60 },
        middle = 18, ending = 61,
    } })
    analyzed:go(18)
    check(analyzed.screen.state.status:find(s.review_middlegame, 1, true), "the move where the middlegame begins says so: " .. analyzed.screen.state.status)
    analyzed:go(19)
    check(not analyzed.screen.state.status:find(s.review_middlegame, 1, true), "only on that move")
    analyzed:more_menu()
    local more = home.pages[#home.pages]
    check(more.lines[1].text == s.review_summary, "the summary comes first in More")
    UIManager:close(more)
    analyzed:show_summary()
    local summary_page = home.pages[#home.pages]
    local function row_with(text)
        for _, line in ipairs(summary_page.lines) do
            if line.text == text then
                return line
            end
        end
    end
    check(summary_page.lines[1].kind == "section" and summary_page.lines[2].kind == "metric" and summary_page.lines[2].value == "91%", "white's accuracy in large first")
    local figures = summary_page.lines[3]
    check(figures.kind == "figures" and #figures.items == 4 and figures.items[3].value == "0" and figures.items[3].label == s.review_blunders, "white's counts side by side")
    check(row_with(s.review_middlegame) and row_with(s.review_middlegame).value == string.format(s.review_move_value, "9...")
        and row_with(s.review_endgame).value == string.format(s.review_move_value, "31."), "the counts and the phases with their moves")
    summary_page:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/review_summary.png")
    -- A phase leads to its move.
    row_with(s.review_endgame).callback()
    check(analyzed.index == 61, "the endgame row should go to its move: " .. analyzed.index)
    UIManager:close(summary_page)
    -- The list of moves has a heading before the row where each phase begins.
    analyzed:show_moves()
    local list = home.pages[#home.pages]
    local heading_before
    for index, line in ipairs(list.lines) do
        if line.kind == "section" and line.text == s.review_middlegame then
            heading_before = list.lines[index + 1]
        end
    end
    check(heading_before and heading_before.number == "9." and heading_before.black == moves[18].san, "the middlegame heading should come before the row of 9...")
    UIManager:close(list)
    UIManager:close(analyzed.screen)
    -- A phase past the moves the review has is not named.
    local short = ReviewScreen.open(home, { moves = { moves[1], moves[2], moves[3] }, white = "A", black = "B", summary = {
        white = { inaccuracy = 0, mistake = 0, blunder = 0 }, black = { inaccuracy = 0, mistake = 0, blunder = 0 }, middle = 2, ending = 61,
    } })
    short:show_summary()
    local has_middle, has_end = false, false
    for _, line in ipairs(home.pages[#home.pages].lines) do
        has_middle = has_middle or line.text == s.review_middlegame
        has_end = has_end or line.text == s.review_endgame
    end
    check(has_middle and not has_end, "only the phases the review has")
    UIManager:close(home.pages[#home.pages])
    UIManager:close(short.screen)
end


-- Promoting: the piece is asked, or with "always promote to a queen" a queen goes at once.
do
    local fen = "8/P7/8/8/8/8/k6K/8 w - - 0 1"
    for _, auto in ipairs({ false, true }) do
        home.settings:saveSetting("auto_queen", auto)
        local game = OfflineGame.open(home, { two_players = true, initial_fen = fen })
        local pages_before = #home.pages
        game.screen.on_square(Chess.square_from_name("a7"))
        game.screen.on_square(Chess.square_from_name("a8"))
        if auto then
            check(#home.pages == pages_before and game.position.board[Chess.square_from_name("a8")] == "Q", "a queen at once with the option on")
        else
            check(#home.pages == pages_before + 1, "the piece should be asked with the option off")
            UIManager:close(home.pages[#home.pages])
        end
        UIManager:close(game.screen)
        home.settings:delSetting("two_player_game")
    end
    home.settings:delSetting("auto_queen")
end

home.settings:delSetting("offline_game")
UIManager:close(home)
if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("offline game: everything as expected")
os.exit(0)
