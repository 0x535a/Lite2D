#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ ! -d Companion/node_modules/esbuild ]; then
  npm ci --prefix Companion --ignore-scripts --no-audit --no-fund
fi
cmake -S . -B build/app-lite2d -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build build/app-lite2d --parallel 6
