-- Goes through the practice lessons on the real screens, in Portuguese: the entry of the offline menu, the sections
-- and studies, the chapters of a study, a mate in one given and kept, the same chapter failed and tried again, the
-- engine answering a move and giving a hint, a guided chapter with a wrong move taken back by itself and the
-- opponent's moves coming by themselves, the whole text a tap away, the commented game from comment to comment, and
-- the end of a study leading to the next one.
-- Usage: OUTPUT_DIR=<folder> KOREADER_DIR=... tools/koreader/run_headless.sh tools/koreader/check_practice.lua
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
local Practice = require("ink_knight/practice")
local PracticeScreen = require("ink_knight/ui/practice_screen")
local sections = require("ink_knight/data/practice")

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
local function run_queue(limit)
    for _ = 1, limit or 100000 do
        if #queue == 0 then
            return
        end
        local pending = queue
        queue = {}
        for _, callback in ipairs(pending) do
            callback()
        end
    end
end

G_reader_settings:saveSetting("language", "pt")
local home = Home:new{ version = "0" }
UIManager:show(home)
local s, t, texts = home.strings, home:learn_texts(), home:practice_texts()
home.settings:delSetting("practice_progress")

local function row_of(page, text)
    for _, line in ipairs(page.lines) do
        if line.text == text then
            return line
        end
    end
