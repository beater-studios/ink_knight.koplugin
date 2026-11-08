# Ink Knight: design and tools

A Lichess client inside KOReader, built for e-ink. `ink_knight` is the plugin identifier. The research and the lessons from earlier clients are in `docs/research/chess-clients.md` and `docs/research/lichess-api.md`, in the `kindle` project.

## What is in and out

| Part | What it has |
|---|---|
| Play | Seek in rapid and classical with an optional rating range, correspondence, challenges with blitz or no time limit, the Lichess computer with a clock or no time limit, choice of color in a challenge, several games at once, a list with whose turn it is, the challenges sent and still unanswered, which can be canceled |
| During a game | Draw offers, draws by repetition, asking for a takeback, giving time, claiming when the opponent leaves, playing again |
| Train | Puzzles with a saved pile, puzzles by theme, the results of the last 30 days, the daily puzzle, a game against a small engine with no network |
| Review | Past games and favorites, with the evaluation, the most played moves and the tablebase result of each position |
| Players | Search, who is online among those followed, profiles, follow and unfollow, a rating chart with statistics, the record against someone |

Out of scope, by decision: tournaments, bullet (the network alone takes 1.4 to 2.7 s per move on a Kindle), engine help in a game on Lichess, chat, Lichess TV, broadcasts, studies, importing PGN, and the bot API, which needs turning the account into a bot account. Variants stay as an idea for later, starting with Chess960, since each one needs its own rules. Lichess refuses a seek below rapid, so `Api.REAL_TIME_SEEK` only lists clocks of at least 8 minutes in the estimate it uses (initial time plus 40 times the increment), and a test keeps it that way. A correspondence seek has no way to be canceled through the API, because the cancel route only covers real-time seeks, and when an opponent cancels the game before the seek's author does, Lichess puts the seek back by itself (`AbortListener` in the Lichess source). So one seek can lead to several games in a row.

## Permissions

Each endpoint of Lichess accepts any one of its scopes, so `board:play` alone covers seeks, games, challenges, the computer and the event stream. The rest is by feature: `follow:read` and `follow:write`, `puzzle:read` and `puzzle:write`, `challenge:write` only to give time, and `preference:write` only to add or remove a favorite. That last one also allows changing the preferences of the account, which the plugin never does, so the link for creating a token leaves it unmarked. Listing favorites needs none of these.

`token_scopes.lua` knows what each feature needs. Lichess states the scopes of the token in the `x-oauth-scopes` header of every authenticated answer, and the plugin reads it from `/api/account`. `/api/token/test` gives the same, but its answer repeats the token, and answers go through a temporary file. A missing scope does not hide anything: the option stays and says what is missing, as a hidden feature looks like one that does not exist. When the header is absent nothing is assumed, and Lichess has the last word.

Token creation has a link with the scopes marked, in `ui/create_token_screen.lua`, shown as a QR code.

## Network

- **A child process per connection.** Each request runs in a child made by KOReader's `runInSubProcess`, using LuaSocket and LuaSec, which come with KOReader on every platform, so there is nothing to install. A TLS handshake in the main process would freeze the interface for seconds at each move. The child writes to its own files, and `Net:tick` reads them without waiting.
- **macOS, for development only.** macOS kills a forked child that touches the network ("crashed on child side of fork pre-exec"), so there each request runs as a new program, through `worker_main.lua`, with the request in a file in the private folder that the program deletes on reading. Devices run Linux and always use the forked child.
- **Certificates and the name of the server.** `tls.lua` opens every connection, asks for `verify = "peer"` with KOReader's `data/ca-bundle.crt` and then checks the name of the server against the alternative names of the certificate. KOReader's `ssl.https` is not used, because on the stable version (2026.07.2) it leaves verification off by default and never checks the name, so any valid certificate, for any site, would get the token. Recent builds do check it, which is why this passed on a newer emulator and failed on a real Kindle. A proxy set in KOReader is ignored too. `tools/koreader/check_tls.lua` confirms each refusal for the right reason, and it needs to run on the oldest version supported, not only on the emulator.
- **Streams** write each piece to a file as it arrives, read by offset and split into lines. Empty lines are keep-alives. A connection silent for 10 minutes ends and reconnects.
- **Checking costs little.** On a Kindle, a file operation right after a pause takes 5 to 30 ms, against 0.05 ms in a tight loop, so what matters is how often the screen checks. It checks once a second while only streams are open, and three times a second while a request is running. A new request brings the next check forward, so it starts right after the screen paints the tap. Each check asks the size of the file of a stream and opens it only if it grew, and asks the system whether the child ended, so there are no extra files to look for.
- **One at a time.** Lichess asks for one request at a time, so they run in a queue, with a 45-second limit each, and streams run beside it. A 429 pauses the queue for a minute.
- **Children are always collected.** A child that ends or dies is noticed even if it wrote nothing, and is reaped, so none stays as a zombie. Closing kills them all and waits.
- **Token in use.** On devices, it stays in memory and goes in a header, so it is not in the address, in temporary files or in the list of processes. Only letters, digits and `_` are accepted in a token, and only those plus `-` in ids and names.
- **Other servers.** The opening database at `explorer.lichess.org` asks for the token, and `net.lua` only sends it there and to `lichess.org`. The tablebase at `tablebase.lichess.org` is public and never gets it.
- **Moves are never sent twice by itself.** If a move fails, the board goes back and says so, and the reader decides.

