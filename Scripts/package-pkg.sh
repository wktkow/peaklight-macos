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

cd "$ROOT_DIR"

rm -rf "$PAYLOAD_ROOT"
mkdir -p "$APPLICATIONS_DIR"

INSTALL_DIR="$APPLICATIONS_DIR" "$ROOT_DIR/Scripts/package-app.sh" >/dev/null
if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APPLICATIONS_DIR/$PRODUCT_NAME.app"
fi
find "$PAYLOAD_ROOT" -name '._*' -delete

pkgbuild \
    --root "$PAYLOAD_ROOT" \
    --identifier "dev.peaklight.Peaklight" \
    --version "$APP_VERSION" \
    --install-location "/" \
    "$PKG_PATH" >/dev/null

echo "$PKG_PATH"
