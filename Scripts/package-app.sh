#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
PRODUCT_NAME="Peaklight"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
DIST_DIR="$ROOT_DIR/.build/dist"
APP_PATH="$DIST_DIR/$PRODUCT_NAME.app"
ICON_SOURCE="$ROOT_DIR/icon.png"
ICONSET_PATH="$DIST_DIR/$PRODUCT_NAME.iconset"
ICON_PATH="$APP_PATH/Contents/Resources/$PRODUCT_NAME.icns"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
INSTALL_PATH="$INSTALL_DIR/$PRODUCT_NAME.app"

cd "$ROOT_DIR"

swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

cp "$BUILD_DIR/$PRODUCT_NAME" "$APP_PATH/Contents/MacOS/$PRODUCT_NAME"
chmod 755 "$APP_PATH/Contents/MacOS/$PRODUCT_NAME"

if [ -f "$ICON_SOURCE" ]; then
    rm -rf "$ICONSET_PATH"
    mkdir -p "$ICONSET_PATH"

    sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_PATH/icon_16x16.png" >/dev/null
    sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_PATH/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_PATH/icon_32x32.png" >/dev/null
    sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_PATH/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_PATH/icon_128x128.png" >/dev/null
    sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_PATH/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_PATH/icon_256x256.png" >/dev/null
    sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_PATH/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_PATH/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "$ICON_SOURCE" --out "$ICONSET_PATH/icon_512x512@2x.png" >/dev/null

    iconutil -c icns "$ICONSET_PATH" -o "$ICON_PATH"
fi

cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Peaklight</string>
    <key>CFBundleIconFile</key>
    <string>Peaklight</string>
    <key>CFBundleIdentifier</key>
    <string>dev.peaklight.Peaklight</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Peaklight</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_PATH" >/dev/null
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_PATH"
cp -R "$APP_PATH" "$INSTALL_PATH"

if command -v xattr >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true
fi

echo "$INSTALL_PATH"
