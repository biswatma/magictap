#!/bin/bash
# Builds MagicTap.app, and a distributable DMG unless --no-dmg is passed.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MagicTap"
BUNDLE_ID="com.biswa.magictap"
VERSION="1.0.0"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# ---------------------------------------------------------------- icon
echo "==> icon"
ICONSET="$BUILD_DIR/$APP_NAME.iconset"
rm -rf "$ICONSET"
if swiftc -O -framework AppKit -o "$BUILD_DIR/make-icon" app/tools/make-icon.swift 2>/dev/null \
   && "$BUILD_DIR/make-icon" "$ICONSET" >/dev/null \
   && iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/$APP_NAME.icns" 2>/dev/null; then
    echo "    generated $APP_NAME.icns"
    ICON_KEY="<key>CFBundleIconFile</key><string>$APP_NAME</string>"
else
    echo "    icon generation failed; shipping without a custom icon"
    ICON_KEY=""
fi

# ---------------------------------------------------------------- binary
echo "==> compiling"
# arm64 only, and an explicit deployment target: the default would target the
# building machine's macOS and silently produce a binary that crashes on older
# systems rather than declining to launch. Intel is not a loss here — those Macs
# have no sensor to read.
swiftc -O -target arm64-apple-macos14.0 \
    -framework IOKit -framework AppKit -framework SwiftUI \
    -framework ServiceManagement -framework CoreGraphics -framework Combine \
    -framework ScreenCaptureKit -framework CoreWLAN -framework IOBluetooth \
    -o "$CONTENTS/MacOS/$APP_NAME" \
    src/HIDMotion.swift src/TapDetector.swift src/Gesture.swift src/InputActivity.swift src/Calibration.swift \
    app/Support.swift app/Actions.swift app/ActionExecutor.swift app/Screenshot.swift \
    app/CalibrationSession.swift \
    app/TapEngine.swift app/SetupWindow.swift \
    app/MenuBar.swift app/main.swift

# ---------------------------------------------------------------- bundle
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    $ICON_KEY
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MagicTap</string>
</dict>
</plist>
PLIST

echo "APPL????" > "$CONTENTS/PkgInfo"

# Ad-hoc signature. Enough for local use and for TCC to track an identity, but
# note that an ad-hoc signature changes whenever the binary does, so macOS may
# treat a rebuilt app as a new one and drop its Screen Recording grant.
echo "==> signing (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>&1 | sed 's/^/    /' || true

echo "==> built $APP"

# ---------------------------------------------------------------- dmg
if [[ "${1:-}" == "--no-dmg" ]]; then
    exit 0
fi

echo "==> dmg"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Read Me.txt" <<TXT
MagicTap $VERSION

Drag MagicTap to Applications, then launch it.

MagicTap is not notarized by Apple, so macOS blocks the first launch.
To open it:

  1. Double-click MagicTap. macOS will refuse to open it. This step is
     required - the override in step 2 only appears after a blocked attempt.
  2. Open System Settings > Privacy & Security, scroll down to Security,
     and click "Open Anyway" next to MagicTap, then confirm.

Doing it once is enough. macOS 14 also accepted a Control-click > Open, but
macOS 15 removed that shortcut for apps it cannot verify.

Prefer the terminal? This clears the quarantine flag instead:

  xattr -dr com.apple.quarantine /Applications/MagicTap.app

MagicTap runs in the menu bar (look for the tap icon near Wi-Fi and battery).
The setup window opens on first launch and walks through permissions.

Screenshots need Screen Recording permission. Grant it in the setup window,
then quit and reopen MagicTap - macOS only applies the change to a fresh launch.

Take your hands off the keyboard before tapping. Taps that land while you are
typing are ignored on purpose: keystrokes are impacts on the same case the
sensor reads, and two of them look exactly like a double tap.

Requires macOS 14 or later, and an Apple silicon MacBook from the 2021 MacBook
Pro / 2022 MacBook Air redesigns or later. Those are the models with the motion sensor MagicTap reads.
Intel Macs, the M1 MacBook Air and the M1 13-inch MacBook Pro are not supported.
TXT

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" \
    | sed 's/^/    /'
rm -rf "$STAGE"
echo "==> built $DMG"
