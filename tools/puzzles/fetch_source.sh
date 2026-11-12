#!/bin/sh
# Downloads the Lichess puzzle database into an empty folder and checks it against tools/puzzles/source.sha256, the
# file the published puzzles were built from. Lichess replaces the file every month under the same name, with no
# version to ask for, so a different checksum means a newer database: the release does not build the puzzles again,
# and updating them is a change of its own (UPDATE=1, then build, review the difference and write the new checksum).
# Usage: sh tools/puzzles/fetch_source.sh <empty folder>
set -eu
dest="${1:?usage: fetch_source.sh <empty folder for the database>}"
sums="$(cd "$(dirname "$0")" && pwd)/source.sha256"
mkdir -p "$dest"
if [ -n "$(ls -A "$dest")" ]; then
    echo "the folder must be empty: $dest" >&2
    exit 1
fi
name=lichess_db_puzzle.csv.zst
curl -fsSL --max-time 1800 -o "$dest/$name" "https://database.lichess.org/$name"
actual="$(shasum -a 256 "$dest/$name" | cut -d' ' -f1)"
expected="$(awk -v name="$name" '$2 == name { print $1 }' "$sums")"
if [ "$actual" != "$expected" ]; then
    if [ "${UPDATE:-}" = 1 ]; then
        echo "a newer database: $actual (write it in tools/puzzles/source.sha256 once the puzzles are reviewed)"
    else
        echo "checksum mismatch: $name is not the database the puzzles were built from (UPDATE=1 to use it)" >&2
        exit 1
    fi
fi
echo "downloaded: $dest/$name"
