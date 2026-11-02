#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build/ModuleCache
xcrun clang -std=c11 -Wall -Wextra -Werror Tests/ProtocolTests.c -framework IOKit -framework CoreFoundation -o build/protocol-tests
build/protocol-tests
xcrun swiftc -module-cache-path build/ModuleCache Sources/FAT12.swift Tests/FAT12Tests.swift -o build/fat12-tests
build/fat12-tests
if [ -f Tests/CardSessionTests.swift ]; then
  xcrun clang -Wall -Wextra -Werror -mmacosx-version-min=12.0 -c Sources/APFHID.c -o build/APFHID.o
  xcrun swiftc -module-cache-path build/ModuleCache -import-objc-header Sources/APFHID.h \
    Sources/FAT12.swift Sources/CardSession.swift Tests/CardSessionTests.swift build/APFHID.o \
    -framework IOKit -o build/session-tests
  build/session-tests
fi
if [ -f Tests/FastUploadTests.swift ]; then
  xcrun swiftc -module-cache-path build/ModuleCache -import-objc-header Sources/APFHID.h \
    Sources/FAT12.swift Sources/CardSession.swift Tests/FastUploadTests.swift build/APFHID.o \
    -framework IOKit -o build/fast-upload-tests
  build/fast-upload-tests
fi
