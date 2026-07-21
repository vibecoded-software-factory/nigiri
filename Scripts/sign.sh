#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
BIN=".build/$CONFIG/nigiri"

if [ ! -f "$BIN" ]; then
  echo "$BIN does not exist - run 'swift build' (or 'swift build -c release') first" >&2
  exit 1
fi

codesign --force --sign - "$BIN"
echo "signed (ad-hoc, stable identity): $BIN"
