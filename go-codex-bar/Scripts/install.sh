#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_NAME="Go Codex Bar"
SOURCE_APP="$PROJECT_DIR/dist/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"

osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
mkdir -p "$INSTALL_DIR"
rm -rf "$TARGET_APP"
cp -R "$SOURCE_APP" "$TARGET_APP"
open "$TARGET_APP"

echo "Installed and launched $TARGET_APP"
