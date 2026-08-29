#!/bin/sh
set -eu
export COPYFILE_DISABLE=1

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
PRODUCT_NAME="Peaklight"
INSTALL_HELPER_NAME="PeaklightInstallHelper"
BUNDLE_IDENTIFIER="dev.peaklight.Peaklight"
APP_VERSION="1.0.0"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
DIST_DIR="$ROOT_DIR/.build/dist"
APP_PATH="$DIST_DIR/$PRODUCT_NAME.app"
ICON_SOURCE="$ROOT_DIR/icon.png"
ICONSET_PATH="$DIST_DIR/$PRODUCT_NAME.iconset"
ICON_PATH="$APP_PATH/Contents/Resources/$PRODUCT_NAME.icns"
BUILD_ONLY="${PEAKLIGHT_BUILD_ONLY:-0}"
PACKAGE_LOCK_HELD="${PEAKLIGHT_PACKAGE_LOCK_HELD:-0}"
PACKAGE_LOCK_NAME="peaklight-package.lock"
PACKAGE_LOCK_RUNNER="$ROOT_DIR/Scripts/run-with-package-lock.sh"
STAGING_DIR=""
PUBLISH_ATTEMPTED=0
PUBLISH_SUCCEEDED=0

fail() {
    echo "package-app.sh: $*" >&2
    exit 1
}

case "$BUILD_ONLY" in
    0|1) ;;
    *) fail "PEAKLIGHT_BUILD_ONLY must be 0 or 1" ;;
esac

case "$PACKAGE_LOCK_HELD" in
    0|1) ;;
    *) fail "PEAKLIGHT_PACKAGE_LOCK_HELD must be 0 or 1" ;;
esac

if [ "$BUILD_ONLY" -eq 0 ] && [ "${INSTALL_DIR+x}" = x ]; then
    fail "INSTALL_DIR overrides are not supported; the local target is ~/Applications/Peaklight.app"
fi
INSTALL_DIR=""

mkdir -p "$ROOT_DIR/.build"
if [ "$PACKAGE_LOCK_HELD" -eq 0 ]; then
    /bin/sh "$PACKAGE_LOCK_RUNNER" \
        "$ROOT_DIR/.build" \
        "$PACKAGE_LOCK_NAME" \
        120 \
        "$ROOT_DIR/Scripts/package-app.sh" \
        "$@"
    exit $?
else
    /usr/bin/lockf -s -t 0 9 || fail "inherited packaging lock is unavailable"
fi

cleanup() {
    exit_status=$?
    trap - 0 HUP INT TERM

    if [ "$PUBLISH_ATTEMPTED" -eq 1 ] && [ "$PUBLISH_SUCCEEDED" -eq 0 ]; then
        echo "package-app.sh: install transaction failed; preserved recovery data at $STAGING_DIR" >&2
    elif [ "$PUBLISH_SUCCEEDED" -eq 1 ] && [ "$exit_status" -ne 0 ]; then
        echo "package-app.sh: install committed but a later step failed; prior app remains at $STAGING_DIR" >&2
    elif [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
        case "$STAGING_DIR" in
            "$INSTALL_DIR"/.Peaklight-install.*)
                if ! rm -rf "$STAGING_DIR"; then
                    echo "package-app.sh: could not clean transaction directory $STAGING_DIR" >&2
                    if [ "$exit_status" -eq 0 ]; then
                        exit_status=1
                    fi
                fi
                ;;
            *) echo "package-app.sh: refusing to clean unexpected staging path $STAGING_DIR" >&2 ;;
        esac
    fi

    exit "$exit_status"
}

trap cleanup 0
trap 'exit 1' HUP INT TERM

bundle_identifier() {
    /usr/bin/plutil -extract CFBundleIdentifier raw -o - "$1" 2>/dev/null
}

