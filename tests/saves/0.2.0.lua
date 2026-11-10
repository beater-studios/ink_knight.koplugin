-- koreader/settings/ink_knight.lua written by Ink Knight 0.2.0 in the emulator: options, a game against the engine, a pile of puzzles and a result waiting to be sent.
return {
    ["board_coordinates"] = true,
    ["board_style"] = "newspaper",
    ["confirm_moves"] = true,
    ["offline_game"] = {
        ["level"] = 2,
        ["moves"] = "e2e4 g7g6 g1f3 f7f6",
        ["my_color"] = "w",
    },
    ["piece_set"] = "merida",
    ["puzzle_results"] = {
        [1] = {
            ["id"] = "p0009",
            ["rated"] = true,
            ["win"] = false,
        },
    },
    ["puzzles"] = {
        [1] = {
            ["id"] = "p0001",
            ["played"] = "e2e4 e7e5 f1c4 b8c6 d1h5 g8f6",
            ["rating"] = 1400,
            ["solution"] = {
                [1] = "h5f7",
            },
            ["themes"] = {
                [1] = "mateIn1",
            },
        },
        [2] = {
            ["id"] = "p0002",
            ["played"] = "d2d4 d7d5 c2c4 e7e6 b1c3 g8f6 c1g5",
            ["rating"] = 1550,
            ["solution"] = {
                [1] = "f8e7",
                [2] = "e2e3",
            },
            ["themes"] = {
                [1] = "opening",
            },
        },
        [3] = {
            ["id"] = "p0003",
            ["played"] = "e2e4 c7c5 g1f3 d7d6 d2d4 c5d4 f3d4 g8f6 b1c3 a7a6",
            ["rating"] = 1700,
            ["solution"] = {
                [1] = "c1e3",
                [2] = "e7e5",
                [3] = "d4b3",
            },
            ["themes"] = {
                [1] = "middlegame",
            },
        },
    },
    ["rated"] = true,
    ["rating_margin"] = 200,
    ["refresh_minutes"] = 15,
}
