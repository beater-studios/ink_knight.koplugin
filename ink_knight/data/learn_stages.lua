-- The stages of "Learn chess", ported by hand from the official Lichess app (lichess-org/mobile, GPL-3.0,
-- lib/src/model/learn/learn_stages.dart, commit a476f69), in the same order and with the same levels, so the scores
-- match the site. The texts are keys of ink_knight/data/learn_texts.lua.
local Learn = require("ink_knight/learn")

local A, level, arrow, circle, step = Learn.A, Learn.level, Learn.arrow, Learn.circle, Learn.step

-- Chess pieces

local rook = {
    key = "rook", title = "learnTheRook", subtitle = "learnItMovesInStraightLines", piece = "R",
    intro = "learnRookIntro", complete = "learnRookComplete",
    levels = {
        level{ goal = "learnRookGoal", fen = "8/8/8/8/8/8/4R3/8 w - -", apples = "e7", nb_moves = 1, shapes = { arrow("e2e7") } },
        level{ goal = "learnGrabAllTheStars", fen = "8/2R5/8/8/8/8/8/8 w - -", apples = "c5 g5", nb_moves = 2, shapes = { arrow("c7c5"), arrow("c5g5") } },
        level{ goal = "learnTheFewerMoves", fen = "8/8/8/8/3R4/8/8/8 w - -", apples = "a4 g3 g4", nb_moves = 3 },
        level{ goal = "learnTheFewerMoves", fen = "7R/8/8/8/8/8/8/8 w - -", apples = "f8 g1 g7 g8 h7", nb_moves = 5 },
        level{ goal = "learnUseTwoRooks", fen = "8/1R6/8/8/3R4/8/8/8 w - -", apples = "a4 g3 g7 h4", nb_moves = 4 },
        level{ goal = "learnUseTwoRooks", fen = "8/8/8/8/8/5R2/8/R7 w - -", apples = "b7 d1 d5 f2 f7 g4 g7", nb_moves = 7 },
    },
}

local bishop = {
    key = "bishop", title = "learnTheBishop", subtitle = "learnItMovesDiagonally", piece = "B",
    intro = "learnBishopIntro", complete = "learnBishopComplete",
    levels = {
        level{ goal = "learnGrabAllTheStars", fen = "8/8/8/8/8/5B2/8/8 w - -", apples = "d5 g8", nb_moves = 2, shapes = { arrow("f3d5"), arrow("d5g8") } },
        level{ goal = "learnTheFewerMoves", fen = "8/8/8/8/8/1B6/8/8 w - -", apples = "a2 b1 b5 d1 d3 e2", nb_moves = 6 },
        level{ goal = "learnGrabAllTheStars", fen = "8/8/8/8/3B4/8/8/8 w - -", apples = "a1 b6 c1 e3 g7 h6", nb_moves = 6 },
        level{ goal = "learnGrabAllTheStars", fen = "8/8/8/8/2B5/8/8/8 w - -", apples = "a4 b1 b3 c2 d3 e2", nb_moves = 6 },
        level{ goal = "learnYouNeedBothBishops", fen = "8/8/8/8/8/8/8/2B2B2 w - -", apples = "d3 d4 d5 e3 e4 e5", nb_moves = 6 },
        level{ goal = "learnYouNeedBothBishops", fen = "8/3B4/8/8/8/2B5/8/8 w - -", apples = "a3 c2 e7 f5 f6 g8 h4 h7", nb_moves = 11 },
    },
}

local queen = {
    key = "queen", title = "learnTheQueen", subtitle = "learnQueenCombinesRookAndBishop", piece = "Q",
    intro = "learnQueenIntro", complete = "learnQueenComplete",
    levels = {
        level{ goal = "learnGrabAllTheStars", fen = "8/8/8/8/8/8/4Q3/8 w - -", apples = "e5 b8", nb_moves = 2, shapes = { arrow("e2e5"), arrow("e5b8") } },
        level{ goal = "learnGrabAllTheStars", fen = "8/8/8/8/3Q4/8/8/8 w - -", apples = "a3 f2 f8 h3", nb_moves = 4 },
        level{ goal = "learnGrabAllTheStars", fen = "8/8/8/8/2Q5/8/8/8 w - -", apples = "a3 d6 f1 f8 g3 h6", nb_moves = 6 },
        level{ goal = "learnGrabAllTheStars", fen = "8/6Q1/8/8/8/8/8/8 w - -", apples = "a2 b5 d3 g1 g8 h2 h5", nb_moves = 7 },
        level{ goal = "learnGrabAllTheStars", fen = "8/8/8/8/8/8/8/4Q3 w - -", apples = "a6 d1 f2 f6 g6 g8 h1 h4", nb_moves = 9 },
    },
}

