#!/bin/zsh
set -euo pipefail

APP_NAME="Go Codex Bar"
TARGET_APP="$HOME/Applications/$APP_NAME.app"

osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
rm -rf "$TARGET_APP"

echo "Uninstalled $TARGET_APP"
