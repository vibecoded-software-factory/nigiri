#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
BIN=".build/$CONFIG/nigiri"

if [ ! -f "$BIN" ]; then
  echo "no existe $BIN — corré 'swift build' (o 'swift build -c release') antes" >&2
  exit 1
fi

codesign --force --sign - "$BIN"
echo "firmado (ad-hoc, identidad estable): $BIN"
