#!/bin/sh
# Builds Stockfish 11 for the Kindle (armhf, static) from its source at a fixed commit, inside a Debian container fixed
# by its digest, with Debian's cross compiler as it was on a fixed date (snapshot.debian.org), so the same bytes come
# out later too, and checks the source and the binary against tools/stockfish/sources.sha256.
# Usage: sh tools/stockfish/build.sh <empty folder>; the binary comes out as <folder>/stockfish-armhf. Needs Docker.
set -eu
dest="${1:?usage: build.sh <empty folder>}"
here="$(cd "$(dirname "$0")" && pwd)"
sums="$here/sources.sha256"
COMMIT=c3483fa9a7d7c0ffa9fcc32b467ca844cfb63790
IMAGE=debian@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc
SNAPSHOT=20261113T180000Z
mkdir -p "$dest"
if [ -n "$(ls -A "$dest")" ]; then
    echo "the folder must be empty: $dest" >&2
    exit 1
fi
dest="$(cd "$dest" && pwd)"
check() {
    expected="$(awk -v name="$2" '$2 == name { print $1 }' "$sums")"
    if [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" != "$expected" ]; then
        echo "checksum mismatch: $2" >&2
        exit 1
    fi
}
curl -fsSL --max-time 120 -o "$dest/stockfish-src.tar.gz" "https://github.com/official-stockfish/Stockfish/archive/$COMMIT.tar.gz"
check "$dest/stockfish-src.tar.gz" stockfish-src.tar.gz
mkdir "$dest/src"
tar xzf "$dest/stockfish-src.tar.gz" -C "$dest/src" --strip-components=1
docker run --rm --platform linux/arm64 -e SNAPSHOT="$SNAPSHOT" -v "$dest":/work "$IMAGE" sh -c '
set -e
rm -f /etc/apt/sources.list.d/debian.sources
for suite in bookworm bookworm-updates; do
    echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/$SNAPSHOT $suite main" >> /etc/apt/sources.list
done
echo "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/$SNAPSHOT bookworm-security main" >> /etc/apt/sources.list
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends g++-arm-linux-gnueabihf make >/dev/null 2>&1
cd /work/src/src
make -j4 build ARCH=armv7 COMP=gcc COMPCXX=arm-linux-gnueabihf-g++ \
    EXTRACXXFLAGS="-march=armv7-a -mfpu=neon -mfloat-abi=hard -mthumb" EXTRALDFLAGS="-static" > /work/build.log 2>&1
arm-linux-gnueabihf-strip -o /work/stockfish-armhf stockfish
'
check "$dest/stockfish-armhf" stockfish-armhf
echo "built: $dest/stockfish-armhf"
