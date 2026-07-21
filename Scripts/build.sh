#!/bin/bash
# SwiftPM's manifest compilation is currently broken on this machine's
# Command Line Tools (libPackageDescription.dylib exports ~2 symbols instead
# of the hundreds it should — likely fixed by installing full Xcode.app).
# Package.swift is kept in the repo for when that's resolved; until then,
# this compiles the sources directly with swiftc.
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p .build-manual
swiftc Sources/nigiri/*.swift -o .build-manual/nigiri
codesign --force --sign - .build-manual/nigiri
echo "built + signed: .build-manual/nigiri"
