#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
CACHE_DIR="$PROJECT_DIR/.cache"
DEVELOPER_DIR=$(xcode-select -p)

# SwiftUI property wrappers are implemented as compiler macros in current Swift
# toolchains. The Command Line Tools package ships the SwiftUI interface but not
# its macro plugin, so Swift packages that use SwiftUI must be built with full
# Xcode rather than the standalone Command Line Tools installation.
if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    cat >&2 <<'EOF'
Go Codex Bar requires the full Xcode toolchain.

The active developer directory is Apple Command Line Tools, which does not
include SwiftUIMacros required by SwiftUI. Install Xcode, then select it:

  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -runFirstLaunch
EOF
    exit 1
fi

mkdir -p "$CACHE_DIR/clang" "$CACHE_DIR/swiftpm"

export SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_DIR/clang"
export XDG_CACHE_HOME="$CACHE_DIR"

if [[ "${1:-}" == run ]]; then
    export GO_CODEX_SWITCH_HELPER="$CACHE_DIR/go-codex-switch"
    (cd "$PROJECT_DIR/.." && go build -o "$GO_CODEX_SWITCH_HELPER" .)
fi

exec swift "$@"
