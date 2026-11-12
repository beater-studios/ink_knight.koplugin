-- A level of "Learn chess" on the board: the goal in a banner on top, the stars and the hints drawn on the squares,
-- and the score below. The opponent's scripted moves, and the move that shows why a move failed, come after a short
-- pause, so the reader sees their own move first.
local UIManager = require("ui/uimanager")

local BoardScreen = require("ink_knight/ui/board_screen")
local Learn = require("ink_knight/learn")
local Sleep = require("ink_knight/sleep")

local LearnScreen = {}
LearnScreen.__index = LearnScreen

local REPLY_DELAY = 0.8
local PRAISE = { "learnAwesome", "learnExcellent", "learnGreatJob", "learnNailedIt", "learnOutstanding", "learnPerfect",
    "learnRightOn", "learnWayToGo", "learnYesYesYes", "learnYoureGoodAtThis" }

function LearnScreen.stars_text(rank)
    if not rank then
        return ""
    end
    return string.rep("\226\152\133", 4 - rank) .. string.rep("\226\152\134", rank - 1)
end

-- stage: one of ink_knight/data/learn_stages.lua. opts.on_stage_done(stage): when its last level is done and the
-- reader goes on.
function LearnScreen.open(app, stage, level_index, opts)
    local self = setmetatable({ app = app, s = app.strings, t = app:learn_texts(), stage = stage, opts = opts or {} }, LearnScreen)
    self.reply_callback = function() self:reply() end
    self.screen = BoardScreen:new{
        state = {},
        banner_lines = 3,
        on_square = function(square) self:on_square(square) end,
        on_button = function(button) self:on_button(button) end,
        on_closed = function()
            self.is_closed = true
            if app.reload_pages then
                app:reload_pages()
            end
        end,
        broken_text = app.strings.unexpected_error,
    }
    UIManager:show(self.screen)
    self:start(level_index or 1, "full")
    return self
end

function LearnScreen:start(index, what)
    Sleep.unschedule(self.screen, self.reply_callback)
    self.index = index
    self.level = self.stage.levels[index]
    self.state = Learn.start(self.level)
    self.selected, self.targets, self.follow, self.praise = nil, nil, nil, nil
    if Learn.is_opponent_scenario_turn(self.state) then
        self.follow = "scenario"
        Sleep.schedule(self.screen, REPLY_DELAY, self.reply_callback)
    end
    self:render(what)
end

function LearnScreen:status_text()
    local state, t = self.state, self.t
    if state.completed then
        return self.praise .. "  " .. LearnScreen.stars_text(Learn.level_rank(self.level, state.score))
    elseif state.failed then
        return t.learnPuzzleFailed
    end
    return ""
end

function LearnScreen:buttons()
    local s, t, state = self.s, self.t, self.state
    local buttons = { { id = "back", label = s.back } }
    if state.failed or state.completed then
        buttons[#buttons + 1] = { id = "retry", label = t.learnRetry }
    end
    if state.completed then
        buttons[#buttons + 1] = { id = "next", label = t.learnNext }
    end
    return buttons
end

function LearnScreen:render(what)
    if self.is_closed then
        return
    end
    local state, level = self.state, self.level
    self.screen:show({
        banner = self.t[level.goal] or "",
        flipped = level.color == "b",
        position = Learn.display_position(state),
        last_move = state.last_move,
        selected = self.selected,
        targets = self.targets,
        stars = state.apples,
        shapes = state.shapes,
        check_square = state.check_square,
        highlighted_rank = level.highlighted_rank,
        bottom = { name = string.format(self.s.learn_level, self.index, #self.stage.levels), clock = tostring(state.score) },
        status = self:status_text(),
        buttons = self:buttons(),
    }, what)
end

-- The opponent's move after a pause: the next scripted one, the capture that failed the level, or a random one.
function LearnScreen:reply()
    local follow = self.follow
    self.follow = nil
    if self.is_closed or not follow then
        return
    end
    if follow == "scenario" then
        Learn.opponent_scenario_move(self.state)
    elseif follow == "capture" then
        Learn.opponent_capture(self.state)
    elseif follow == "random" then
        Learn.random_opponent_move(self.state)
    end
    self:render()
end

function LearnScreen:play(move)
    self.selected, self.targets = nil, nil
    local follow = Learn.player_move(self.state, move)
    if self.state.completed then
        self.praise = self.t[PRAISE[math.random(#PRAISE)]]
        self.app:learn_record(self.stage.key, self.index, self.state.score)
    end
    if follow ~= "none" then
        self.follow = follow
        Sleep.schedule(self.screen, REPLY_DELAY, self.reply_callback)
    end
    self:render()
end

function LearnScreen:on_square(square)
    local state = self.state
    if self.follow or not Learn.is_player_turn(state) then
        return
    end
    if self.targets and self.targets[square] then
        local moves = self.targets[square]
        if #moves == 1 then
            self:play(moves[1])
        else
            -- The first pawn level explains promotion when it comes, as the app does.
            if self.level.explain_promotion then
                local t = self.t
                self.app:info(table.concat({ t.learnYourPawnReachedTheEndOfTheBoard, t.learnItNowPromotesToAStrongerPiece, t.learnSelectThePieceYouWant }, " "), 6)
            end
            self.app:choose_promotion(moves, function(move) self:play(move) end)
        end
        return
    end
    local piece = state.position.board[square]
    if piece and not state.apples[square] and (piece == piece:upper()) == (self.level.color == "w") then
        self.selected = square
        self.targets = Learn.targets(state, square)
    else
        self.selected, self.targets = nil, nil
    end
    self:render()
end

function LearnScreen:on_button(button)
    if button == "back" then
        UIManager:close(self.screen)
    elseif button == "retry" then
        self:start(self.index)
    elseif button == "next" then
        if self.index < #self.stage.levels then
            self:start(self.index + 1)
        else
            UIManager:close(self.screen)
            if self.opts.on_stage_done then
                self.opts.on_stage_done(self.stage)
            end
        end
    end
end

return LearnScreen
