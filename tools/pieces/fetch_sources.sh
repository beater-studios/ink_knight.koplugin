#!/bin/sh
# Downloads the piece sets of the plugin from the Lichess source (lichess-org/lila, public/piece, where their authors
# and licenses are listed in COPYING.md) at a fixed commit, and the license of chessnut from its author's repository,
# and checks each file against tools/pieces/sources.sha256. The release compares them with ink_knight/pieces.
set -eu
dest="${1:?usage: fetch_sources.sh <empty folder for the sources>}"
sums="$(cd "$(dirname "$0")" && pwd)/sources.sha256"
mkdir -p "$dest"
if [ -n "$(ls -A "$dest")" ]; then
    echo "the folder must be empty: $dest" >&2
    exit 1
fi
lila=https://raw.githubusercontent.com/lichess-org/lila/8f16c305d51d888efd09bcd56de6c9c06041a75b/public/piece
chessnut=https://raw.githubusercontent.com/LexLuengas/chessnut-pieces/2b8eaf14a31edad7e9deb53b1473e1d4857868a9
while read -r expected name; do
    mkdir -p "$dest/$(dirname "$name")"
    if [ "$name" = chessnut/LICENSE.txt ]; then
        url="$chessnut/LICENSE.txt"
    else
        url="$lila/$name"
    fi
    curl -fsSL --retry 3 --max-time 120 -o "$dest/$name" "$url"
    if [ "$(shasum -a 256 "$dest/$name" | cut -d' ' -f1)" != "$expected" ]; then
        echo "checksum mismatch: $name (the source changed; update the commit or sources.sha256 on purpose)" >&2
        exit 1
    fi
done < "$sums"
echo "downloaded: $(wc -l < "$sums" | tr -d ' ') files"
