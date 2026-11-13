#!/bin/sh
# Every check that runs without KOReader. The CI runs tools/check.sh; the release runs tools/check.sh release,
# which also downloads the list of openings, the texts of Learn chess and the practice lessons, builds them again and
# fails if they differ from the repository, and downloads the piece sets and fails if they differ from ink_knight/pieces. The puzzles in the package come from a database with no version, so they are not built again.
set -eu
cd "$(dirname "$0")/.."
for spec in tests/*_spec.lua; do
    luajit "$spec"
done
luajit tools/check_texts.lua s strings
if [ "${1:-}" = release ]; then
    sources="$(mktemp -d)"
    trap 'rm -rf "$sources"' EXIT
    mkdir "$sources/openings" "$sources/learn" "$sources/practice" "$sources/pieces"
    sh tools/openings/fetch_sources.sh "$sources/openings"
    luajit tools/openings/build.lua "$sources/openings"
    sh tools/learn/fetch_sources.sh "$sources/learn"
    python3 -I tools/learn/build_texts.py "$sources/learn"
    sh tools/practice/fetch_sources.sh "$sources/practice"
    luajit tools/practice/build.lua "$sources/practice"
    sh tools/pieces/fetch_sources.sh "$sources/pieces"
    if ! diff -rq -x .DS_Store -x '._*' "$sources/pieces" ink_knight/pieces; then
        echo "ink_knight/pieces/ differs from the piece sets of the sources." >&2
        exit 1
    fi
    # Also catches new files, which git diff leaves out.
    if [ -n "$(git status --porcelain -- ink_knight/data)" ]; then
        git status --short -- ink_knight/data
        echo "ink_knight/data/ differs from what the sources generate." >&2
        exit 1
    fi
fi
sh tools/package.sh