local king = {
    key = "king", title = "learnTheKing", subtitle = "learnTheMostImportantPiece", piece = "K",
    intro = "learnKingIntro", complete = "learnKingComplete",
    levels = {
        level{ goal = "learnTheKingIsSlow", fen = "8/8/8/8/8/3K4/8/8 w - -", apples = "e6", nb_moves = 3, empty_apples = true,
            shapes = { arrow("d3d4"), arrow("d4d5"), arrow("d5e6") } },
        level{ goal = "learnGrabAllTheStars", fen = "8/8/8/8/8/8/8/4K3 w - -", apples = "c2 d3 e2 e3", nb_moves = 4, empty_apples = true },
        level{ goal = "learnLastOne", fen = "8/8/8/4K3/8/8/8/8 w - -", apples = "b5 c5 d6 e3 f3 g4", nb_moves = 8, empty_apples = true },
    },
}

local knight = {
    key = "knight", title = "learnTheKnight", subtitle = "learnItMovesInAnLShape", piece = "N",
    intro = "learnKnightIntro", complete = "learnKnightComplete",
    levels = {
        level{ goal = "learnKnightsHaveAFancyWay", fen = "8/8/8/8/4N3/8/8/8 w - -", apples = "c5 d7", nb_moves = 2, shapes = { arrow("e4c5"), arrow("c5d7") } },
        level{ goal = "learnGrabAllTheStars", fen = "8/8/8/8/8/8/8/1N6 w - -", apples = "c3 d4 e2 f3 f7 g5 h8", nb_moves = 8 },
        level{ goal = "learnGrabAllTheStars", fen = "8/2N5/8/8/8/8/8/8 w - -", apples = "b6 d5 d7 e6 f4", nb_moves = 5 },
        level{ goal = "learnKnightsCanJumpOverObstacles", fen = "8/8/8/8/5N2/8/8/8 w - -", apples = "e3 e4 e5 f3 f5 g3 g4 g5", nb_moves = 9 },
        level{ goal = "learnGrabAllTheStars", fen = "8/8/8/8/8/3N4/8/8 w - -", apples = "c3 e2 e4 f2 f4 g6", nb_moves = 6 },
        level{ goal = "learnGrabAllTheStars", fen = "8/2N5/8/8/8/8/8/8 w - -", apples = "b4 b5 c6 c8 d4 d5 e3 e7 f5", nb_moves = 9 },
    },
}

local pawn = {
    key = "pawn", title = "learnThePawn", subtitle = "learnItMovesForwardOnly", piece = "P",
    intro = "learnPawnIntro", complete = "learnPawnComplete",
    levels = {
        level{ goal = "learnPawnsMoveOneSquareOnly", fen = "8/8/8/P7/8/8/8/8 w - -", apples = "f3", nb_moves = 4, explain_promotion = true,
            shapes = { arrow("a5a6"), arrow("a6a7"), arrow("a7a8"), arrow("a8f3") } },
        level{ goal = "learnMostOfTheTimePromotingToAQueenIsBest", fen = "8/8/8/5P2/8/8/8/8 w - -", apples = "b6 c4 d7 e5 a8", nb_moves = 8 },
        level{ goal = "learnPawnsMoveForward", fen = "8/8/8/8/8/4P3/8/8 w - -", apples = "c6 d5 d7", nb_moves = 4,
            shapes = { arrow("e3e4"), arrow("e4d5"), arrow("d5c6"), arrow("c6d7") }, failure = A.no_piece_on("e3 e4 c6 d5 d7") },
        level{ goal = "learnCaptureThenPromote", fen = "8/8/8/8/8/1P6/8/8 w - -", apples = "b4 b6 c4 c6 c7 d6", nb_moves = 8 },
        level{ goal = "learnCaptureThenPromote", fen = "8/8/8/8/8/3P4/8/8 w - -", apples = "c4 b5 b6 d5 d7 e6 c8", nb_moves = 8,
            failure = A.white_pawn_on_any_of("b5 d4 d6 c7") },
        level{ goal = "learnUseAllThePawns", fen = "8/8/8/8/8/P1PP3P/8/8 w - -", apples = "b5 c5 d4 e5 g4", nb_moves = 7 },
        level{ goal = "learnAPawnOnTheSecondRank", fen = "8/8/8/8/8/8/4P3/8 w - -", apples = "d6", nb_moves = 3, shapes = { arrow("e2e4") },
            failure = A.white_pawn_on_any_of("e3"), highlighted_rank = 2 },
        level{ goal = "learnGrabAllTheStarsNoNeedToPromote", fen = "8/8/8/8/8/8/2PPPP2/8 w - -", apples = "c5 d5 e5 f5 d3 e4", nb_moves = 9 },
    },
}