verify_bundle() {
    bundle_path=$1
    bundle_plist="$bundle_path/Contents/Info.plist"
    bundle_executable="$bundle_path/Contents/MacOS/$PRODUCT_NAME"

    [ -d "$bundle_path" ] && [ ! -L "$bundle_path" ] || \
        fail "staged app is not a safe bundle directory: $bundle_path"
    [ -f "$bundle_plist" ] && [ ! -L "$bundle_plist" ] || \
        fail "staged app has no safe Info.plist"
    /usr/bin/plutil -lint "$bundle_plist" >/dev/null || fail "staged Info.plist is invalid"
    staged_identifier="$(bundle_identifier "$bundle_plist")" || \
        fail "staged app has no readable bundle identifier"
    [ "$staged_identifier" = "$BUNDLE_IDENTIFIER" ] || \
        fail "staged app has unexpected bundle identifier $staged_identifier"
    [ -f "$bundle_executable" ] && [ -x "$bundle_executable" ] && [ ! -L "$bundle_executable" ] || \
        fail "staged app has no safe executable"

    if command -v codesign >/dev/null 2>&1; then
        codesign --verify --deep --strict "$bundle_path" >/dev/null 2>&1 || \
            fail "staged app failed code-signature verification"
    fi
}

assert_install_target() {
    [ "$INSTALL_PATH" = "$EXPECTED_INSTALL_PATH" ] || \
        fail "refusing unexpected install target: $INSTALL_PATH"

    if [ -L "$INSTALL_DIR" ]; then
        fail "refusing symlinked install directory: $INSTALL_DIR"
    fi

    if [ -e "$INSTALL_DIR" ]; then
        [ -d "$INSTALL_DIR" ] || fail "install directory is not a directory: $INSTALL_DIR"
        resolved_install_dir="$(cd "$INSTALL_DIR" && pwd -P)"
        [ "$resolved_install_dir" = "$INSTALL_DIR" ] || \
            fail "refusing an install directory with symlinked path components"
    fi
}

validate_existing_install() {
    assert_install_target

    if [ ! -e "$INSTALL_PATH" ] && [ ! -L "$INSTALL_PATH" ]; then
        return
    fi

    [ ! -L "$INSTALL_PATH" ] || fail "refusing symlinked install target: $INSTALL_PATH"
    [ -d "$INSTALL_PATH" ] || fail "existing install target is not an app bundle directory"

    existing_plist="$INSTALL_PATH/Contents/Info.plist"
    [ -f "$existing_plist" ] && [ ! -L "$existing_plist" ] || \
        fail "existing app has no safe Info.plist"
    existing_identifier="$(bundle_identifier "$existing_plist")" || \
        fail "existing app has no readable bundle identifier"
    [ "$existing_identifier" = "$BUNDLE_IDENTIFIER" ] || \
        fail "refusing to replace bundle identifier $existing_identifier"
}

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

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
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
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Peaklight</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>100</string>
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

verify_bundle "$APP_PATH"

if [ "$BUILD_ONLY" -eq 1 ]; then
    echo "$APP_PATH"
    exit 0
fi

swift build -c "$CONFIGURATION" --product "$INSTALL_HELPER_NAME"
INSTALL_HELPER_PATH="$BUILD_DIR/$INSTALL_HELPER_NAME"
[ -f "$INSTALL_HELPER_PATH" ] && [ -x "$INSTALL_HELPER_PATH" ] || \
    fail "install helper was not built"

INSTALL_DIR="$("$INSTALL_HELPER_PATH" --print-install-directory)" || \
    fail "could not determine the canonical per-user install directory"
case "$INSTALL_DIR" in
    /*) ;;
    *) fail "install helper returned a non-absolute install directory" ;;
esac
INSTALL_PATH="$INSTALL_DIR/$PRODUCT_NAME.app"
EXPECTED_INSTALL_PATH="$INSTALL_DIR/$PRODUCT_NAME.app"

assert_install_target
mkdir -p "$INSTALL_DIR"
assert_install_target
validate_existing_install

STAGING_DIR="$(mktemp -d "$INSTALL_DIR/.Peaklight-install.XXXXXX")"
STAGING_NAME=${STAGING_DIR##*/}
STAGED_APP_PATH="$STAGING_DIR/$PRODUCT_NAME.app"

if command -v ditto >/dev/null 2>&1; then
    ditto --norsrc --noextattr "$APP_PATH" "$STAGED_APP_PATH"
else
    cp -R "$APP_PATH" "$STAGED_APP_PATH"
fi

if command -v xattr >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$STAGED_APP_PATH" 2>/dev/null || true
fi

verify_bundle "$STAGED_APP_PATH"
validate_existing_install

PUBLISH_ATTEMPTED=1
"$INSTALL_HELPER_PATH" "$STAGING_NAME" >/dev/null
PUBLISH_SUCCEEDED=1

echo "$INSTALL_PATH"