end
local function ids(screen)
    local list = {}
    for _, button in ipairs(screen.state.buttons or {}) do
        list[#list + 1] = button.id
    end
    return table.concat(list, " ")
end
local function shot(screen, name)
    screen:paintTo(Screen.bb, 0, 0)
    Screen.bb:writePNG(out_dir .. "/" .. name .. ".png")
end
local function play(practice, from, to)
    practice.screen.on_square(Chess.square_from_name(from))
    practice.screen.on_square(Chess.square_from_name(to))
end

-- The entry of the offline menu, then the sections and studies.
home:offline_menu()
local offline = home.pages[#home.pages]
local entry = row_of(offline, t.practice)
check(entry and entry.detail == string.format(t.learnProgressX, "0%"), "the offline menu should offer the practice at 0%")
entry.callback()
local menu = home.pages[#home.pages]
local first_study = sections[1].studies[1]
check(row_of(menu, t.practiceSecHeadCheckmates) and row_of(menu, t.practiceSecHeadRookEndgames), "the sections should be the app's")
local study_row = row_of(menu, t[first_study.name])
check(study_row and study_row.value == "0/" .. #first_study.chapters and study_row.detail == t[first_study.subtitle], "a study should show its chapters done")
study_row.callback()
local chapters = home.pages[#home.pages]
check(#chapters.lines == #first_study.chapters and chapters.lines[1].bold, "the chapters of the study, the first to play marked")
menu:paintTo(Screen.bb, 0, 0)
Screen.bb:writePNG(out_dir .. "/practice_menu.png")

-- A mate in one, found in the data: given, it solves the chapter and is kept.
local mate_study, mate_index, mate_move
for _, section in ipairs(sections) do
    for _, study in ipairs(section.studies) do
        for index, chapter in ipairs(study.chapters) do
            if not mate_study and chapter.goal == "mate_in" and chapter.moves == 1 then
                local position = Chess.parse_fen(chapter.fen)
                for _, candidate in ipairs(Chess.legal_moves(position)) do
                    if Chess.ending(Chess.play(position, candidate)) == "mate" then
                        mate_study, mate_index, mate_move = study, index, candidate
                    end
                end
            end
        end
    end
end
local practice = PracticeScreen.open(home, mate_study, mate_index)
local chapter = practice.chapter
check(practice.screen.state.banner == (texts[chapter.id .. ".d"] or string.format(s.practice_goal_mate_in, 1)), "the banner should say what the chapter is about")
check(practice.screen.state.status == string.format(s.practice_moves_of, string.format(s.practice_goal_mate_in, 1), 1, 1), "the status should count the moves: " .. tostring(practice.screen.state.status))
shot(practice.screen, "practice_goal")
play(practice, Chess.square_name(mate_move.from), Chess.square_name(mate_move.to))
check(practice.state.status == "solved" and practice.screen.state.status == string.format(s.practice_solved, 1), "the mate should solve it: " .. tostring(practice.screen.state.status))
check(home:practice_progress()[chapter.id] == 1, "the chapter should be kept as done in one move")
check(ids(practice.screen):find("retry", 1, true) and ids(practice.screen):find("next", 1, true), "done: retry and next: " .. ids(practice.screen))

-- Tried again and failed: another move, and the mate in one is gone.
practice.screen.on_button("retry")
check(practice.state.status == "playing" and practice.state.played == 0, "retry should start over")
local position = practice.state.position
for _, candidate in ipairs(Chess.legal_moves(position)) do
    if practice.state.status == "playing" and Chess.ending(Chess.play(position, candidate)) == nil then
        practice:play_goal(candidate)
    end
end
check(practice.state.status == "failed" and practice.screen.state.status == string.format(s.practice_failed_slow, 1), "a move without mate should fail: " .. tostring(practice.screen.state.status))
UIManager:close(practice.screen)
run_queue()

-- Against the engine: a hint, then a move, and the engine's answer.
local mate_chapter_study = sections[1].studies[1]
practice = PracticeScreen.open(home, mate_chapter_study, 1)
check(practice.chapter.goal == "mate" and practice.screen.state.status == s.practice_goal_mate, "the first chapter is a mate: " .. tostring(practice.screen.state.status))
practice.screen.on_button("hint")
check(practice.screen.state.status == s.hint_thinking, "the hint should be looked for")
run_queue()
check(practice.hint_move ~= nil and practice.screen.state.status:find(s.hint_status:gsub("%%s", ""), 1, true), "the hint should name a move: " .. tostring(practice.screen.state.status))
local legal = Chess.legal_moves(practice.state.position)
practice:play_goal(practice.hint_move or legal[1])
check(practice.thinking and practice.screen.state.status == s.status_thinking, "the engine should think after the move")
run_queue()
check(not practice.thinking and Practice.is_player_turn(practice.state) and practice.state.played == 1, "the engine should answer, and the reader move again")
UIManager:close(practice.screen)
run_queue()

-- A guided chapter: the knight and bishop mate, the first triangle.
local kbn_study
for _, section in ipairs(sections) do
    for _, study in ipairs(section.studies) do
        if study.id == "ByhlXnmM" then
            kbn_study = study
        end
    end
end
local _, _, guided_index = Practice.find(sections, "5OqFMeoY")
practice = PracticeScreen.open(home, kbn_study, guided_index)
local guided = practice.chapter
check(practice.screen.state.banner == texts["5OqFMeoY.c0"], "the guided chapter opens with its first comment")
check(#practice.screen.state.shapes > 0, "with the author's drawing")
shot(practice.screen, "practice_guided")
-- A wrong move with nothing to say about it is taken back by itself.
play(practice, "e1", "d1")
check(Practice.feedback(practice.state, guided) == "bad" and practice.screen.state.status == s.practice_wrong_status, "a wrong move should be marked")
run_queue()
check(Practice.feedback(practice.state, guided) == "play" and practice.state.ply == 0, "and taken back by itself")
-- The right one: the opponent answers by itself, and the next comment shows.
play(practice, "e1", "e2")
check(practice.state.ply == 1 and practice.screen.state.status == s.practice_good_move, "the right move should be good: " .. tostring(practice.screen.state.status))
run_queue()
check(practice.state.ply == 2 and practice.screen.state.banner == texts["5OqFMeoY.c2"], "the opponent should answer, with its comment")
practice.screen.on_button("solution")
check(practice.screen.state.status == string.format(s.practice_solution_status, "Ke3"), "the solution should name the move: " .. tostring(practice.screen.state.status))
UIManager:close(practice.screen)
run_queue()
-- A long text can be read whole.
local long_study, long_index, long_length
for _, section in ipairs(sections) do
    for _, study in ipairs(section.studies) do
        for index, item in ipairs(study.chapters) do
            local length = #(texts[item.id .. ".d"] or "")
            if item.kind == "goal" and length > (long_length or 0) then
                long_study, long_index, long_length = study, index, length
            end
        end
    end
end
practice = PracticeScreen.open(home, long_study, long_index)
check(not practice.screen:banner_fits(practice.screen.state.banner), "the longest description should not fit the banner: " .. long_length .. " bytes, screen " .. Screen:getWidth() .. "x" .. Screen:getHeight())
check(ids(practice.screen):find("read", 1, true), "a long text offers to read it: " .. ids(practice.screen))
local pages = #home.pages
practice.screen.on_button("read")
check(#home.pages == pages + 1 and home.pages[#home.pages].lines[1].text:find(practice.screen.state.banner, 1, true), "read should show the whole comment")
UIManager:close(home.pages[#home.pages])
UIManager:close(practice.screen)
run_queue()

-- A guided chapter with a description opens with it, and the opponent waits for it to be read.
local _, intro_study, intro_index = Practice.find(sections, "D23EYigW")
pages = #home.pages
practice = PracticeScreen.open(home, intro_study, intro_index)
check(#home.pages == pages + 1 and home.pages[#home.pages].lines[1].text:find(texts["D23EYigW.d"], 1, true), "the description should open first")
UIManager:close(home.pages[#home.pages])
check(ids(practice.screen):find("read", 1, true), "the description can be read again: " .. ids(practice.screen))
practice.screen.on_button("retry")
check(#home.pages == pages, "trying again does not show it again")
UIManager:close(practice.screen)
run_queue()

-- A wrong move with the comment for any wrong move waits for Continue, and then is taken back.
local _, dev_study, dev_index = Practice.find(sections, "mXNCYwCt")
practice = PracticeScreen.open(home, dev_study, dev_index)
local dev = practice.chapter
local wrong_move
for _, candidate in ipairs(Chess.legal_moves(practice.state.positions[0])) do
    local uci = Chess.move_to_uci(candidate)
    if not wrong_move and uci ~= dev.line[1] and not (dev.wrong and dev.wrong[1] and dev.wrong[1][uci]) then
        wrong_move = candidate
    end
end
practice:play_guided(wrong_move)
check(practice.screen.state.banner == texts["mXNCYwCt.v1"], "the comment for a wrong move should show: " .. tostring(practice.screen.state.banner))
check(ids(practice.screen):find("continue", 1, true), "and wait for Continue: " .. ids(practice.screen))
practice.screen.on_button("continue")
check(Practice.feedback(practice.state, dev) == "play", "Continue takes the wrong move back")
UIManager:close(practice.screen)
run_queue()

-- The commented game: from comment to comment, done at the end.
local _, _, lesson_index = Practice.find(sections, "Z9gmSew0")
practice = PracticeScreen.open(home, kbn_study, lesson_index)
practice.screen.on_button("comment")
check(practice.state.ply == 143 and practice.screen.state.status == "72. Nxc3", "to the first comment: " .. tostring(practice.screen.state.status))
check(practice.screen.state.banner == texts["Z9gmSew0.c143"], "with the comment")
shot(practice.screen, "practice_lesson")
practice.screen.on_button("comment")
check(practice.state.ply == #practice.chapter.line and home:practice_progress()["Z9gmSew0"], "to the end, which counts it done")
UIManager:close(practice.screen)

-- The end of a study leads to the next one.
practice = PracticeScreen.open(home, first_study, #first_study.chapters, { on_study_done = function(done) home:practice_study_done(done) end })
practice.screen.on_button("next")
local done_page = home.pages[#home.pages]
check(row_of(done_page, string.format(t.learnNextX, t[sections[1].studies[2].name])), "the end of a study should offer the next one")
UIManager:close(done_page)
run_queue()

-- The chapter solved at the start is marked done in its study.
home:practice_study(mate_study)
local solved_row = row_of(home.pages[#home.pages], texts[chapter.id .. ".n"])
check(solved_row and solved_row.value == "\226\156\147", "a chapter done should be checked: " .. tostring(solved_row and solved_row.value))
UIManager:close(home.pages[#home.pages])

home.settings:delSetting("practice_progress")
if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("practice: everything as expected")
os.exit(0)
