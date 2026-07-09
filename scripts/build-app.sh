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

echo "==> Ad-hoc code signing…"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose "$APP" >/dev/null 2>&1 && echo "    signature OK"

echo "==> Built: $APP"
