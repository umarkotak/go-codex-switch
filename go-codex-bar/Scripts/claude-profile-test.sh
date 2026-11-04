#!/bin/bash
# Experiment: run a separate Claude desktop profile per account via Electron's --user-data-dir.
#
#   claude-profile-test.sh launch <name>   open Claude with its own profile (creates it if new)
#   claude-profile-test.sh running         list running Claude windows and which profile each uses
#   claude-profile-test.sh path <name>     print the profile folder
#
# Your normal Claude data folder is never touched: profiles live in ~/.go-codex-switch/claude-profiles/.
set -euo pipefail

APP="${CLAUDE_APP:-/Applications/Claude.app}"
PROFILES="${CLAUDE_PROFILES_DIR:-$HOME/.go-codex-switch/claude-profiles}"

die() { echo "error: $*" >&2; exit 1; }
valid_name() { [[ "$1" =~ ^[A-Za-z0-9._@+-]+$ ]] || die "name may only contain letters, digits and . _ @ + -"; }

# Reads `ps` lines on stdin: "<pid> <command...>". Prints "<pid> <profile or (default)>" for main Claude processes.
parse_running() {
    local pid rest profile
    while read -r pid rest; do
        [[ "$rest" == *"/Contents/MacOS/Claude"* && "$rest" != *"Helper"* ]] || continue
        if [[ "$rest" =~ --user-data-dir=([^[:space:]]+) ]]; then profile="${BASH_REMATCH[1]}"; else profile="(default)"; fi
        echo "$pid $profile"
    done
}

cmd="${1:-}"; name="${2:-}"
case "$cmd" in
    launch)
        [[ -n "$name" ]] || die "usage: launch <name>"
        valid_name "$name"
        [[ -d "$APP" ]] || die "Claude not found at $APP"
        dir="$PROFILES/$name"
        mkdir -p "$dir"; chmod 700 "$PROFILES" "$dir"
        echo "launching Claude with profile: $dir"
        open -n -a "$APP" --args "--user-data-dir=$dir"
        echo "Sign in with the EMAIL CODE (don't click the emailed link), and quit other Claude windows first if you use Google sign-in."
        ;;
    running)
        ps -axo pid=,command= | parse_running || true
        ;;
    path)
        [[ -n "$name" ]] || die "usage: path <name>"
        valid_name "$name"; echo "$PROFILES/$name"
        ;;
    parse-test) # internal: pipe sample ps output into the parser
        parse_running
        ;;
    *)
        sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1
        ;;
esac