## Where the token is kept

The shared storage of an e-reader is a FAT-like filesystem, where `chmod` does nothing, so a file there is readable by anyone who plugs the device into a computer. `token_store.lua` therefore:

- On a Kindle, uses `/var/local/ink_knight`, in the system partition, which USB does not reach, with folder `700` and file `600`.
- Everywhere else, uses `settings/ink_knight_token`, also with `600`.
- Writes under `umask 077` to a temporary file and renames it, so the file is never readable by others, not even briefly.
- Checks the permissions the filesystem really reports, and reads the file back, before calling it protected. Otherwise it falls back to the settings folder and warns the reader, and **Where the token is** in the settings says which case applies.
- Moves a token found in the settings folder to the private place, and removes the old file.
- Closes the permissions again whenever it loads a token. At every boot, a Kindle gives the group `javausers`, used by its own services (`framework` and `bluetooth`), access to the whole system partition, which turns the folder into `2770` and the file into `660`. Other users never get access. So, from a reboot until Ink Knight is opened, those services can read the token.

The token is not encrypted, because the key would have to live on the same device, which would only look like protection. What this does not protect against: anything running as root, including SSH and other plugins, can read it. The answer to those cases, and to a lost device, is revoking the token on Lichess, and the permissions are already limited so it cannot send private messages or change the account.

## Screens

`ui/home.lua` opens on a first page with no network: play online, or connect an account if there is no token, play offline, about and exit. Playing online asks KOReader for the Wi-Fi, opens the online part and starts the network, and leaving that part stops it. With no connection, that part stays open, says so, and tries again every 30 seconds. When Lichess refuses the token, on any request, every row of that part is disabled except one that goes to connecting an account, and tapping it removes the token, so leaving without connecting comes back to the first page asking for an account. Saved puzzles and the offline game are also reachable from the first page.

`ui/page.lua` is every screen outside the board: a title with a way back, and rows meant for a finger, such as tiles, toggles and stats. There are no popups from KOReader. A choice is a page, a question is a page with two buttons, and `ui/toast.lua` gives short notices at the bottom without taking taps. A row answers a tap by inverting, because what comes next can take a moment on e-ink. The exceptions are the keyboard, and the question that allows a phone on the token page. The challenges received and sent share one line when both exist, each a button of half the width whose text gets smaller if it does not fit, and each takes the whole line alone. The sent ones come from the event stream, which also reports the challenges the reader makes, so no other permission is needed, and canceling uses the same `board:play`. A correspondence seek cannot be listed or canceled through the API, so it is not among them. Both lists start over whenever the stream opens, after a sleep or a dropped connection, since Lichess sends everything still pending and nothing about what changed while it was closed. A player who is not signed in comes from Lichess with no name and is called anonymous.

## Board