-- Fundamentals

local function take(fields)
    fields.goal = fields.goal or "learnTakeTheBlackPiecesAndDontLoseYours"
    fields.points_for_capture = true
    fields.success = A.extinct("b")
    return level(fields)
end

local capture = {
    key = "capture", title = "learnCapture", subtitle = "learnTakeTheEnemyPieces",
    intro = "learnCaptureIntro", complete = "learnCaptureComplete",
    levels = {
        take{ goal = "learnTakeTheBlackPieces", fen = "8/2p2p2/8/8/8/2R5/8/8 w - -", nb_moves = 2, captures = 2, shapes = { arrow("c3c7"), arrow("c7f7") } },
        take{ fen = "8/2r2p2/8/8/5Q2/8/8/8 w - -", nb_moves = 2, captures = 2, shapes = { arrow("f4c7"), arrow("f4f7", "red"), arrow("c7f7", "yellow") } },
        take{ fen = "8/5r2/8/1r3p2/8/3B4/8/8 w - -", nb_moves = 5, captures = 3 },
        take{ fen = "8/5b2/5p2/3n2p1/8/6Q1/8/8 w - -", nb_moves = 7, captures = 4 },
        take{ fen = "8/3b4/2p2q2/8/3p1N2/8/8/8 w - -", nb_moves = 6, captures = 4 },
    },
}

local protection = {
    key = "protection", title = "learnProtection", subtitle = "learnKeepYourPiecesSafe",
    intro = "learnProtectionIntro", complete = "learnProtectionComplete",
    levels = {
        level{ goal = "learnEscape", fen = "8/8/8/4bb2/8/8/P2P4/R2K4 w - -", nb_moves = 1, shapes = { arrow("e5a1", "red"), arrow("a1c1") } },
        level{ goal = "learnEscape", fen = "8/8/2q2N2/8/8/8/8/8 w - -", nb_moves = 1 },
        level{ goal = "learnNoEscape", fen = "8/N2q4/8/8/8/8/6R1/8 w - -", nb_moves = 1, scenario = { step("g2a2", { arrow("a2a7", "green") }) } },
        level{ goal = "learnNoEscape", fen = "8/8/1Bq5/8/2P5/8/8/8 w - -", nb_moves = 1 },
        level{ goal = "learnNoEscape", fen = "1r6/8/5b2/8/8/5N2/P2P4/R1B5 w - -", nb_moves = 1, shapes = { arrow("f6a1", "red"), arrow("d2d4") } },
        level{ goal = "learnDontLetThemTakeAnyUndefendedPiece", fen = "8/1b6/8/8/8/3P2P1/5NRP/r7 w - -", nb_moves = 1 },
        level{ goal = "learnDontLetThemTakeAnyUndefendedPiece", fen = "rr6/3q4/4n3/4P1B1/7P/P7/1B1N1PP1/R5K1 w - -", nb_moves = 1 },
        level{ goal = "learnDontLetThemTakeAnyUndefendedPiece", fen = "8/3q4/8/1N3R2/8/2PB4/8/8 w - -", nb_moves = 1 },
    },
}

local combat = {
    key = "combat", title = "learnCombat", subtitle = "learnCaptureAndDefendPieces",
    intro = "learnCombatIntro", complete = "learnCombatComplete",
    levels = {
        take{ fen = "8/8/8/8/P2r4/6B1/8/8 w - -", nb_moves = 3, captures = 1,
            shapes = { arrow("a4a5"), arrow("g3f2"), arrow("f2d4"), arrow("d4a4", "yellow") } },
        take{ fen = "2r5/8/3b4/2P5/8/1P6/2B5/8 w - -", nb_moves = 4, captures = 2 },
        take{ fen = "1r6/8/5n2/3P4/4P1P1/1Q6/8/8 w - -", nb_moves = 4, captures = 2 },
        take{ fen = "2r5/8/3N4/5b2/8/8/PPP5/8 w - -", nb_moves = 4, captures = 2 },
        take{ fen = "8/6q1/8/4P1P1/8/4B3/r2P2N1/8 w - -", nb_moves = 8, captures = 2 },
    },
}

