#!/bin/sh
# Downloads the list of openings of Lichess at a fixed commit and checks it against tools/openings/sources.sha256,
# so a release always builds the same names.
set -eu
dest="${1:?usage: fetch_sources.sh <empty folder for the sources>}"
sums="$(cd "$(dirname "$0")" && pwd)/sources.sha256"
mkdir -p "$dest"
if [ -n "$(ls -A "$dest")" ]; then
    echo "the folder must be empty: $dest" >&2
    exit 1
fi
base=https://raw.githubusercontent.com/lichess-org/chess-openings/3ba6b20d31b2e6125cb0e6a2e792f400717d9d39
for name in a.tsv b.tsv c.tsv d.tsv e.tsv; do
    curl -fsSL --max-time 120 -o "$dest/$name" "$base/$name"
    expected="$(awk -v name="$name" '$2 == name { print $1 }' "$sums")"
    if [ "$(shasum -a 256 "$dest/$name" | cut -d' ' -f1)" != "$expected" ]; then
        echo "checksum mismatch: $name (the source changed; update the commit or sources.sha256 on purpose)" >&2
        exit 1
    fi
    echo "downloaded: $name"
done
