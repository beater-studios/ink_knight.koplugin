#!/bin/sh
# Builds the plugin zips in dist/, with their checksums: the usual one, with 1000 puzzles of the package for each
# level (5000 in all), and two larger ones, with 4000 and 10000 for each level (20000 and 50000). The repository has
# 10000 for each level, and each zip keeps the first ones, which are the same in all three. Each carries the Stockfish
# built for the Kindle, in bin/.
set -eu
. "$(dirname "$0")/package_lib.sh"
package_start ink_knight
build() {
    package_stage
    package_add assets bin
    luajit tools/puzzles/trim.lua "$PACKAGE_STAGE/ink_knight/data/puzzles" "$1"
    package_zip "$2"
}
build 1000 ink_knight.koplugin.zip
build 4000 ink_knight-20000-puzzles.koplugin.zip
build 10000 ink_knight-50000-puzzles.koplugin.zip
