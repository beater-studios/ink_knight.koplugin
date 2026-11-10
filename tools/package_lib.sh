# Pattern "package". This file is copied unchanged into every
# plugin as tools/package_lib.sh: change the pattern first, then copy it again.
#
# The steps of tools/package.sh, which sources this file and says what goes in the package:
#   . "$(dirname "$0")/package_lib.sh"
#   package_start <id>            checks the files every package needs and empties dist/
#   package_stage                 a new package with those files
#   package_add <path> ...        files or folders, at the same path inside the package
#   package_copy <source> <dest>  one file at another path inside the package
#   package_zip [zip name]        checks what the code loads, then writes dist/<zip> and its .sha256
# Every package has _meta.lua, main.lua, LICENSE, NOTICE, LICENSE-CONTENT (when there is one), the <id>
# folder and assets/screensaver.png.

package_fail() {
    echo "$*" >&2
    exit 1
}

package_start() {
    [ $# -eq 1 ] || package_fail "Usage: package_start <id>"
    PACKAGE_ID="$1"
    PACKAGE_NAME="$1.koplugin"
    PACKAGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    cd "$PACKAGE_ROOT"
    for file in _meta.lua main.lua LICENSE NOTICE assets/screensaver.png; do
        [ -f "$file" ] || package_fail "$file not found: the package cannot be built without it."
    done
    [ -d "$PACKAGE_ID" ] || package_fail "$PACKAGE_ID/ not found: package_start takes the plugin id."
    PACKAGE_VERSION="$(sed -n 's/.*version *= *"\([^"]*\)".*/\1/p' _meta.lua | head -n 1)"
    [ -n "$PACKAGE_VERSION" ] || package_fail "_meta.lua has no version."
    rm -rf dist
    mkdir -p dist
    PACKAGE_STAGE=""
}

package_stage() {
    [ -n "${PACKAGE_ID:-}" ] || package_fail "package_start must come first."
    rm -rf dist/stage
    PACKAGE_STAGE="dist/stage/$PACKAGE_NAME"
    mkdir -p "$PACKAGE_STAGE"
    set -- _meta.lua main.lua LICENSE NOTICE "$PACKAGE_ID" assets/screensaver.png
    if [ -f LICENSE-CONTENT ]; then
        set -- "$@" LICENSE-CONTENT
    fi
    package_add "$@"
}

package_add() {
    [ -n "${PACKAGE_STAGE:-}" ] || package_fail "package_stage must come first."
    for _pk_path in "$@"; do
        _pk_path="${_pk_path%/}"
        [ -e "$_pk_path" ] || package_fail "$_pk_path not found: the package cannot be built without it."
        _pk_parent="$(dirname "$_pk_path")"
        mkdir -p "$PACKAGE_STAGE/$_pk_parent"
        cp -R "$_pk_path" "$PACKAGE_STAGE/$_pk_parent/"
    done
}

package_copy() {
    [ -n "${PACKAGE_STAGE:-}" ] || package_fail "package_stage must come first."
    [ $# -eq 2 ] || package_fail "Usage: package_copy <source> <destination>"
    [ -f "$1" ] || package_fail "$1 not found: the package cannot be built without it."
    mkdir -p "$PACKAGE_STAGE/$(dirname "$2")"
    cp "$1" "$PACKAGE_STAGE/$2"
}

# The Lua code of the package, without comments that start a line or follow a space ("-- old: /x.lua").
package_lua_code() {
    find "$PACKAGE_STAGE" -name '*.lua' -exec sed -E 's/(^|[[:space:]])--.*$//' {} +
}

# Prints a line for each file the code loads from the plugin that is not in the package. Two forms are
# checked, with single or double quotes, when the first part of the path exists in the plugin root:
# every require("data/i18n") or require "data.i18n" of a line, and paths written after the plugin folder,
# like "/data/i18n.lua", "/assets/icons/" or "/words.txt" (a path with a format marker, like
# "/assets/%s.png", is checked up to its folder).
package_missing_files() {
    package_lua_code | grep -oE "require *\(? *[\"'][^\"']+[\"']" | sed -E "s/^require *\(? *[\"']//; s/[\"']$//" |
        tr . / | LC_ALL=C sort -u | while IFS= read -r _pk_module; do
        _pk_first="${_pk_module%%/*}"
        if [ -e "$_pk_first" ] || [ -e "$_pk_first.lua" ]; then
            if [ ! -f "$PACKAGE_STAGE/$_pk_module.lua" ] && [ ! -f "$PACKAGE_STAGE/$_pk_module/init.lua" ]; then
                echo "$_pk_module.lua is required by the code but is not in the package."
            fi
        fi
    done
    package_lua_code | grep -oE "[\"']/[A-Za-z0-9_.%-][^\"' ]*[\"']" | sed -E "s/^[\"']\///; s/[\"']$//" |
        LC_ALL=C sort -u | while IFS= read -r _pk_path; do
        case "$_pk_path" in
            *%*)
                _pk_path="${_pk_path%%%*}"
                case "$_pk_path" in
                    */*) _pk_path="${_pk_path%/*}/" ;;
                    *) continue ;;
                esac
                ;;
        esac
        _pk_first="${_pk_path%%/*}"
        if [ -n "$_pk_first" ] && [ -e "$_pk_first" ] && [ ! -e "$PACKAGE_STAGE/$_pk_path" ]; then
            echo "$_pk_path is used by the code but is not in the package."
        fi
    done
}

package_check_files() {
    _pk_report="$(package_missing_files)"
    if [ -n "$_pk_report" ]; then
        echo "$_pk_report" >&2
        package_fail "Add the missing files with package_add."
    fi
}

# Files that never go in a package: macOS metadata, editor leftovers and placeholders for empty folders.
package_clean() {
    find dist/stage \( -name '._*' -o -name '.DS_Store' -o -name 'Thumbs.db' -o -name 'desktop.ini' \
        -o -name '.git*' -o -name '*.swp' -o -name '*.swo' -o -name '*~' \) -prune -exec rm -rf {} +
}

# The same files give the same zip, on any machine and at any time: fixed dates and permissions, entries in
# a fixed order and no extra attributes (-X also leaves out the Unix timestamps and owners).
package_write_zip() {
    (
        cd dist/stage
        chmod -R u+rw,go-w,a+rX "$PACKAGE_NAME"
        find "$PACKAGE_NAME" -exec env TZ=UTC touch -t 200001010000 {} +
        find "$PACKAGE_NAME" | LC_ALL=C sort | TZ=UTC zip -qX -@ "../$1"
    )
}

package_zip() {
    [ -n "${PACKAGE_STAGE:-}" ] || package_fail "package_stage must come first."
    _pk_zip="${1:-$PACKAGE_NAME.zip}"
    package_clean
    package_check_files
    package_write_zip "$_pk_zip"
    rm -rf dist/stage
    PACKAGE_STAGE=""
    (cd dist && shasum -a 256 "$_pk_zip" > "$_pk_zip.sha256")
    echo "Package built: dist/$_pk_zip ($PACKAGE_ID $PACKAGE_VERSION)"
}
