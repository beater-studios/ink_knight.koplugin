#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
name=ink_knight.koplugin
for required in LICENSE NOTICE; do
    if [ ! -f "$required" ]; then
        echo "$required not found: the package cannot be built without it." >&2
        exit 1
    fi
done
rm -rf dist
mkdir -p "dist/stage/$name"
cp -R _meta.lua main.lua LICENSE NOTICE ink_knight "dist/stage/$name/"
find dist/stage \( -name '._*' -o -name '.DS_Store' \) -delete
(cd dist/stage && zip -qrX "../$name.zip" "$name")
rm -rf dist/stage
(cd dist && shasum -a 256 "$name.zip" > "$name.zip.sha256")
echo "Package built: dist/$name.zip"
