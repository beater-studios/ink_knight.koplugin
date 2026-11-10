#!/bin/sh
# Pattern "headless". This file is copied unchanged into
# every plugin as tools/koreader/run_emulator.sh: change the pattern first, then copy it again.
#
# Opens the desktop KOReader in a 600x800 window with this plugin installed, with its own settings in .ko-home
# inside the plugin folder (or in KO_HOME, relative to the folder it was called from). If tools/koreader/prepare_emulator.sh exists, it runs first,
# with KOREADER_DIR, KO_HOME and PLUGIN_DIR set, to create sample data. Restarting KOReader from its menu
# opens it again.
set -eu
: "${KOREADER_DIR:?Set KOREADER_DIR to the KOReader folder, the one with luajit and reader.lua.}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
home="${KO_HOME:-$repo/.ko-home}"
# KOReader only loads plugin folders ending in .koplugin, whatever the folder of the clone is called.
name="$(basename "$repo")"
case "$name" in
    *.koplugin) ;;
    *) name="$name.koplugin" ;;
esac
mkdir -p "$home/plugins" "$home/settings"
# Absolute before the cd below, so a relative KO_HOME still means the folder it was called from.
home="$(cd "$home" && pwd)"
ln -sfn "$repo" "$home/plugins/$name"
# KOReader hides its on-screen keyboard when the computer has a physical one, so a text dialog would look
# roomier here than on a Kindle. Only for new settings: an existing choice stays as it is.
if [ ! -f "$home/settings.reader.lua" ]; then
    printf 'return {\n    ["virtual_keyboard_enabled"] = true,\n}\n' > "$home/settings.reader.lua"
fi
if [ -f "$repo/tools/koreader/prepare_emulator.sh" ]; then
    KOREADER_DIR="$KOREADER_DIR" KO_HOME="$home" PLUGIN_DIR="$repo" sh "$repo/tools/koreader/prepare_emulator.sh"
fi
cd "$KOREADER_DIR"
# KOReader exits with 85 to ask for a restart.
while :; do
    status=0
    env KO_HOME="$home" EMULATE_READER_W=600 EMULATE_READER_H=800 EMULATE_READER_DPI=167 ./luajit reader.lua "$@" || status=$?
    [ "$status" -eq 85 ] || exit "$status"
done
