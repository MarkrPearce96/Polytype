#!/usr/bin/env bash
# Build the menu-bar app and install it to /Applications (its permanent home,
# needed for "Launch at login" to work). Run this yourself in a normal terminal.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Polytype.app"
DEST="/Applications/Polytype.app"

"$ROOT/scripts/build-bar.sh"

echo "==> Installing to $DEST"
killall PolytypeBar 2>/dev/null || true
if rm -rf "$DEST" 2>/dev/null && cp -R "$APP" "$DEST" 2>/dev/null; then
    echo "    installed"
else
    echo "    (needs your password to write to /Applications)"
    sudo rm -rf "$DEST"
    sudo cp -R "$APP" "$DEST"
fi

# Remove the freshly-built copy so it doesn't linger as a second "Polytype"
# in Spotlight/Launchpad — the installed /Applications copy is canonical.
rm -rf "$APP"

echo "==> Launching from /Applications"
open "$DEST"
echo "Done. In the app's Settings you can now enable 'Launch at login'."
