#!/bin/bash
# Launches a bundled app, checks it stays up and migrates its database, then quits it.
# Meant for CI runners; locally, pass a side-by-side copy so the real app's data is untouched.
set -euo pipefail

APP_DIR="${1:?usage: $0 path/to/App.app [seconds]}"
SETTLE_SECONDS="${2:-20}"

INFO_PLIST="$APP_DIR/Contents/Info.plist"
SUPPORT_NAME="$(/usr/libexec/PlistBuddy -c "Print :BSideAppSupportName" "$INFO_PLIST")"
DB_PATH="$HOME/Library/Application Support/$SUPPORT_NAME/db.sqlite"
LOG_PATH="$(mktemp -t bside-smoke)"

codesign --verify --strict "$APP_DIR"

"$APP_DIR/Contents/MacOS/BSide" >"$LOG_PATH" 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT

for _ in $(seq "$SETTLE_SECONDS"); do
    sleep 1
    if ! kill -0 "$PID" 2>/dev/null; then
        wait "$PID" && status=0 || status=$?
        echo "error: app exited during startup (status $status)" >&2
        cat "$LOG_PATH" >&2
        exit 1
    fi
done

if [ ! -f "$DB_PATH" ]; then
    echo "error: no database at $DB_PATH" >&2
    cat "$LOG_PATH" >&2
    exit 1
fi
MIGRATIONS="$(sqlite3 "$DB_PATH" "SELECT count(*) FROM grdb_migrations")"
if [ "$MIGRATIONS" -eq 0 ]; then
    echo "error: database has no applied migrations" >&2
    exit 1
fi

echo "Smoke test passed: alive after ${SETTLE_SECONDS}s, $MIGRATIONS migrations applied"
