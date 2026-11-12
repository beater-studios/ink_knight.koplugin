-- The lessons of "Learn chess", ported from the official Lichess app (lichess-org/mobile, GPL-3.0,
-- lib/src/model/learn), itself a port of the lessons of lichess.org: stars to collect, scripted moves of the
-- opponent, captures that fail a level, and the same scores and stars as the site. A level is played in place on its
-- state table; what should happen next is returned for the screen to schedule. No KOReader here.
local Chess = require("ink_knight/chess")

local Learn = {}

Learn.APPLE_SCORE, Learn.CAPTURE_SCORE, Learn.SCENARIO_SCORE = 50, 50, 50
local LEVEL_BONUS = { 500, 300, 100 }
local PIECE_VALUE = { q = 90, r = 50, b = 30, n = 30, p = 10, k = 0 }

-- Conditions of success or failure, looking at what the player's move left: { position, nb_moves, castled,
-- scenario_complete, scenario_failed }, with the opponent to move.
local A = {}
Learn.A = A

local function squares(list)
    local set = {}
    for name in tostring(list):gmatch("%S+") do
        set[Chess.square_from_name(name)] = true
    end
    return set
end

function A.piece_on(piece, square)
    local at = Chess.square_from_name(square)
    return function(data) return data.position.board[at] == piece end
end

function A.piece_not_on(piece, square)
    return A.no(A.piece_on(piece, square))
end

-- True when a piece stands outside the squares.
function A.no_piece_on(list)
    local allowed = squares(list)
    return function(data)
        for square in pairs(data.position.board) do
            if not allowed[square] then
                return true
            end
        end
        return false
    end
end

function A.white_pawn_on_any_of(list)
    local set = squares(list)
    return function(data)
        for square in pairs(set) do
            if data.position.board[square] == "P" then
                return true
            end
        end
        return false
    end
end

-- True when color ("w" or "b") has no piece left.
function A.extinct(color)
    return function(data)
        for _, piece in pairs(data.position.board) do
            if (piece == piece:upper()) == (color == "w") then
                return false
            end
        end
        return true
    end
end

function A.castled(side)
    return function(data) return data.castled == side end
end

function A.check_in(moves)
    return function(data) return data.nb_moves <= moves and Chess.in_check(data.position) end
end

function A.no_check_in(moves)
    return function(data) return data.nb_moves >= moves and not Chess.in_check(data.position) end
end

A.check = function(data) return Chess.in_check(data.position) end
A.mate = function(data) return Chess.ending(data.position) == "mate" end
A.scenario_complete = function(data) return data.scenario_complete end
A.scenario_failed = function(data) return data.scenario_failed end

function A.every(list)
    return function(data)
        for _, condition in ipairs(list) do
            if not condition(data) then
                return false
            end
        end
        return true
    end
end

function A.any(list)
    return function(data)
        for _, condition in ipairs(list) do
            if condition(data) then
                return true
            end
        end
        return false
    end
end

function A.no(condition)
    return function(data) return not condition(data) end
end

-- Hints drawn on the board: an arrow for "e2e4", a circle for "e4", with a color name as the app has them.
function Learn.arrow(uci, brush)
    return { from = Chess.square_from_name(uci:sub(1, 2)), to = Chess.square_from_name(uci:sub(3, 4)), brush = brush or "pale_green" }
end

function Learn.circle(square, brush)
    return { from = Chess.square_from_name(square), brush = brush or "green" }
end

function Learn.step(uci, shapes)
    return { uci = uci, shapes = shapes or {} }
end

-- A level from the same fields as the app: goal (the key of its text), fen, nb_moves, and optionally apples, color,
-- detect_capture, empty_apples, shapes, scenario, success, failure, captures, explain_promotion, next_button,
-- offer_illegal, points_for_capture, show_piece_values, show_failure_follow_up and highlighted_rank.
function Learn.level(fields)
    local level = {}
    for key, value in pairs(fields) do
        level[key] = value
    end
    level.position = assert(Chess.parse_fen(fields.fen), "learn: bad FEN " .. tostring(fields.fen))
    level.color = fields.color or level.position.turn
    level.apples = squares(fields.apples or "")
    level.apple_count = 0
    for _ in pairs(level.apples) do
        level.apple_count = level.apple_count + 1
    end
    level.detect_capture = fields.detect_capture or (level.apple_count == 0 and "unprotected" or "none")
    level.shapes = fields.shapes or {}
    level.scenario = fields.scenario or {}
    level.captures = fields.captures or 0
    return level
end

local copy, king_square = Chess.copy_position, Chess.king_square

local function other(color)
    return color == "w" and "b" or "w"
end

local function check_square(position)
    return Chess.in_check(position) and king_square(position, position.turn) or nil
