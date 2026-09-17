#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
"$ROOT/build.sh"
exec "$ROOT/Vibestick.app/Contents/MacOS/Vibestick" "$@"
