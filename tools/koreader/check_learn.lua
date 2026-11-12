-- Goes through "Learn chess" on the real screens: the list of stages from the offline menu, the introduction of a
-- stage never played, a level done with its stars and score kept, a level failed with the capture that shows why,
-- a level that starts with the opponent's scripted move, and the end of a stage leading to the next one.
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=... tools/koreader/run_headless.sh tools/koreader/check_learn.lua
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

local failures = 0
local function check(condition, message)
    if not condition then
        failures = failures + 1
        print("FAILED: " .. message)
    end
end

local queue = {}
UIManager.scheduleIn = function(_, _, callback)
    queue[#queue + 1] = callback
end
local function run_queue()
    local pending = queue
    queue = {}
    for _, callback in ipairs(pending) do
        callback()
    end
end

G_reader_settings:saveSetting("language", "pt")
local home = Home:new{ version = "0" }
UIManager:show(home)
local t = home:learn_texts()
home.settings:delSetting("learn_progress")

local function row_of(page, text)
    for _, line in ipairs(page.lines) do
        if line.text == text then
            return line
        end
    end
end
local function board()
    for _, widget in ipairs(UIManager._window_stack or {}) do
        if widget.widget and widget.widget.on_square then
            return widget.widget
        end
    end
end
local function ids(state)
    local list = {}
    for _, button in ipairs(state.buttons or {}) do
        list[#list + 1] = button.id
    end
    return table.concat(list, " ")
end
local function play(screen, from, to)
    screen.on_square(Chess.square_from_name(from))
    screen.on_square(Chess.square_from_name(to))
end

-- The list of stages, in Portuguese, from the offline menu.
home:offline_menu()
local offline = home.pages[#home.pages]
local learn_row = row_of(offline, t.learnLearnChess)
check(learn_row and learn_row.detail == string.format(t.learnProgressX, "0%"), "the offline menu should offer Learn chess at 0%")
learn_row.callback()
local menu = home.pages[#home.pages]
check(row_of(menu, t.learnChessPieces) and row_of(menu, t.learnAdvanced), "the stages should be grouped as in the app")

-- A stage never played opens with its introduction.
row_of(menu, t.learnTheRook).callback()
local intro = home.pages[#home.pages]
check(intro.lines[1] and intro.lines[1].text == t.learnRookIntro, "the rook stage should start with its introduction")
intro.lines[2].callback()
UIManager:close(intro)
local screen = board()
check(screen and screen.state.banner == t.learnRookGoal, "the goal should be in the banner: " .. tostring(screen and screen.state.banner))
check(screen.state.stars[Chess.square_from_name("e7")], "the star should be drawn on e7")
check(#screen.state.shapes == 1, "the first level shows its hint arrow")
check(screen.state.position.board[Chess.square_from_name("e7")] == nil, "the pawn under the star is not drawn")
screen:paintTo(Screen.bb, 0, 0)
Screen.bb:writePNG(out_dir .. "/learn_rook_1.png")

-- Done in one move: praised, with three stars, and kept.
play(screen, "e2", "e7")
check(screen.state.status:find("\226\152\133\226\152\133\226\152\133", 1, true), "the level should give three stars: " .. tostring(screen.state.status))
check(ids(screen.state) == "back retry next", "after a level, retry or next: " .. ids(screen.state))
check((home:learn_progress().rook or {})[1] == 550, "the score should be kept: " .. tostring((home:learn_progress().rook or {})[1]))
check(home:learn_percent() == 3, "one level of the rook counts as on the site: " .. home:learn_percent())
screen.on_button("next")
check(screen.state.banner == t.learnGrabAllTheStars and screen.state.bottom.name == string.format(home.strings.learn_level, 2, 6), "next should open level 2")
screen:paintTo(Screen.bb, 0, 0)
Screen.bb:writePNG(out_dir .. "/learn_rook_2.png")
UIManager:close(screen)

-- A level failed: the queen takes the pawn and is left to the rook, which takes her after a pause.
local categories = require("ink_knight/data/learn_stages")
local LearnScreen = require("ink_knight/ui/learn_screen")
local view = LearnScreen.open(home, categories[2].stages[1], 2)
screen = view.screen
play(screen, "f4", "f7")
check(screen.state.status == t.learnPuzzleFailed, "taking the defended pawn should fail")
check(screen.state.position.board[Chess.square_from_name("f7")] == "Q", "the capture waits for a pause")
run_queue()
check(screen.state.position.board[Chess.square_from_name("f7")] == "r", "the rook should take the queen")
check(ids(screen.state) == "back retry", "after failing, retry: " .. ids(screen.state))
screen.on_button("retry")
check(screen.state.position.board[Chess.square_from_name("f4")] == "Q" and screen.state.status == "", "retry should start the level again")
UIManager:close(screen)

-- En passant: black's scripted move comes first, then the pawn takes it in passing.
view = LearnScreen.open(home, categories[3].stages[3], 1)
screen = view.screen
play(screen, "c5", "d6")
check(screen.state.position.board[Chess.square_from_name("d6")] == nil, "no move before black's scripted one")
run_queue()
check(screen.state.position.board[Chess.square_from_name("d5")] == "p", "black should play d7-d5")
play(screen, "c5", "d6")
check(screen.state.position.board[Chess.square_from_name("d5")] == nil and screen.state.status ~= "", "en passant should take the pawn and finish the level")
UIManager:close(screen)

-- The end of a stage: the king's last level done leads to the knight.
local king = categories[1].stages[4]
home:learn_record("king", 1, 500)
home:learn_record("king", 2, 700)
view = LearnScreen.open(home, king, 3, { on_stage_done = function(stage) home:learn_stage_done(stage) end })
screen = view.screen
for _, move in ipairs({ { "e5", "d6" }, { "d6", "c5" }, { "c5", "b5" }, { "b5", "c5" }, { "c5", "d4" }, { "d4", "e3" }, { "e3", "f3" }, { "f3", "g4" } }) do
    play(screen, move[1], move[2])
end
check(next(screen.state.stars) == nil and screen.state.status ~= "", "the route should take every star of the last king level")
check(ids(screen.state) == "back retry next", "the last level also offers next: " .. ids(screen.state))
screen.on_button("next")
local done = home.pages[#home.pages]
check(done.lines[1].text:find(t.learnKingComplete, 1, true), "the end of the stage should say what it taught")
check(row_of(done, string.format(t.learnNextX, t.learnTheKnight)), "the end of the stage should lead to the knight")
UIManager:close(done)
check(row_of(menu, t.learnTheKing).value ~= nil, "the list should show the king stage done")

UIManager:close(menu)
UIManager:close(offline)
home.settings:delSetting("learn_progress")
G_reader_settings:saveSetting("language", "en")
if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("learn: everything as expected")
os.exit(0)