end

-- The state of a level about to be played. Unless the level says otherwise, an enemy pawn stands under each star,
-- so taking the star is a capture.
function Learn.start(level)
    local position = copy(level.position)
    if not level.empty_apples then
        local pawn = level.position.turn == "w" and "p" or "P"
        for square in pairs(level.apples) do
            position.board[square] = pawn
        end
    end
    local apples = {}
    for square in pairs(level.apples) do
        apples[square] = true
    end
    return {
        level = level, position = position, apples = apples, score = 0, nb_moves = 0, scenario_index = 1,
        scenario_failed = false, failed = false, completed = false, shapes = level.shapes,
        check_square = check_square(position),
    }
end

-- The board to draw: without the pawns under the stars.
function Learn.display_position(state)
    if state.level.empty_apples then
        return state.position
    end
    local position = copy(state.position)
    for square in pairs(state.apples) do
        position.board[square] = nil
    end
    return position
end

function Learn.is_over(state)
    return state.failed or state.completed
end

function Learn.is_player_turn(state)
    return not Learn.is_over(state) and state.position.turn == state.level.color
end

function Learn.is_opponent_scenario_turn(state)
    return not Learn.is_over(state) and state.position.turn ~= state.level.color and state.scenario_index <= #state.level.scenario
end

-- Where the piece on a square can go, as Chess.targets_from does, with the moves into check too when the level
-- lets the player blunder.
function Learn.targets(state, from)
    if not Learn.is_player_turn(state) then
        return {}
    end
    local moves = state.level.offer_illegal and Chess.pseudo_legal_moves(state.position) or nil
    return Chess.targets_from(state.position, from, moves)
end

local function captured_piece(position, move)
    local piece = position.board[move.from]
    if piece:lower() == "p" and move.to == position.passant then
        return position.turn == "w" and "p" or "P"
    end
    local target = position.board[move.to]
    if target and (target == target:upper()) ~= (piece == piece:upper()) then
        return target
    end
    return nil
end

local function castling_side(position, move)
    local piece = position.board[move.from]
    if piece:lower() ~= "k" then
        return nil
    end
    local distance = (move.to - 1) % 8 - (move.from - 1) % 8
    if distance == 2 then
        return "king"
    elseif distance == -2 then
        return "queen"
    end
    return nil
end

