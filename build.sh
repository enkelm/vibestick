#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
cd "$ROOT"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/Vibestick.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/Vibestick" "$APP/Contents/MacOS/Vibestick"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" >/dev/null

printf 'Built %s\n' "$APP"
