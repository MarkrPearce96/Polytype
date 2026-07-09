#!/usr/bin/env bash
# Build the TypeTranslator executable and assemble it into a loadable macOS
# input-method .app bundle (no Xcode required).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_NAME="TypeTranslator"
APP="$ROOT/build/$BIN_NAME.app"

echo "==> Building executable (release)…"
swift build -c release --package-path "$ROOT/TypeTranslatorApp"
BIN="$ROOT/TypeTranslatorApp/.build/release/$BIN_NAME"

echo "==> Assembling bundle at ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>TypeTranslator</string>
    <key>CFBundleIdentifier</key><string>com.typetranslator.inputmethod</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>TypeTranslator</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <!-- Top-level keys the input-source scanner requires. Both working system
         input methods (AinuIM, TamilIM) carry these at the TOP level — burying
         them inside ComponentInputModeDict makes the source fail to register. -->
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsSuddenTermination</key><true/>
    <key>TISInputSourceID</key><string>com.typetranslator.inputmethod</string>
    <key>TISIntendedLanguage</key><string>en</string>
    <key>tsInputMethodCharacterRepertoireKey</key>
    <array><string>Latn</string></array>
    <key>InputMethodConnectionName</key><string>com.typetranslator.inputmethod_Connection</string>
    <key>InputMethodServerControllerClass</key><string>TranslatorInputController</string>
    <key>ComponentInputModeDict</key>
    <dict>
        <key>tsInputModeListKey</key>
        <dict>
            <key>com.typetranslator.inputmethod.EnglishToZhTW</key>
            <dict>
                <key>TISInputSourceID</key><string>com.typetranslator.inputmethod.EnglishToZhTW</string>
                <key>TISIntendedLanguage</key><string>en</string>
                <key>tsInputModeAlternateMenuTitleKey</key><string>English → 台灣中文</string>
                <key>tsInputModeCharacterRepertoireKey</key>
                <array><string>Latn</string></array>
                <key>tsInputModeIsVisibleKey</key><true/>
                <key>tsInputModeDefaultStateKey</key><true/>
                <key>tsInputModePrimaryInScriptKey</key><true/>
                <key>tsInputModeScriptKey</key><string>smUnicodeScript</string>
                <key>tsInputModeKeyEquivalentKey</key><string></string>
                <key>tsInputModeKeyEquivalentModifiersKey</key><integer>0</integer>
            </dict>
        </dict>
        <key>tsVisibleInputModeOrderedArrayKey</key>
        <array><string>com.typetranslator.inputmethod.EnglishToZhTW</string></array>
    </dict>
</dict>
</plist>
PLIST

# macOS 26 (Tahoe) will silently ignore an ad-hoc-signed input method during the
# login-scan that populates the input-source database. Sign with a real identity
# (Apple Development / Developer ID) so the bundle gets a Team Identifier.
SIGN_ID="${CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -Eo '"(Developer ID Application|Apple Development)[^"]*"' | head -1 | tr -d '"')"
fi

if [ -n "$SIGN_ID" ]; then
    echo "==> Code signing with: $SIGN_ID"
    codesign --force --deep --sign "$SIGN_ID" --timestamp=none "$APP"
else
    echo "==> WARNING: no real signing identity found — falling back to ad-hoc"
    echo "    (a new input method may NOT register on macOS 15+/26 when ad-hoc signed)"
    codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --verbose "$APP" >/dev/null 2>&1 && echo "    signature verifies"
echo "    identity: $(codesign -dvvv "$APP" 2>&1 | grep -E 'TeamIdentifier|Authority=' | head -2 | tr '\n' ' ')"

echo "==> Built: $APP"
