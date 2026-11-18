#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:-"$source_dir/build"}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
destination="$output_dir/夏威夷果开罐器.app"
if [[ -e "$destination" || -L "$destination" ]]; then
    printf 'The destination already exists: %s\n' "$destination" >&2
    exit 1
fi
sdk="$(xcrun --sdk macosx --show-sdk-path)"
intermediates="$(mktemp -d "${TMPDIR:-/tmp}/archivehere-build.XXXXXX")"
trap 'rm -rf "$intermediates"' EXIT
app="$intermediates/夏威夷果开罐器.app"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
cp "$source_dir/ArchiveHere.icns" "$app/Contents/Resources/ArchiveHere.icns"
for source in ArchiveEngine StreamDecoder; do
    xcrun --sdk macosx clang -isysroot "$sdk" -target arm64-apple-macos12.0 \
        -std=c17 -O2 -Wall -Wextra -Werror -c "$source_dir/$source.c" -o "$intermediates/$source.o"
done
xcrun --sdk macosx swiftc -sdk "$sdk" -target arm64-apple-macos12.0 -swift-version 5 -parse-as-library \
    -module-cache-path "$intermediates/modules" -O -import-objc-header "$source_dir/ArchiveEngine.h" \
    "$source_dir/ArchiveHere.swift" "$intermediates/ArchiveEngine.o" "$intermediates/StreamDecoder.o" -larchive -lcompression \
    -o "$app/Contents/MacOS/ArchiveHere"
codesign --sign - --options runtime --timestamp=none "$app"
codesign --verify --deep --strict "$app"
ditto "$app" "$destination"
printf '%s\n' "$destination"
