package.path = "./?.lua;" .. package.path
local Api = require("ink_knight/api")
local Practice = require("ink_knight/practice")
local StudyChapter = require("ink_knight/study_chapter")
local StudyStore = require("ink_knight/study_store")
local TokenScopes = require("ink_knight/token_scopes")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAILED: " .. name .. "\n  " .. tostring(err))
    end
end

local function eq(actual, expected, what)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
    end
end

-- A chapter of analysis, as /api/study/{id}.pgn sends it: comments, drawings, a variation with its own comments and
-- deeper variations, which the reader skips.
local LESSON = [[
[Event "Candidates: Round 1"]
[StudyName "Candidates 2026 | Annotations"]
[ChapterName "Round 1: Caruana - Nakamura"]
[Orientation "white"]

{ Annotated by a WGM https://lichess.org/@/someone } 1. e4 { [%clk 1:59:00] The fashionable start. [%cal Ge2e4,Rd7d5] } 1... e5 ( 1... c5 { The Sicilian. } 2. Nf3 ( 2. c3 d5 ) d6 ) 2. Nf3 { [%csl Ge5] [%anno "x", y] } 2... Nc6 *
]]

-- An interactive chapter: the reader plays black, a wrong move with its comment, and an alternative the opponent
-- has, which is no wrong move of the reader.
local GAMEBOOK = [[
[Event "Puzzle Pack: Kovalenko - Mwadzura"]
[StudyName "Olympiad Puzzle Pack"]
[ChapterName "Kovalenko, Igor - Mwadzura, Roy"]
[FEN "rn1r2k1/pb3ppp/1p2pn2/3p4/1PP5/q2N2P1/P2NPPBP/R2Q1RK1 b - - 0 14"]
[SetUp "1"]
[Orientation "black"]
[ChapterMode "gamebook"]

{ Welcome! What had Black missed? } 14... a5 { Now White traps the queen. } ( 14... Qxb4 { No, that loses the queen at once. } 15. Nxb4 { A comment on a later move. [%cal Gd3b4] } ) 15. Nb1 ( 15. c5 bxc5 ) 15... Qxb4 *
]]

test("a chapter of analysis: the main line with comments and drawings, the variations left out", function()
    local chapter, texts = StudyChapter.read(LESSON, "s_1")
    eq(chapter.kind, "lesson")
    eq(#chapter.line, 4, "only the main line")
    eq(chapter.line[1], "e2e4"); eq(chapter.line[4], "b8c6")
    eq(texts["s_1.d"], "Annotated by a WGM", "the opening comment, its address gone")
    eq(texts["s_1.c1"], "The fashionable start.", "the clock and drawing commands go")
    eq(StudyChapter.clean("Curated by FM Doğan (https://lichess.org/@/NaSil) and FM Selbes (https://lichess.org/@/x)."), "Curated by FM Doğan and FM Selbes.")
    eq(chapter.shapes[1], "Ge2e4,Rd7d5")
    eq(chapter.shapes[3], "Ge5")
    eq(texts["s_1.c3"], nil, "a comment of only commands says nothing")
    eq(texts["s_1.c2"], nil, "the comment of a variation is not the main line's")
    eq(texts["s_1.n"], "Round 1: Caruana - Nakamura")
    eq(next(chapter.wrong), nil, "a chapter of analysis has no wrong moves")
end)

test("an interactive chapter: the moves to find, the reader's wrong move with its comment, the introduction", function()
    local chapter, texts = StudyChapter.read(GAMEBOOK, "g_1")
    eq(chapter.kind, "guided")
    eq(chapter.color, "b")
    eq(#chapter.line, 3)
    eq(chapter.line[1], "a7a5")
    eq(chapter.wrong[1]["a3b4"], "", "the reader's other move at the first ply is wrong")
    eq(texts["g_1.w1.a3b4"], "No, that loses the queen at once.", "only what comes right after the wrong move")
    eq(chapter.wrong[1]["a3b4"], "", "the arrow of a later move is not drawn after the wrong one")
    eq(chapter.wrong[2], nil, "an alternative of the opponent is no wrong move")
    eq(texts["g_1.d"], "Welcome! What had Black missed?", "the first comment opens the chapter")
    eq(texts["g_1.c1"], "Now White traps the queen.")
    -- It plays in the guided chapters of the practice: the right move goes on, the wrong one is marked.
    local state = Practice.start_guided(chapter)
    assert(state.positions[#chapter.line], "every move of the line can be played")
end)

test("a chapter that cannot be read: a move that does not fit ends the line, a FEN that cannot be read gives nothing", function()
    local chapter = StudyChapter.read('[Event "x"]\n\n1. e4 e5 2. Qxf7 Nc6 *', "b_1")
    eq(#chapter.line, 2, "the line ends before the move that does not fit")
    eq(StudyChapter.read('[FEN "nonsense"]\n\n1. e4 *', "b_2"), nil)
    eq(#StudyChapter.read('[Event "x"]\n\n1. e4 } e5 2. Nf3 *', "b_3").line, 3, "a stray brace says nothing")
end)

test("study requests: the token only goes with study:read, which is optional and comes marked", function()
    eq(Api.study_list("Reader", true).anonymous, true)
    eq(Api.study_list("Reader", false).anonymous, false)
    eq(Api.study_list("Reader", true).path, "/api/study/by/Reader")
    eq(Api.study_pgn("Y1yXP80U").path, "/api/study/Y1yXP80U.pgn?clocks=false")
    assert(not pcall(Api.study_pgn, "../x"), "an id with a slash is refused")
    eq(TokenScopes.OPTIONAL.studies, true)
    assert(TokenScopes.create_url():find("scopes[]=study:read", 1, true), "the link for a token marks it")
    eq(TokenScopes.allows({ ["study:read"] = true }, "studies"), true)
    eq(TokenScopes.missing_count({}) == TokenScopes.missing_count({ ["study:read"] = true }), true, "missing it is not something missing")
end)

test("kept studies: the address or code, the file, its chapters, set aside and put back, deleted", function()
    eq(StudyStore.id_from("https://lichess.org/study/Y1yXP80U/abcdEFGH"), "Y1yXP80U")
    eq(StudyStore.id_from(" lichess.org/study/Y1yXP80U "), "Y1yXP80U")
    eq(StudyStore.id_from("Y1yXP80U"), "Y1yXP80U")
    eq(StudyStore.id_from("https://example.org/study/Y1yXP80U"), nil)
    eq(StudyStore.id_from("short"), nil)
    local files = {}
    local store = StudyStore.new{
        dir = "/studies",
        exists = function(path) return files[path] ~= nil end,
        remove = function(path) files[path] = nil end,
        rename = function(from, to) files[to], files[from] = files[from], nil end,
        make_dir = function() end,
        read = function(path) return files[path] end,
    }
    local study = { id = "Y1yXP80U", name = "Y1yXP80U", chapters = {} }
    local todo = store:files(study)
    eq(#todo, 1)
    eq(todo[1][1], "https://lichess.org/api/study/Y1yXP80U.pgn?clocks=false")
    eq(todo[1][2], "/studies/Y1yXP80U.pgn")
    files["/studies/Y1yXP80U.pgn"] = LESSON .. "\n\n" .. GAMEBOOK
    eq(#store:files(study), 0, "a kept study is not asked again")
    local chapters, name = store:chapters_of(study)
    eq(#chapters, 2)
    eq(name, "Candidates 2026 | Annotations")
    eq(chapters[2].guided, true)
    eq(#store:chapter_texts(study), 2)
    store:set_aside(study)
    eq(#store:files(study), 1, "set aside, it is asked for again")
    eq(store:is_kept(study), true, "and its chapters still open from the old copy meanwhile")
    eq(#store:chapter_texts(study), 2)
    store:settle(study)
    eq(store:is_kept(study), true, "a download that failed gives the old file back")
    files["/studies/Y1yXP80U.pgn.part"] = "half"
    store:delete(study)
    eq(files["/studies/Y1yXP80U.pgn"], nil); eq(files["/studies/Y1yXP80U.pgn.part"], nil)
    local index = StudyStore.read_index({ { id = "Y1yXP80U", name = "C", chapters = chapters }, { id = "bad/id" } })
    eq(#index, 1); eq(#index[1].chapters, 2)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
