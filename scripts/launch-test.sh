#!/bin/bash
# Builds this checkout as "B-Side Test" (own bundle id, defaults and data dir)
# and opens it next to the real B-Side, which is never touched.
set -euo pipefail

cd "$(dirname "$0")/.."

export BSIDE_APP_NAME="B-Side Test"
export BSIDE_BUNDLE_ID="dev.mabeck.bside.test"
export BSIDE_DIST_DIR="dist-test"

./scripts/bundle.sh

# Quit a test copy still running an older build, or `open` would just focus it.
TEST_BINARY="$BSIDE_DIST_DIR/$BSIDE_APP_NAME.app/Contents/MacOS/BSide"
if pgrep -f "$TEST_BINARY" >/dev/null; then
    osascript -e "tell application id \"$BSIDE_BUNDLE_ID\" to quit" || true
    while pgrep -f "$TEST_BINARY" >/dev/null; do sleep 0.2; done
fi

open "$BSIDE_DIST_DIR/$BSIDE_APP_NAME.app"