local function captures(position)
    local list = {}
    for _, move in ipairs(Chess.legal_moves(position)) do
        if captured_piece(position, move) then
            list[#list + 1] = move
        end
    end
    return list
end

-- A capture after which the other side cannot take back on the same square.
local function unprotected_capture(position)
    for _, capture in ipairs(captures(position)) do
        local taken_back = false
        for _, reply in ipairs(captures(Chess.play(position, capture))) do
            taken_back = taken_back or reply.to == capture.to
        end
        if not taken_back then
            return capture
        end
    end
    return nil
end

-- Arrows from the pieces of color that attack the king on square.
local function attack_arrows(position, color, square, brush)
    local arrows = {}
    for _, move in ipairs(Chess.pseudo_legal_moves(copy(position, color))) do
        if move.to == square then
            arrows[#arrows + 1] = { from = move.from, to = move.to, brush = brush }
        end
    end
    return arrows
end

local function level_bonus(level, nb_moves)
    local late = nb_moves - level.nb_moves
    if late <= 0 then
        return LEVEL_BONUS[1]
    elseif late <= math.max(1, level.nb_moves / 8) then
        return LEVEL_BONUS[2]
    end
    return LEVEL_BONUS[3]
end

-- Plays the player's move, as the app does: returns "none", "scenario" (the opponent's scripted move comes next),
-- "random" (a random opponent move shows why the move failed) or "capture" (the capture that failed it).
function Learn.player_move(state, move)
    local level, position = state.level, state.position
    local player = level.color
    local captured = captured_piece(position, move)
    local castled = castling_side(position, move)
    local after = Chess.play(position, move)
    state.nb_moves = state.nb_moves + 1
    state.last_move = move
    state.threat_move = nil
    if Chess.in_check(after, player == "w") then
        local king = king_square(after, player)
        state.position, state.failed, state.check_square = after, true, king
        state.shapes = attack_arrows(after, other(player), king, "red")
        return "none"
    end
    local took = false
    if state.apples[move.to] then
        state.score = state.score + Learn.APPLE_SCORE
        state.apples[move.to] = nil
        took = true
    end
    if not took and captured and level.points_for_capture and captured:lower() ~= "k" then
        state.score = state.score + (level.show_piece_values and PIECE_VALUE[captured:lower()] or Learn.CAPTURE_SCORE)
    end
    local shapes = state.shapes
    state.check_square = nil
    if Chess.in_check(after) then
        state.check_square = king_square(after, after.turn)
        shapes = attack_arrows(after, player, state.check_square, "yellow")
    end
    local step = level.scenario[state.scenario_index]
    local in_scenario = false
    local capture
    if step and step.uci == Chess.move_to_uci(move) then
        state.scenario_index = state.scenario_index + 1
        shapes = step.shapes
        state.score = state.score + Learn.SCENARIO_SCORE
        in_scenario = true
    else
        if step then
            state.scenario_failed = true
        end
        if level.detect_capture == "unprotected" then
            capture = unprotected_capture(after)
        elseif level.detect_capture == "any" then
            capture = captures(after)[1]
        end
    end
    -- What the conditions look at; the failure one only when the move left the scenario.
    local data = {
        position = after, nb_moves = state.nb_moves, castled = castled,
        scenario_complete = state.scenario_index > #level.scenario, scenario_failed = state.scenario_failed,
    }
    if not in_scenario then
        state.failed = capture ~= nil or (level.failure ~= nil and level.failure(data))
    end
    if level.apple_count > 0 then
        shapes = {}
    end
    state.position, state.shapes, state.threat_move = after, shapes, capture
    if not state.failed then
        local succeeded
        if level.success then
            succeeded = level.success(data)
        else
            succeeded = next(state.apples) == nil
        end
        if succeeded then
            state.completed = true
            state.score = state.score + level_bonus(level, state.nb_moves)
            return "none"
        end
    end
    if state.failed then
        if capture then
            return "capture"
        end
        return level.show_failure_follow_up and "random" or "none"
    end
    if not in_scenario then
        -- The opponent does not move in these levels: the turn comes back to the player.
        state.position = copy(after, player)
        return "none"
    end
    return Learn.is_opponent_scenario_turn(state) and "scenario" or "none"
end

function Learn.opponent_scenario_move(state)
    if not Learn.is_opponent_scenario_turn(state) then
        return
    end
    local step = state.level.scenario[state.scenario_index]
    local move = Chess.parse_uci(state.position, step.uci)
    local mover = state.position.turn
    local after = Chess.play(state.position, move)
    state.last_move = move
    if Chess.in_check(after, mover == "w") then
        state.position, state.scenario_failed = after, true
        return
    end
    state.position = after
    state.scenario_index = state.scenario_index + 1
    state.shapes = step.shapes
    state.check_square = check_square(after)
end

function Learn.random_opponent_move(state, random)
    local moves = Chess.legal_moves(state.position)
    if #moves == 0 then
        return
    end
    local move = moves[(random or math.random)(1, #moves)]
    state.position = Chess.play(state.position, move)
    state.last_move, state.shapes = move, {}
    state.check_square = check_square(state.position)
end

function Learn.opponent_capture(state)
    local move = state.threat_move
    if not move then
        return
    end
    state.position = Chess.play(state.position, move)
    state.last_move, state.threat_move, state.shapes = move, nil, {}
    state.check_square = check_square(state.position)
end

local function level_max(level)
    return level.apple_count * Learn.APPLE_SCORE + (level.points_for_capture and level.captures * Learn.CAPTURE_SCORE or 0) + LEVEL_BONUS[1]
end

-- From 1 (three stars) to 3 (one star), as on the site.
function Learn.level_rank(level, score)
    local max = level_max(level)
    if score >= max then
        return 1
    elseif score >= max - 200 then
        return 2
    end
    return 3
end

-- scores: the best score of each level, nil for one not done. nil while a level is missing.
function Learn.stage_rank(stage, scores)
    local max, total = 0, 0
    for index, level in ipairs(stage.levels) do
        if not scores[index] then
            return nil
        end
        max = max + level_max(level)
        total = total + scores[index]
    end
    if total >= max then
        return 1
    elseif total >= max - math.max(200, #stage.levels * 150) then
        return 2
    end
    return 3
end

-- The progress of all the stages, from 0 to 100, as on the site: each stage started counts 10, 8 or 5 points by its
-- stars, its levels not done scoring nothing.
function Learn.percent(categories, progress)
    local total, count = 0, 0
    for _, category in ipairs(categories) do
        for _, stage in ipairs(category.stages) do
            count = count + 1
            local scores = progress[stage.key] or {}
            if next(scores) ~= nil then
                local filled = {}
                for index in ipairs(stage.levels) do
                    filled[index] = scores[index] or 0
                end
                local rank = Learn.stage_rank(stage, filled)
                total = total + (rank == 1 and 10 or rank == 2 and 8 or 5)
            end
        end
    end
    return math.floor(total / math.max(1, count * 10) * 100 + 0.5)
end

return Learn
