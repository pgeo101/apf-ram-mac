#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build/ModuleCache "APF RAM.app/Contents/MacOS" "APF RAM.app/Contents/Resources"
xcrun clang -Wall -Wextra -Werror -target arm64-apple-macos12.0 -c Sources/APFHID.c -o build/APFHID.o
xcrun swiftc -module-cache-path build/ModuleCache -target arm64-apple-macos12.0 -O \
  -import-objc-header Sources/APFHID.h Sources/FAT12.swift Sources/CardSession.swift Sources/App.swift \
  build/APFHID.o -framework AppKit -framework IOKit -o "APF RAM.app/Contents/MacOS/APFRAM"
cp Info.plist "APF RAM.app/Contents/Info.plist"
cp LICENSE "APF RAM.app/Contents/Resources/LICENSE"
codesign --force --sign - "APF RAM.app"
printf 'Built: %s/APF RAM.app\n' "$PWD"
