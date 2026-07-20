# Go Codex Bar

A native macOS menu-bar companion for switching between saved Codex accounts and monitoring their usage.

## Features

- Live session and weekly usage with reset countdowns
- Automatic active-account quota refresh whenever the menu opens
- Available reset-credit count and individual expiry dates
- Active and recommended account badges
- One-click account switching
- **Next** and usage-aware **Maxing** selection
- Save the currently signed-in Codex account
- Refresh and save credentials older than eight days across all saved accounts
- Optional Codex restart after switching (enabled by default)
- Restart Codex, log out, refresh, and open the saved-account folder
- Uses the same `~/.codex/auth.json` and `~/.go-codex-switch/*.auth.json` files as `go-codex-switch`

`Maxing` uses the same policy as the CLI: prefer accounts with more than 95% remaining, choosing the earliest upcoming reset; otherwise choose the nearest upcoming reset.

## Requirements

- macOS 13 or newer
- Apple Swift toolchain (Xcode Command Line Tools or Xcode)
- Codex installed as `Codex.app`

## Install

From the repository root:

```bash
make bar-install
```

This builds an optimized, ad-hoc-signed application, installs it at:

```text
~/Applications/Go Codex Bar.app
```

and launches it. Look for the bolt icon on the right side of the macOS menu bar.

## Update or reinstall

After pulling or editing the latest source:

```bash
make bar-reinstall
```

This quits the running app, removes the installed copy, rebuilds the latest source, installs it, and relaunches it. Saved Codex accounts and preferences are not removed.

## Uninstall

```bash
make bar-uninstall
```

This quits and removes the application. It intentionally preserves:

```text
~/.go-codex-switch/
~/.codex/
```

so uninstalling the menu-bar app cannot delete saved accounts or Codex authentication.

## Development

```bash
make bar-run
make bar-test
make bar-package
```

`make bar-test` performs a debug compile verification. The included build wrapper selects the SDK compatible with the installed Swift compiler and keeps compiler caches inside the project.

If macOS blocks the locally built app after it has been copied between machines, build it locally with `make bar-reinstall`. The package is ad-hoc signed and is intended for personal/local installation.