- **Pieces** come from the chess symbols of FreeSerif, which ships with KOReader, so there is no art to license. The solid symbol gives the shape and the hollow one the outline: a white piece is the solid one in white with the hollow one in black, and a black piece is the solid one in black. Both are cut to the same box, so they stay aligned and centered.
- **Styles.** Five board styles: plain, with gray dark squares, and newspaper, crosshatch, dotted and contrast. The patterns are only black and white, and contrast uses the darker gray 0x55. On those four, a piece gets a white edge, its shape grown by 2 px, so it stands out. Three piece sets: classic, from FreeSerif, and Cburnett and Merida, pictures in `ink_knight/pieces` from the Lichess source (see NOTICE), drawn with KOReader's SVG renderer and kept for the session, so they are drawn once per size. A set whose picture fails to load falls back to classic. Coordinates are optional, in the corners of the edge squares. All of this is chosen in the settings and in the offline menu. A dark theme for the whole plugin was left out: KOReader's night mode already inverts it.
- **One screen for every mode.** `ui/board_screen.lua` only draws the state it receives and reports taps. `live_game`, `offline_game`, `puzzle_screen` and `review_screen` decide what to show.
- **The list of moves.** `ui/move_list.lua` shows a game in the usual notation, two moves to a row as on a score sheet, on a page that opens on the sheet holding the move to look at, the last one by default. `Chess.san_list` writes the notation from the starting position, so a game from a position is numbered from there. Writing a move lists the legal moves to tell pieces apart, about 20 ms for 160 half moves on a Mac and much slower on a Kindle, so the games keep what was written and add only the new moves, and the review uses the notation that comes with the game from Lichess. The offline game has it on its bar, the online game among its actions, and the review in its menu, where the move shown is marked and a tap on another goes to it. At the start of a review the list opens on its first sheet, and elsewhere on the last move. Puzzles do not have it, since they are a few moves from a position.
- **Refresh.** `board_diff.lua` compares what is on screen with what comes next, and only what changed goes to the display: each square as its own region, so a move touches the squares it changed and nothing between them. A clock only touches its own bar. Every 40 changes the whole screen is redrawn, to clear what e-ink leaves behind. Tried on the Kindle 10 in 2026-11: `[partial]` looked worse than `ui`, because it is sent as a full update and redraws the gray squares, and GL16 as a partial update brought no gain worth calling the driver directly. So squares stay on `ui`. DU4, which other Kindles can use, does not exist in the driver of this model, where waveform 7 is `ZELDA_LAST`.
- **Time and battery.** `ui/status_strip.lua` draws them centered at the bottom of every full screen. The room comes from the buttons of the board, which lost 8 px, and from the gap that was left under them, so the board keeps its size. `Home` has one timer for the whole plugin: when the minute changes, only the screen on top redraws, and only the middle of the strip goes to the display.
- **Staying awake.** Only during a game with a clock, as Book Drop does, with a marker so a crash cannot leave the device unable to sleep. Correspondence does not need it.

## Analysis

Only in `review_screen`, which only opens finished games, so nothing here can help in a game under way. A position asks three things, one at a time: the cloud evaluation, the most played moves and, with up to 7 pieces, the tablebase. The API has no way to ask Lichess for a new analysis, and the cloud only keeps positions already computed, so a position outside it says so. A game someone analyzed on the site also shows the evaluation of each move, read from the same export.

## Rules

`chess.lua` is the whole set of rules, with no KOReader dependency, checked against known position counts (perft) on six reference positions. It covers castling, en passant, promotion, pins, checks, mate, stalemate, insufficient material, the fifty-move rule, the usual notation and UCI. Lichess remains the authority in online games: the local rules only decide what can be tapped, and the stream always replaces the local state. Variants other than standard are refused when a challenge is answered.

## Puzzles

A batch of 15 is saved in `settings/ink_knight.lua`, and another is asked for when 3 or fewer are left. Each theme has its own pile, and results go to Lichess under the theme they came from. Solving works with no network. Results stay saved until they reach Lichess, in the same request format as the batch API, and a failure just keeps them for next time. A puzzle counts as a win only with no mistake and without showing the move. A puzzle left unsolved goes back to the pile, and any mate is accepted even when it is not the expected one. The daily puzzle reports nothing.

## Offline engine

`engine.lua` is a negamax with alpha-beta and iterative deepening, valued by material with small rewards for the center and for advancing pawns. It is a coroutine: `offline_game` runs it for 40 ms at a time and gives the screen its turn, which is what froze the screen in earlier clients. Each of the 4 levels has a time limit, a depth and an amount of noise, and noise never throws away a forced mate. The game is saved after each move, and draws by repetition, the fifty-move rule and insufficient material are checked here, since no server does it. The reader picks a color, or lets it be drawn, and playing again keeps that choice. Undo goes back to the reader's last move, taking the computer's answer with it and stopping a search under way, and works after a mate too, but not after resigning. A hint runs the same search with `Engine.HINT` (3 seconds, depth 3, no noise), so it is the best move found and not a weaker one, marks the piece and its square, so a tap there plays it, and names the move below the board. Here it is not cheating, since no server is involved. The same screen plays a game between two people on one device: no engine, whoever is to move plays, undo takes back one move, a button turns the board and the way it faces is saved, resigning is for the side to move, and the game is kept under its own key, apart from the one against the engine.

## Token page

`ui/token_screen.lua`, with `token_access.lua` and `token_server.lua`, receives the token from a phone. The rules follow Book Drop. None of them makes the connection fully secure: there is no HTTPS, so someone capturing traffic on the same network could see the token. That is why the screen asks for a trusted network.

