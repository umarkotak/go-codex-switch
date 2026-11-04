#!/bin/bash
# Experiment: can Claude.app switch accounts by swapping its saved login files?
#
#   claude-desktop-swap-test.sh backup <name> [--full]   save the current login state
#   claude-desktop-swap-test.sh restore <name> [--full]  put a saved state back
#   claude-desktop-swap-test.sh list                     show saved states
#
# Default swaps only the cookie database. --full also swaps Local Storage, Session Storage and
# IndexedDB (use it if a cookie-only swap still shows the old account). Claude must be quit for
# backup and restore. Restore always saves the current state first, so it can be undone.
set -euo pipefail

APP_DIR="${CLAUDE_APP_DIR:-$HOME/Library/Application Support/Claude}"
STORE="${CLAUDE_SWAP_STORE:-$HOME/.go-codex-switch/claude-desktop-test}"

COOKIE_FILES=("Network/Cookies" "Network/Cookies-journal" "Network/Cookies-wal" "Network/Cookies-shm"
              "Cookies" "Cookies-journal" "Cookies-wal" "Cookies-shm")
STORAGE_DIRS=("Local Storage" "Session Storage" "IndexedDB")

die() { echo "error: $*" >&2; exit 1; }

require_quit() {
    [[ "${SKIP_RUNNING_CHECK:-0}" == "1" ]] && return 0
    if pgrep -x "Claude" >/dev/null 2>&1 || pgrep -f "Claude.app/Contents" >/dev/null 2>&1; then
        die "Claude is running. Quit it first (Cmd+Q, and check the menu bar), then retry."
    fi
}

valid_name() { [[ "$1" =~ ^[A-Za-z0-9._@+-]+$ ]] || die "name may only contain letters, digits and . _ @ + -"; }

save_state() { # save_state <dest-dir> <full:0|1>
    local dest="$1" full="$2"
    [[ -d "$APP_DIR" ]] || die "Claude data folder not found: $APP_DIR"
    mkdir -p "$dest"
    chmod 700 "$STORE" "$dest"
    local saved=0 rel
    for rel in "${COOKIE_FILES[@]}"; do
        if [[ -f "$APP_DIR/$rel" ]]; then
            mkdir -p "$dest/$(dirname "$rel")"
            cp -p "$APP_DIR/$rel" "$dest/$rel"
            saved=$((saved + 1))
        fi
    done
    [[ $saved -gt 0 ]] || die "no cookie database found under $APP_DIR"
    if [[ "$full" == "1" ]]; then
        for rel in "${STORAGE_DIRS[@]}"; do
            if [[ -d "$APP_DIR/$rel" ]]; then
                mkdir -p "$dest/$rel"
                rsync -a --checksum --delete "$APP_DIR/$rel/" "$dest/$rel/"
            fi
        done
    fi
    echo "$full" > "$dest/.full"
    echo "saved $saved cookie file(s) to $dest (full=$full)"
}

restore_state() { # restore_state <src-dir> <full:0|1>
    local src="$1" full="$2" rel
    [[ -d "$src" ]] || die "saved state not found: $src"
    # Stale sidecar files from the other account would corrupt the swapped database.
    for rel in "${COOKIE_FILES[@]}"; do rm -f "$APP_DIR/$rel"; done
    for rel in "${COOKIE_FILES[@]}"; do
        if [[ -f "$src/$rel" ]]; then
            mkdir -p "$APP_DIR/$(dirname "$rel")"
            cp -p "$src/$rel" "$APP_DIR/$rel"
        fi
    done
    if [[ "$full" == "1" ]]; then
        for rel in "${STORAGE_DIRS[@]}"; do
            if [[ -d "$src/$rel" ]]; then
                mkdir -p "$APP_DIR/$rel"
                rsync -a --checksum --delete "$src/$rel/" "$APP_DIR/$rel/"
            fi
        done
    fi
}

cmd="${1:-}"; shift || true
full=0
args=()
for a in "$@"; do
    if [[ "$a" == "--full" ]]; then full=1; else args+=("$a"); fi
done

case "$cmd" in
    backup)
        [[ ${#args[@]} -eq 1 ]] || die "usage: backup <name> [--full]"
        valid_name "${args[0]}"; require_quit
        mkdir -p "$STORE"
        [[ ! -e "$STORE/${args[0]}" ]] || die "'${args[0]}' already exists in $STORE (pick another name or delete it)"
        save_state "$STORE/${args[0]}" "$full"
        ;;
    restore)
        [[ ${#args[@]} -eq 1 ]] || die "usage: restore <name> [--full]"
        valid_name "${args[0]}"; require_quit
        [[ -d "$STORE/${args[0]}" ]] || die "no saved state named '${args[0]}'"
        if [[ "$full" == "1" && "$(cat "$STORE/${args[0]}/.full" 2>/dev/null || echo 0)" != "1" ]]; then
            die "'${args[0]}' was saved without --full, so it has no storage folders to restore"
        fi
        mkdir -p "$STORE"
        undo="_before-restore-$(date +%Y%m%d-%H%M%S)-$$"
        save_state "$STORE/$undo" "$full"
        restore_state "$STORE/${args[0]}" "$full"
        echo "restored '${args[0]}'. Previous state saved as '$undo'. Now open Claude and check which account it shows."
        ;;
    list)
        [[ -d "$STORE" ]] && ls -1 "$STORE" || echo "(nothing saved yet)"
        ;;
    *)
        sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
