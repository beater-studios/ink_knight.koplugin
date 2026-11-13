#!/bin/sh
# Downloads the positions with known move counts of scalachess (lichess-org/scalachess, MIT) used by
# tests/perft_spec.lua, with the license of scalachess, at a fixed commit, and checks them against
# tools/perft/sources.sha256. The release compares them with tests/perft.
set -eu
dest="${1:?usage: fetch_sources.sh <empty folder for the sources>}"
sums="$(cd "$(dirname "$0")" && pwd)/sources.sha256"
mkdir -p "$dest"
if [ -n "$(ls -A "$dest")" ]; then
    echo "the folder must be empty: $dest" >&2
    exit 1
fi
base=https://raw.githubusercontent.com/lichess-org/scalachess/fbb8f2c75d25b64cb4c9995d867e46a877e1f418
while read -r expected name; do
    if [ "$name" = LICENSE-scalachess ]; then
        url="$base/LICENSE"
    else
        url="$base/test-kit/src/test/resources/$name"
    fi
    curl -fsSL --retry 3 --max-time 120 -o "$dest/$name" "$url"
    if [ "$(shasum -a 256 "$dest/$name" | cut -d' ' -f1)" != "$expected" ]; then
        echo "checksum mismatch: $name (the source changed; update the commit or sources.sha256 on purpose)" >&2
        exit 1
    fi
done < "$sums"
echo "downloaded: $(wc -l < "$sums" | tr -d ' ') files"
