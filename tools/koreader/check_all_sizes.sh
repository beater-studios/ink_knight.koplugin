#!/bin/sh
# Pattern "headless". This file is copied unchanged into
# every plugin that has tools/koreader/check_layout.lua, as tools/koreader/check_all_sizes.sh: change the
# pattern first, then copy it again.
#
# Runs a layout check without a window in four Kindle screen sizes, from 600x800 to 1264x1680, and reports
# every size that failed. Usage: tools/koreader/check_all_sizes.sh [script.lua] (tools/koreader/check_layout.lua)
# With OUTPUT_DIR, each size saves its images in OUTPUT_DIR/<width>x<height>.
set -eu
plugin="$(cd "$(dirname "$0")/../.." && pwd)"
# The script and OUTPUT_DIR are relative to the folder it was called from.
if [ $# -ge 1 ]; then
    script="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
else
    script="$plugin/tools/koreader/check_layout.lua"
fi
out=""
if [ -n "${OUTPUT_DIR:-}" ]; then
    mkdir -p "$OUTPUT_DIR"
    out="$(cd "$OUTPUT_DIR" && pwd)"
fi
failed=""
for size in "600 800 167" "758 1024 212" "1072 1448 300" "1264 1680 300"; do
    echo "== $size"
    set -- $size
    status=0
    if [ -n "$out" ]; then
        mkdir -p "$out/${1}x$2"
        OUTPUT_DIR="$out/${1}x$2" sh "$plugin/tools/koreader/run_headless.sh" "$script" "$@" || status=$?
    else
        sh "$plugin/tools/koreader/run_headless.sh" "$script" "$@" || status=$?
    fi
    if [ "$status" -ne 0 ]; then
        failed="$failed [$size]"
    fi
done
if [ -n "$failed" ]; then
    echo "FAILED in:$failed"
    exit 1
fi
echo "all sizes passed"
