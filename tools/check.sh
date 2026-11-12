#!/bin/sh
# Every check that runs without KOReader. The CI runs tools/check.sh; the release runs tools/check.sh release,
# which also downloads the list of openings and the texts of Learn chess, builds them again and fails if they differ
# from the repository. The puzzles in the package come from a database with no version, so they are not built again.
set -eu
cd "$(dirname "$0")/.."
for spec in tests/*_spec.lua; do
    luajit "$spec"
done
luajit tools/check_texts.lua s strings
if [ "${1:-}" = release ]; then
    sources="$(mktemp -d)"
    trap 'rm -rf "$sources"' EXIT
    mkdir "$sources/openings" "$sources/learn"
    sh tools/openings/fetch_sources.sh "$sources/openings"
    luajit tools/openings/build.lua "$sources/openings"
    sh tools/learn/fetch_sources.sh "$sources/learn"
    python3 -I tools/learn/build_texts.py "$sources/learn"
    # Also catches new files, which git diff leaves out.
    if [ -n "$(git status --porcelain -- ink_knight/data)" ]; then
        git status --short -- ink_knight/data
        echo "ink_knight/data/ differs from what the sources generate." >&2
        exit 1
    fi
fi
sh tools/package.sh
