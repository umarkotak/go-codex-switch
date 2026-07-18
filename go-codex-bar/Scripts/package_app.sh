#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_NAME="Go Codex Bar"
APP_DIR="$PROJECT_DIR/dist/$APP_NAME.app"
BIN_DIR=$(cd "$PROJECT_DIR" && ./Scripts/swift.sh build -c release --show-bin-path --disable-sandbox)

cd "$PROJECT_DIR"
./Scripts/swift.sh build -c release --disable-sandbox

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/GoCodexBar" "$APP_DIR/Contents/MacOS/GoCodexBar"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod 755 "$APP_DIR/Contents/MacOS/GoCodexBar"
codesign --force --deep --sign - "$APP_DIR"

echo "Packaged $APP_DIR"
