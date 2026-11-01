#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
cmake -S . -B build/app -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build build/app --parallel 6
