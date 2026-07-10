#!/usr/bin/env bash
# Build the menu-bar + global-hotkey app (the free delivery path) and assemble it
# into a runnable macOS .app bundle. No input-source registration, no
# notarization — a normal app you run yourself.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_NAME="TypeTranslatorBar"
APP="$ROOT/build/Type Translator.app"

echo "==> Building executable (release)…"
swift build -c release --package-path "$ROOT/TypeTranslatorApp" --product "$BIN_NAME"
BIN="$ROOT/TypeTranslatorApp/.build/release/$BIN_NAME"

echo "==> Assembling bundle at ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# App icon (Finder/Dock). The menu-bar icon uses the system "globe" template
# symbol at runtime, so no menu-bar image is bundled.
cp "$ROOT/TypeTranslatorApp/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>TypeTranslatorBar</string>
    <key>CFBundleIdentifier</key><string>com.typetranslator.bar</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Type Translator</string>
    <key>CFBundleDisplayName</key><string>Type Translator</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.5</string>
    <key>CFBundleVersion</key><string>5</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign with a stable real identity so the Accessibility grant persists across
# rebuilds (TCC keys on the code-signing designated requirement). Falls back to
# ad-hoc, which still runs but will re-prompt for Accessibility after each build.
SIGN_ID="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -Eo '"(Developer ID Application|Apple Development)[^"]*"' | head -1 | tr -d '"')"
fi
if [ -n "$SIGN_ID" ]; then
    echo "==> Signing with: $SIGN_ID"
    codesign --force --deep --sign "$SIGN_ID" --timestamp=none "$APP"
else
    echo "==> WARNING: no signing identity — ad-hoc (Accessibility will re-prompt each build)"
    codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --verbose "$APP" >/dev/null 2>&1 && echo "    signature OK"
echo "==> Built: $APP"
