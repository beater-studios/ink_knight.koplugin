#!/bin/sh
# Every check that runs without KOReader. The CI runs tools/check.sh; the release runs tools/check.sh release,
# which also downloads the list of openings, the texts of Learn chess and the practice lessons, builds them again and
# fails if they differ from the repository, and downloads the piece sets and the positions of the rule tests and fails
# if they differ from ink_knight/pieces and tests/perft. The puzzles in the package come from a database with no version, so they are not built again.
set -eu
cd "$(dirname "$0")/.."
# Deeper than on a Kindle, where the install runs the tests too.
export PERFT_LIMIT="${PERFT_LIMIT:-1000000}"
# Every one of the 960 starting positions of Chess960, to the second depth.
export CHESS960_EVERY="${CHESS960_EVERY:-1}"
export CHESS960_LIMIT="${CHESS960_LIMIT:-1000}"
for spec in tests/*_spec.lua; do
    luajit "$spec"
done
luajit tools/check_texts.lua s strings
# The Stockfish for the Kindle is built by tools/stockfish/build.sh, which needs Docker; here only its checksum.
expected="$(awk '$2 == "stockfish-armhf" { print $1 }' tools/stockfish/sources.sha256)"
actual="$( (sha256sum bin/stockfish-armhf 2>/dev/null || shasum -a 256 bin/stockfish-armhf) | cut -d' ' -f1)"
if [ "$actual" != "$expected" ]; then
    echo "bin/stockfish-armhf differs from the one tools/stockfish/build.sh builds." >&2
    exit 1
fi
if [ "${1:-}" = release ]; then
    sources="$(mktemp -d)"
    trap 'rm -rf "$sources"' EXIT
    mkdir "$sources/openings" "$sources/learn" "$sources/practice" "$sources/pieces" "$sources/perft"
    sh tools/openings/fetch_sources.sh "$sources/openings"
    luajit tools/openings/build.lua "$sources/openings"
    sh tools/learn/fetch_sources.sh "$sources/learn"
    python3 -I tools/learn/build_texts.py "$sources/learn"
    sh tools/practice/fetch_sources.sh "$sources/practice"
    luajit tools/practice/build.lua "$sources/practice"
    sh tools/pieces/fetch_sources.sh "$sources/pieces"
    if ! diff -rq -x .DS_Store -x '._*' "$sources/pieces" ink_knight/pieces; then
        echo "ink_knight/pieces/ differs from the piece sets of the sources." >&2
        exit 1
    fi
    sh tools/perft/fetch_sources.sh "$sources/perft"
    if ! diff -rq -x .DS_Store -x '._*' "$sources/perft" tests/perft; then
        echo "tests/perft/ differs from the positions of the sources." >&2
        exit 1
    fi
    # Also catches new files, which git diff leaves out.
    if [ -n "$(git status --porcelain -- ink_knight/data)" ]; then
        git status --short -- ink_knight/data
        echo "ink_knight/data/ differs from what the sources generate." >&2
        exit 1
    fi
fi
sh tools/package.sh
