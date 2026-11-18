#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:-"$source_dir/build"}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
destination="$output_dir/安装夏威夷果开罐器.app"
if [[ -e "$destination" || -L "$destination" ]]; then
    printf 'The destination already exists: %s\n' "$destination" >&2
    exit 1
fi

sdk="$(xcrun --sdk macosx --show-sdk-path)"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/archivehere-launcher.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
app="$temporary/安装夏威夷果开罐器.app"
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources" "$temporary/extractor"
"$source_dir/build.sh" "$temporary/extractor"

/usr/bin/ditto "$temporary/extractor/夏威夷果开罐器.app" "$resources/夏威夷果开罐器.app"
/bin/cp "$source_dir/ArchiveHere.icns" "$resources/ArchiveHere.icns"
/usr/bin/install -m 755 "$source_dir/设置默认解压程序.command" "$resources/设置默认解压程序.command"
/bin/cp "$source_dir/Launcher/Info.plist" "$app/Contents/Info.plist"

xcrun --sdk macosx clang -isysroot "$sdk" -target arm64-apple-macos12.0 \
    -std=c17 -O2 -Wall -Wextra -Werror -c "$source_dir/Launcher/InstallerCopy.c" -o "$temporary/InstallerCopy.o"
xcrun --sdk macosx swiftc -sdk "$sdk" -target arm64-apple-macos12.0 -swift-version 5 -parse-as-library \
    -module-cache-path "$temporary/modules" -O -import-objc-header "$source_dir/Launcher/InstallerCopy.h" \
    "$source_dir/Launcher/Installer.swift" "$temporary/InstallerCopy.o" \
    -o "$app/Contents/MacOS/ArchiveHereInstaller"

/usr/bin/codesign --sign - --options runtime --timestamp=none "$app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/codesign --verify --deep --strict "$resources/夏威夷果开罐器.app"
/usr/bin/ditto "$app" "$destination"
printf '%s\n' "$destination"
