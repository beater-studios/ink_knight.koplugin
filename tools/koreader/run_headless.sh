#!/bin/sh
# Pattern "headless". This file is copied unchanged into
# every plugin as tools/koreader/run_headless.sh: change the pattern first, then copy it again.
#
# Runs a Lua script inside the desktop KOReader, without a window, with a temporary KOReader home.
# The script gets PLUGIN_DIR (the plugin folder) and OUTPUT_DIR (where to save images and reports). Without
# OUTPUT_DIR, the output goes to the temporary home and is deleted at the end. The script output is shown as
# it comes, without KOReader's log lines.
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
# KOReader hides its on-screen keyboard when the computer has a physical one, so a text dialog would look
# roomier here than on a Kindle, where the keyboard covers the lower half of the screen.
printf 'return {\n    ["virtual_keyboard_enabled"] = true,\n}\n' > "$home/settings.reader.lua"
output="${OUTPUT_DIR:-$home/output}"
mkdir -p "$output"
# Absolute before the cd below, so a relative OUTPUT_DIR still means the folder it was called from.
output="$(cd "$output" && pwd)"
cd "$KOREADER_DIR"
# Through a named pipe, so the output is filtered while the script runs and its exit status is kept.
mkfifo "$home/pipe"
grep --line-buffered -vE '^(has monolibtic|lib_|ffi\.|Started SDL|  [hw] = |\} --\[\[table|[0-9/: -]*(INFO|DEBUG|WARN)|$)' \
    < "$home/pipe" &
filter=$!
status=0
# Line buffering, so a script that hangs still shows what it printed so far.
SDL_VIDEODRIVER=dummy KO_HOME="$home" PLUGIN_DIR="$repo" OUTPUT_DIR="$output" \
    EMULATE_READER_W="${2:-600}" EMULATE_READER_H="${3:-800}" EMULATE_READER_DPI="${4:-167}" \
    ./luajit -e 'io.stdout:setvbuf("line")' "$script" > "$home/pipe" 2>&1 || status=$?
wait "$filter" || true
exit "$status"