local function check1(fen, shapes)
    return level{ goal = "learnCheckInOneGoal", fen = fen, shapes = shapes, nb_moves = 1, failure = A.no(A.check), success = A.check }
end

local check1_stage = {
    key = "check1", title = "learnCheckInOne", subtitle = "learnAttackTheOpponentsKing",
    intro = "learnCheckInOneIntro", complete = "learnCheckInOneComplete",
    levels = {
        check1("4k3/8/2b5/8/8/8/8/R7 w - -", { arrow("a1e1") }),
        check1("8/8/4k3/3n4/8/1Q6/8/8 w - -"),
        check1("3qk3/1pp5/3p4/4p3/8/3B4/6r1/8 w - -"),
        check1("2r2q2/2n5/8/4k3/8/2N1P3/3P2B1/8 w - -"),
        check1("8/2b1q2n/1ppk4/2N5/8/8/8/8 w - -"),
        check1("6R1/1k3r2/8/4Q3/8/2n5/8/8 w - -"),
        check1("7r/4k3/8/3n4/4N3/8/2R5/4Q3 w - -"),
    },
}

local function out_of_check(goal, fen, shapes)
    return level{ goal = goal, fen = fen, shapes = shapes, detect_capture = "none", offer_illegal = true, nb_moves = 1 }
end

local out_of_check_stage = {
    key = "outOfCheck", title = "learnOutOfCheck", subtitle = "learnDefendYourKing",
    intro = "learnOutOfCheckIntro", complete = "learnOutOfCheckComplete",
    levels = {
        out_of_check("learnEscapeWithTheKing", "8/8/8/4q3/8/8/8/4K3 w - -", { arrow("e5e1", "red"), arrow("e1f1") }),
        out_of_check("learnEscapeWithTheKing", "8/2n5/5b2/8/2K5/8/2q5/8 w - -"),
        out_of_check("learnTheKingCannotEscapeButBlock", "8/7r/6r1/8/R7/7K/8/8 w - -"),
        out_of_check("learnYouCanGetOutOfCheckByTaking", "8/8/8/3b4/8/4N3/KBn5/1R6 w - -"),
        out_of_check("learnThisKnightIsCheckingThroughYourDefenses", "4q3/8/8/8/8/5nb1/3PPP2/3QKBNr w - -"),
        out_of_check("learnEscapeOrBlock", "8/8/7p/2q5/5n2/1N1KP2r/3R4/8 w - -"),
        out_of_check("learnEscapeOrBlock", "8/6b1/8/8/q4P2/2KN4/3P4/8 w - -"),
    },
}

local function mate1(fen, shapes, scenario)
    return level{ goal = "learnAttackYourOpponentsKing", fen = fen, shapes = shapes, scenario = scenario, nb_moves = 1,
        failure = A.no(A.mate), success = A.mate, show_failure_follow_up = true }
end

local checkmate1 = {
    key = "checkmate1", title = "learnMateInOne", subtitle = "learnDefeatTheOpponentsKing",
    intro = "learnMateInOneIntro", complete = "learnMateInOneComplete",
    levels = {
        mate1("3qk3/3ppp2/8/8/2B5/5Q2/8/8 w - -", { arrow("f3f7") }),
        mate1("6rk/6pp/7P/6N1/8/8/8/8 w - -"),
        mate1("R7/8/7k/2r5/5n2/8/6Q1/8 w - -"),
        mate1("2rb4/2k5/5N2/1Q6/8/8/8/8 w - -"),
        mate1("1r2kb2/ppB1p3/2P2p2/2p1N3/B7/8/8/3R4 w - -"),
        mate1("8/pk1N4/n7/b7/6B1/1r3b2/8/1RR5 w - -", nil, { step("g4f3", { arrow("b1b7", "yellow"), arrow("f3b7", "yellow") }) }),
        mate1("r1b5/ppp5/2N2kpN/5q2/8/Q7/8/4B3 w - -"),
    },
}

