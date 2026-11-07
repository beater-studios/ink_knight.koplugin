#!/bin/sh
set -eu
: "${KOREADER_DIR:?Set KOREADER_DIR to the KOReader folder, the one with luajit and reader.lua.}"
if [ $# -lt 1 ]; then
    echo "Usage: tools/koreader/run_headless.sh <script.lua> [width] [height] [dpi]" >&2
    exit 2
fi
repo="$(cd "$(dirname "$0")/../.." && pwd)"
script="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
home="$(mktemp -d)"
trap 'rm -rf "$home"' EXIT
output="${OUTPUT_DIR:-$home/output}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
cd "$KOREADER_DIR"
status=0
SDL_VIDEODRIVER=dummy KO_HOME="$home" PLUGIN_DIR="$repo" OUTPUT_DIR="$output" \
    EMULATE_READER_W="${2:-600}" EMULATE_READER_H="${3:-800}" EMULATE_READER_DPI="${4:-167}" \
    ./luajit "$script" > "$home/log" 2>&1 || status=$?
grep -vE '^(has monolibtic|lib_|ffi\.|Started SDL|  [hw] = |\} --\[\[table|[0-9/: -]*(INFO|DEBUG|WARN)|$)' "$home/log" || true
exit "$status"
