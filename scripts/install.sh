#!/usr/bin/env bash
# Install the assembled TypeTranslator.app into ~/Library/Input Methods and
# (re)launch it so macOS registers the input source.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/TypeTranslator.app"
DEST_DIR="$HOME/Library/Input Methods"
DEST="$DEST_DIR/TypeTranslator.app"

if [ ! -d "$APP" ]; then
    echo "No build found. Run scripts/build-app.sh first." >&2
    exit 1
fi

mkdir -p "$DEST_DIR"
killall TypeTranslator 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"

echo "Installed to: $DEST"
echo
echo "Next: System Settings → Keyboard → Input Sources → Edit… → + →"
echo "      English → 'English → 台灣中文' → Add."
