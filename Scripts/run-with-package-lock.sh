#!/bin/sh
set -eu

fail() {
    echo "run-with-package-lock.sh: $*" >&2
    exit 1
}

[ "$#" -ge 4 ] || \
    fail "expected build-directory lock-name timeout command [arguments ...]"

BUILD_DIRECTORY=$1
LOCK_NAME=$2
TIMEOUT=$3
COMMAND=$4
shift 4

case "$BUILD_DIRECTORY" in
    /*) ;;
    *) fail "build directory must be absolute" ;;
esac
case "$COMMAND" in
    /*) ;;
    *) fail "command must be absolute" ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
LOCK_SOURCE="$SCRIPT_DIR/peaklight-package-lock.c"
[ -f "$LOCK_SOURCE" ] && [ ! -L "$LOCK_SOURCE" ] || \
    fail "missing safe package-lock source"

LOCK_BUILD_DIRECTORY=$(/usr/bin/mktemp -d /private/tmp/Peaklight-package-lock.XXXXXX) || \
    fail "could not create package-lock build directory"
LOCK_RUNNER="$LOCK_BUILD_DIRECTORY/peaklight-package-lock"

cleanup() {
    exit_status=$?
    trap - 0 HUP INT TERM
    case "$LOCK_BUILD_DIRECTORY" in
        /private/tmp/Peaklight-package-lock.*)
            if ! /bin/rm -rf "$LOCK_BUILD_DIRECTORY"; then
                echo "run-with-package-lock.sh: could not clean $LOCK_BUILD_DIRECTORY" >&2
                if [ "$exit_status" -eq 0 ]; then
                    exit_status=1
                fi
            fi
            ;;
        *)
            echo "run-with-package-lock.sh: refusing unexpected cleanup path $LOCK_BUILD_DIRECTORY" >&2
            exit_status=1
            ;;
    esac
    exit "$exit_status"
}

trap cleanup 0
trap 'exit 1' HUP INT TERM

/usr/bin/xcrun --sdk macosx clang \
    -std=c11 \
    -O2 \
    -Wall \
    -Wextra \
    -Werror \
    "$LOCK_SOURCE" \
    -o "$LOCK_RUNNER"

"$LOCK_RUNNER" \
    "$BUILD_DIRECTORY" \
    "$LOCK_NAME" \
    "$TIMEOUT" \
    "$COMMAND" \
    "$@"
