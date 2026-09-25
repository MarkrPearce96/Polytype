#!/usr/bin/env bash
# Build the app and package it into a drag-to-install .dmg for distribution.
# The result (dist/Polytype-<version>.dmg) can be attached to a GitHub
# Release — no build tools needed on the machine that installs it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Polytype.app"
DIST="$ROOT/dist"

"$ROOT/scripts/build-bar.sh"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.1)"
DMG="$DIST/Polytype-$VERSION.dmg"
STAGING="$(mktemp -d)"

echo "==> Staging disk image contents"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/INSTALL.txt" <<'TXT'
Polytype — install

1. Drag "Polytype.app" onto the Applications folder (shown here).

2. FIRST launch only: because this app isn't notarized by Apple, macOS will
   block a normal double-click. Instead:
     • Right-click (or Control-click) "Polytype" in Applications
     • Choose "Open", then "Open" again in the dialog.
   After this one time, it opens normally forever.

   (Alternatively, run this once in Terminal:
      xattr -dr com.apple.quarantine "/Applications/Polytype.app" )

3. Grant Accessibility permission when asked (System Settings ▸ Privacy &
   Security ▸ Accessibility ▸ enable "Polytype"). This lets the hotkey
   read and replace your selected text.

4. Open the app's menu-bar icon (globe) ▸ Settings, and paste your Google Cloud
   Translation API key.

Then press the hotkey (default Option-Command-T) in any app to translate the
text you just typed.
TXT

echo "==> Building $DMG"
mkdir -p "$DIST"
rm -f "$DMG"
hdiutil create -volname "Polytype" -srcfolder "$STAGING" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "==> Done: $DMG"
ls -lh "$DMG"
