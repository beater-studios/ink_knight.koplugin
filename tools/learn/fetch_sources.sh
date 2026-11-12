#!/bin/sh
# Downloads the texts of the learn stages from the official Lichess app (lichess-org/mobile, GPL-3.0) at a fixed
# commit and checks them against tools/learn/sources.sha256, so a release always builds the same texts.
set -eu
dest="${1:?usage: fetch_sources.sh <empty folder for the sources>}"
sums="$(cd "$(dirname "$0")" && pwd)/sources.sha256"
mkdir -p "$dest"
if [ -n "$(ls -A "$dest")" ]; then
    echo "the folder must be empty: $dest" >&2
    exit 1
fi
base=https://raw.githubusercontent.com/lichess-org/mobile/a476f69153f3469a019d4b9febe635a0831b59e7/lib/l10n
for name in app_en.arb app_pt_BR.arb app_es.arb; do
    curl -fsSL --max-time 120 -o "$dest/$name" "$base/$name"
    expected="$(awk -v name="$name" '$2 == name { print $1 }' "$sums")"
    if [ "$(shasum -a 256 "$dest/$name" | cut -d' ' -f1)" != "$expected" ]; then
        echo "checksum mismatch: $name (the source changed; update the commit or sources.sha256 on purpose)" >&2
        exit 1
    fi
    echo "downloaded: $name"
done
