#!/bin/sh
set -eu
export COPYFILE_DISABLE=1

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCT_NAME="Peaklight"
APP_VERSION="1.0.0"
DIST_DIR="$ROOT_DIR/.build/dist"
PAYLOAD_ROOT="$DIST_DIR/pkg-root"
APPLICATIONS_DIR="$PAYLOAD_ROOT/Applications"
PKG_PATH="$DIST_DIR/$PRODUCT_NAME-$APP_VERSION.pkg"
PACKAGE_LOCK_HELD="${PEAKLIGHT_PACKAGE_LOCK_HELD:-0}"
PACKAGE_LOCK_NAME="peaklight-package.lock"
PACKAGE_LOCK_RUNNER="$ROOT_DIR/Scripts/run-with-package-lock.sh"

mkdir -p "$ROOT_DIR/.build"
if [ "$PACKAGE_LOCK_HELD" -eq 0 ]; then
    /bin/sh "$PACKAGE_LOCK_RUNNER" \
        "$ROOT_DIR/.build" \
        "$PACKAGE_LOCK_NAME" \
        120 \
        "$ROOT_DIR/Scripts/package-pkg.sh" \
        "$@"
    exit $?
else
    /usr/bin/lockf -s -t 0 9 || {
        echo "package-pkg.sh: inherited packaging lock is unavailable" >&2
        exit 1
    }
fi

cd "$ROOT_DIR"

rm -rf "$PAYLOAD_ROOT"
mkdir -p "$APPLICATIONS_DIR"

PEAKLIGHT_BUILD_ONLY=1 \
PEAKLIGHT_PACKAGE_LOCK_HELD=1 \
    "$ROOT_DIR/Scripts/package-app.sh" >/dev/null
if command -v ditto >/dev/null 2>&1; then
    ditto --norsrc --noextattr "$DIST_DIR/$PRODUCT_NAME.app" "$APPLICATIONS_DIR/$PRODUCT_NAME.app"
else
    cp -R "$DIST_DIR/$PRODUCT_NAME.app" "$APPLICATIONS_DIR/$PRODUCT_NAME.app"
fi
if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APPLICATIONS_DIR/$PRODUCT_NAME.app"
fi
find "$PAYLOAD_ROOT" -name '._*' -delete

rm -f "$PKG_PATH"
pkgbuild \
    --root "$PAYLOAD_ROOT" \
    --identifier "dev.peaklight.Peaklight" \
    --version "$APP_VERSION" \
    --install-location "/" \
    "$PKG_PATH" >/dev/null

echo "$PKG_PATH"