| Layer | What it does |
|---|---|
| Only on while in use | The server exists while the screen is open, and closes on Cancel, on sleep, after a token arrives and after 5 minutes without use |
| Firewall | The port opens in `iptables` during the session, and the rule goes away on closing |
| Secret code | The address carries a random code from `/dev/urandom`, new at each opening. Without it, every answer is the same 404 |
| Approval on the device | The first device with the code must be approved on the screen, and no form is shown before that |
| One device | Once approved, no other address is served |
| Private networks only | It refuses to start outside 10.x, 172.16-31.x and 192.168.x, and refuses clients from outside |
| `Host` and `Origin` | Block DNS rebinding and other sites posting to the page |
| Limits | Headers up to 8 KB, a body up to 512 bytes, 6 connections and 15 seconds each. 20 invalid requests block that address |
| Token | Must have the shape of a Lichess token, is never echoed in a page and is never logged |
| Pages | No script, a restrictive `Content-Security-Policy`, `nosniff`, no frames and no cache |

## Structure

```
ink_knight.koplugin/
  _meta.lua, main.lua     registration in KOReader, and recovery after a crash
  ink_knight/
    chess.lua             the rules
    game.lua              the state of a game on Lichess, fed by its stream
    api.lua               what each action asks of Lichess
    net.lua               child processes and their files
    https_worker.lua      one HTTPS request, inside the child
    tls.lua               the secure connection, with the check of the server's name
    worker_main.lua       the same request as its own program, only on macOS
    pgn.lua               reads moves in the usual notation
    analysis.lua          what Lichess knows about a position, as text
    rating_chart.lua      the rating over time, as marks to draw
    engine.lua            the offline engine, in slices
    puzzles.lua           puzzles and their results
    token_store.lua       where the token is kept
    token_scopes.lua      what each feature asks of the token
    token_access.lua      who gets what on the token page
    token_server.lua      the server of the token page
    board_diff.lua        what changed on the board, for the refresh
    i18n.lua              texts in three languages
    pieces/               pictures of the Cburnett and Merida sets
    ui/                   the screens
  tests/, tools/, docs/   development
```

## Tools

- `for spec in tests/*_spec.lua; do luajit "$spec"; done`: rules, the game state, requests, the network layer with recorded child processes, PGN, the engine, puzzles, where the token is kept and the token page.
- With `KOREADER_DIR` pointing to a desktop KOReader:
  - `INK_KNIGHT_TOKEN=lip_... OUTPUT_DIR=<folder> tools/koreader/run_headless.sh tools/koreader/check_live.lua` goes through the screens against the real Lichess, with no window, and saves a picture of each. With `PLAY_AI=1` it also plays a casual game against level 1 and resigns it, which stays in the account's history. It never sends puzzle results.
  - `tools/koreader/run_headless.sh tools/koreader/check_tls.lua` confirms that bad certificates are refused. It needs internet and sends no token.
  - `OUTPUT_DIR=<folder> tools/koreader/run_headless.sh tools/koreader/check_token_page.lua` tests the token page with real connections, including attempts that must fail.
  - `OUTPUT_DIR=<folder> tools/koreader/run_headless.sh tools/koreader/check_token_rejected.lua` goes through a refused token on the real screens, with invented answers and no network.
  - `OUTPUT_DIR=<folder> tools/koreader/run_headless.sh tools/koreader/check_offline_game.lua` plays offline games on the real screens: choosing a color, undo, also while the engine thinks and after a mate, and a hint played with a tap, plus the list of moves offline and in a long review, where it opens on the right sheet and a tap goes to the move.
  - `OUTPUT_DIR=<folder> tools/koreader/run_headless.sh tools/koreader/check_challenges.lua` goes through the challenges sent, with invented answers and no network: the buttons beside the received ones in the three languages, canceling, a challenge already gone, and one declined or accepted.
  - `OUTPUT_DIR=docs/screenshots tools/koreader/run_headless.sh tools/koreader/render_readme_screens.lua` draws the README images with invented players.
- `KOREADER_DIR=<desktop KOReader> python3 -I tools/make_brand_art.py` draws the icon, the banner and the social preview from the README images, with the knight of FreeSerif and no Lichess artwork.
- `tools/package.sh` builds the zip and the checksum, only with what the plugin uses.

## How to publish a version

1. Update `version` in `_meta.lua` and create the version's section in `CHANGELOG.md`.
2. Run the tests and try it on a device.
3. Publish the release on GitHub, creating the `v<version>` tag with it. The `release.yml` workflow checks that the tag matches `_meta.lua`, runs the tests and attaches the zip and the checksum.
