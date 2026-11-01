#!/bin/sh
# Generate a reproducible native Xcode project from the same source manifest.
set -eu
cd "$(dirname "$0")/.."
cmake -S . -B build/xcode -G Xcode -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_POLICY_VERSION_MINIMUM=3.5
printf '%s\n' 'Generated: build/xcode/Lite2D.xcodeproj' \
  'Build: xcodebuild -project build/xcode/Lite2D.xcodeproj -scheme Lite2D -configuration Release CODE_SIGNING_ALLOWED=NO build'
