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

DEFAULT_SIGNING_IDENTITY="Vibestick Local Code Signing"
SIGNING_IDENTITY="${VIBESTICK_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    if security find-identity -v -p codesigning 2>/dev/null |
        grep -Fq "\"$DEFAULT_SIGNING_IDENTITY\""; then
        SIGNING_IDENTITY="$DEFAULT_SIGNING_IDENTITY"
    else
        SIGNING_IDENTITY="-"
    fi
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP" >/dev/null
    print -u2 \
        "Warning: ad-hoc signing means Accessibility must be granted again after each rebuild."
else
    codesign \
        --force \
        --deep \
        --sign "$SIGNING_IDENTITY" \
        --identifier com.enkelm.vibestick \
        "$APP" >/dev/null
    printf 'Signed with stable identity %s\n' "$SIGNING_IDENTITY"
fi

printf 'Built %s\n' "$APP"