-- Intermediate

local setup = {
    key = "setup", title = "learnBoardSetup", subtitle = "learnHowTheGameStarts",
    intro = "learnBoardSetupIntro", complete = "learnBoardSetupComplete",
    levels = {
        level{ goal = "learnThisIsTheInitialPosition", fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w - -", nb_moves = 1 },
        level{ goal = "learnFirstPlaceTheRooks", fen = "r6r/pppppppp/8/8/8/8/8/2RR4 w - -", apples = "a1 h1", nb_moves = 2,
            shapes = { arrow("c1a1"), arrow("d1h1") }, success = A.every({ A.piece_on("R", "a1"), A.piece_on("R", "h1") }) },
        level{ goal = "learnThenPlaceTheKnights", fen = "rn4nr/pppppppp/8/8/8/8/2NN4/R6R w - -", apples = "b1 g1", nb_moves = 4,
            success = A.every({ A.piece_on("N", "b1"), A.piece_on("N", "g1") }) },
        level{ goal = "learnPlaceTheBishops", fen = "rnb2bnr/pppppppp/8/8/4BB2/8/8/RN4NR w - -", apples = "c1 f1", nb_moves = 4,
            success = A.every({ A.piece_on("B", "c1"), A.piece_on("B", "f1") }) },
        level{ goal = "learnPlaceTheQueen", fen = "rnbq1bnr/pppppppp/8/8/5Q2/8/8/RNB2BNR w - -", apples = "d1", nb_moves = 2,
            success = A.piece_on("Q", "d1") },
        level{ goal = "learnPlaceTheKing", fen = "rnbqkbnr/pppppppp/8/8/5K2/8/8/RNBQ1BNR w - -", apples = "e1", nb_moves = 3,
            success = A.piece_on("K", "e1") },
        level{ goal = "learnPawnsFormTheFrontLine", fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w - -", nb_moves = 1, highlighted_rank = 2 },
    },
}

local castled_king_side = A.castled("king")
local castled_queen_side = A.castled("queen")

local function cant_castle(side, black_king)
    return A.every({
        A.no(A.castled(side)),
        A.any({
            A.piece_not_on("K", "e1"),
            A.piece_not_on("R", side == "king" and "h1" or "a1"),
            A.mate,
            A.piece_not_on("k", black_king),
        }),
    })
end

local castling = {
    key = "castling", title = "learnCastling", subtitle = "learnTheSpecialKingMove",
    intro = "learnCastlingIntro", complete = "learnCastlingComplete",
    levels = {
        level{ goal = "learnCastleKingSide", fen = "rnbqkbnr/pppppppp/8/8/2B5/4PN2/PPPP1PPP/RNBQK2R w KQkq -", nb_moves = 1,
            shapes = { arrow("e1g1") }, success = castled_king_side, failure = cant_castle("king", "e8") },
        level{ goal = "learnCastleQueenSide", fen = "rnbqkbnr/pppppppp/8/8/4P3/1PN5/PBPPQPPP/R3KBNR w KQkq -", nb_moves = 1,
            shapes = { arrow("e1c1") }, success = castled_queen_side, failure = cant_castle("queen", "e8") },
        level{ goal = "learnTheKnightIsInTheWay", fen = "rnbqkbnr/pppppppp/8/8/8/4P3/PPPPBPPP/RNBQK1NR w KQkq -", nb_moves = 2,
            shapes = { arrow("e1g1"), arrow("g1f3") }, success = castled_king_side, failure = cant_castle("king", "e8") },
        level{ goal = "learnCastleKingSideMovePiecesFirst", fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -", nb_moves = 4,
            shapes = { arrow("e1g1") }, success = castled_king_side, failure = cant_castle("king", "e8") },
        level{ goal = "learnCastleQueenSideMovePiecesFirst", fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -", nb_moves = 6,
            shapes = { arrow("e1c1") }, success = castled_queen_side, failure = cant_castle("queen", "e8") },
        level{ goal = "learnYouCannotCastleIfMoved", fen = "rnbqkbnr/pppppppp/8/8/3P4/1PN1PN2/PBPQBPPP/R3K1R1 w Qkq -", nb_moves = 1,
            shapes = { arrow("e1g1", "red"), arrow("e1c1") }, success = castled_queen_side, failure = cant_castle("queen", "e8") },
        level{ goal = "learnYouCannotCastleIfAttacked", fen = "rn1qkbnr/ppp1pppp/3p4/8/2b5/4PN2/PPPP1PPP/RNBQK2R w KQkq -", nb_moves = 2,
            shapes = { arrow("c4f1", "red"), circle("e1"), circle("f1"), circle("g1") }, success = castled_king_side,
            failure = cant_castle("king", "e8"), detect_capture = "none" },
        level{ goal = "learnFindAWayToCastleKingSide", fen = "rnb2rk1/pppppppp/8/8/8/4Nb1n/PPPP1P1P/RNB1KB1R w KQkq -", nb_moves = 2,
            shapes = { arrow("e1g1") }, success = castled_king_side, failure = cant_castle("king", "g8"), detect_capture = "none" },
        level{ goal = "learnFindAWayToCastleQueenSide", fen = "1r1k2nr/p2ppppp/7b/7b/4P3/2nP4/P1P2P2/RN2K3 w Q -", nb_moves = 4,
            shapes = { arrow("e1c1") }, success = castled_queen_side, failure = cant_castle("queen", "d8"), detect_capture = "none" },
    },
}

local function en_passant(fields)
    fields.color = "w"
    fields.success = A.scenario_complete
    fields.failure = A.scenario_failed
    fields.detect_capture = "none"
    return level(fields)
end

local enpassant = {
    key = "enpassant", title = "enPassant", subtitle = "learnTheSpecialPawnMove",
    intro = "learnEnPassantIntro", complete = "learnEnPassantComplete",
    levels = {
        en_passant{ goal = "learnBlackJustMovedThePawnByTwoSquares", fen = "rnbqkbnr/pppppppp/8/2P5/8/8/PP1PPPPP/RNBQKBNR b KQkq -",
            nb_moves = 1, captures = 1, scenario = { step("d7d5", { arrow("c5d6") }), step("c5d6") } },
        en_passant{ goal = "learnEnPassantOnlyWorksImmediately", fen = "rnbqkbnr/ppp1pppp/8/2Pp3P/8/8/PP1PPPP1/RNBQKBNR b KQkq -",
            nb_moves = 1, captures = 1, scenario = { step("g7g5", { arrow("h5g6"), arrow("c5d6", "red") }), step("h5g6") } },
        en_passant{ goal = "learnEnPassantOnlyWorksOnFifthRank", fen = "rnbqkbnr/pppppppp/P7/2P5/8/8/PP1PPPP1/RNBQKBNR b KQkq -",
            nb_moves = 1, captures = 1, highlighted_rank = 5,
            scenario = { step("b7b5", { arrow("c5b6"), arrow("a6b7", "red") }), step("c5b6") } },
        en_passant{ goal = "learnTakeAllThePawnsEnPassant", fen = "rnbqkbnr/pppppppp/8/2PPP2P/8/8/PP1P1PP1/RNBQKBNR b KQkq -",
            nb_moves = 4, captures = 4, scenario = {
                step("b7b5"), step("c5b6"), step("f7f5"), step("e5f6"), step("c7c5"), step("d5c6"), step("g7g5"), step("h5g6"),
            } },
    },
}

local function stalemate_level(fen, shapes, scenario)
    return level{ goal = "learnStalemateGoal", fen = fen, shapes = shapes, scenario = scenario, detect_capture = "none", nb_moves = 1,
        next_button = true, show_failure_follow_up = true, success = A.scenario_complete, failure = A.scenario_failed }
end

local stalemate = {
    key = "stalemate", title = "learnStalemate", subtitle = "learnTheGameIsADraw",
    intro = "learnStalemateIntro", complete = "learnStalemateComplete",
    levels = {
        stalemate_level("k7/8/8/6B1/8/1R6/8/8 w - -", { arrow("g5e3") }, { step("g5e3", {
            arrow("e3a7", "blue"), arrow("b3b7", "blue"), arrow("b3b8", "blue"), circle("a7", "blue"), circle("b7", "blue"), circle("b8", "blue"),
        }) }),
        stalemate_level("8/7p/4N2k/8/8/3N4/8/1K6 w - -", nil, { step("d3f4", {
            arrow("e6g7", "blue"), arrow("e6g5", "blue"), arrow("f4g6", "blue"), arrow("f4h5", "blue"),
            circle("g7", "blue"), circle("g5", "blue"), circle("g6", "blue"), circle("h5", "blue"),
        }) }),
        stalemate_level("4k3/6p1/5p2/p4P2/PpB2N2/1K6/8/3R4 w - -", nil, { step("f4g6", {
            arrow("c4f7", "blue"), arrow("d1d8", "blue"), arrow("g6e7", "blue"), arrow("g6f8", "blue"),
        }) }),
        stalemate_level("8/6pk/6np/7K/8/3B4/8/1R6 w - -", nil, { step("b1b8", {
            arrow("b8g8", "blue"), arrow("b8h8", "blue"), arrow("d3h7", "red"), arrow("g6e7", "red"),
        }) }),
        stalemate_level("7R/pk6/p1pP4/K7/3BB2p/7p/1r5P/8 w - -", nil, { step("d4b2", {
            arrow("h8a8", "blue"), arrow("a5b6", "blue"), arrow("d6c7", "blue"), arrow("e4b7", "red"), arrow("c6c5", "red"),
        }) }),
    },
}

-- Advanced

local function value_level(goal, fen, scenario, opts)
    opts = opts or {}
    return level{ goal = goal, fen = fen, scenario = { step(scenario) }, shapes = opts.shapes, nb_moves = 1, captures = 1,
        points_for_capture = true, show_piece_values = true, offer_illegal = opts.offer_illegal, success = A.scenario_complete,
        failure = A.scenario_failed, detect_capture = opts.detect_capture }
end

local value = {
    key = "value", title = "learnPieceValue", subtitle = "learnEvaluatePieceStrength",
    intro = "learnPieceValueIntro", complete = "learnPieceValueComplete",
    levels = {
        value_level("learnQueenOverBishop", "8/8/2qrbnp1/3P4/8/8/8/8 w - -", "d5c6", { shapes = { arrow("d5c6") }, detect_capture = "none" }),
        value_level("learnPieceValueExchange", "8/8/4b3/1p6/6r1/8/4Q3/8 w - -", "e2e6", { detect_capture = "any" }),
        value_level("learnPieceValueLegal", "5b2/8/6N1/2q5/3Kn3/2rp4/3B4/8 w - -", "d4e4", { offer_illegal = true }),
        value_level("learnTakeThePieceWithTheHighestValue", "1k4q1/pp6/8/3B4/2P5/1P1p2P1/P3Kr1P/3n4 w - -", "e2d1",
            { offer_illegal = true, detect_capture = "none" }),
        value_level("learnTakeThePieceWithTheHighestValue", "7k/3bqp1p/7r/5N2/6K1/6n1/PPP5/R1B5 w - -", "c1h6", { offer_illegal = true }),
    },
}

local function check2(fen, shapes)
    return level{ goal = "learnCheckInTwoGoal", fen = fen, shapes = shapes, nb_moves = 2, failure = A.no_check_in(2), success = A.check_in(2) }
end

local check2_stage = {
    key = "check2", title = "learnCheckInTwo", subtitle = "learnTwoMovesToGiveCheck",
    intro = "learnCheckInTwoIntro", complete = "learnCheckInTwoComplete",
    levels = {
        check2("2k5/2pb4/8/2R5/8/8/8/8 w - -", { arrow("c5a5"), arrow("a5a8") }),
        check2("8/8/5k2/8/8/1N6/5b2/8 w - -"),
        check2("6k1/2r3pp/8/1N6/8/8/4B3/8 w - -"),
        check2("r3k3/7b/8/4B3/8/8/4N3/4R3 w - -"),
        check2("r1bqkb1r/pppp1p1p/2n2np1/4p3/2B5/4PN2/PPPP1PPP/RNBQK2R w KQkq -"),
        check2("8/8/8/2k5/q7/4N3/3B4/8 w - -"),
        check2("r6r/1Q2nk2/1B3p2/8/8/8/8/8 w - -"),
    },
}

return {
    { key = "chess-pieces", name = "learnChessPieces", stages = { rook, bishop, queen, king, knight, pawn } },
    { key = "fundamentals", name = "learnFundamentals", stages = { capture, protection, combat, check1_stage, out_of_check_stage, checkmate1 } },
    { key = "intermediate", name = "learnIntermediate", stages = { setup, castling, enpassant, stalemate } },
    { key = "advanced", name = "learnAdvanced", stages = { value, check2_stage } },
}
