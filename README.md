# go-codex-switch

A command-line tool and native macOS menu-bar app for switching between Codex accounts and monitoring their quota.

Both interfaces use the same Codex authentication and saved-account files, so accounts saved from the CLI are immediately available in Go Codex Bar and vice versa.

## Features

- Save and switch between multiple Codex accounts
- Show session and weekly quota, reset times, and available reset credits
- Switch to the next account or automatically select the best account with **Maxing**
- Restart Codex after switching, with an option to switch without restarting
- Log out while preserving the active account for later use
- Native menu-bar interface with active and recommended account indicators
- Automatically refresh the active account's quota whenever the menu opens
- Refresh and save expired OAuth credentials across all saved accounts

## Requirements

- macOS with `Codex.app` installed
- Go 1.22 or newer for the CLI
- macOS 13 or newer and the Apple Swift toolchain for Go Codex Bar

## CLI installation

Build and install `go-codex-switch` into `/usr/local/bin`:

```bash
make install
```

Use `sudo make install` if `/usr/local/bin` requires administrator permission.

To rebuild or remove the CLI:

```bash
make reinstall
make uninstall
```

## CLI usage

Save the account currently signed in to Codex:

```bash
go-codex-switch save
```

List saved accounts:

```bash
go-codex-switch ls
```

```text
[*] 1. codingmase@gmail.com
[_] 2. jhone@gmail.com
```

Include quota and reset-credit information:

```bash
go-codex-switch ls --usage
```

```text
[*] 1. codingmase@gmail.com | session: 93% left (5h)     | weekly: 99% left (6d 23h) | 3 reset credits (2026-07-20, 2026-07-24, 2026-07-31) | recommended
[_] 2. jhone@gmail.com      | session: 92% left (4h 12m) | weekly: 97% left (6d 8h)  | 0 reset credits                                  | -
```

Switch accounts:

```bash
go-codex-switch load 2
go-codex-switch next
go-codex-switch maxing
```

`load`, `next`, and `maxing` restart Codex after a successful switch. Pass `--no-restart` to any of them to only replace the active authentication file:

```bash
go-codex-switch load 2 --no-restart
go-codex-switch next --no-restart
go-codex-switch maxing --no-restart
```

`maxing` prefers accounts with more than 95% session quota remaining and selects the one with the earliest upcoming reset. If none exceed 95%, it selects the account with the nearest reset.

Log out of Codex while saving the active account:

```bash
go-codex-switch logout
```

## Go Codex Bar

Go Codex Bar provides the same account switching workflow from the macOS menu bar. Its compact header contains **Next**, **Maxing**, manual refresh, and an additional-actions menu.

The account list shows:

- The active account at the top
- Session and weekly quota with reset countdowns
- Available reset credits and their expiry dates
- Active and recommended account badges

Opening the menu automatically refreshes quota for the current active account. The manual refresh button updates every saved account.

The dropdown includes actions to save the current account, refresh expired credentials, restart Codex, open the saved-account directory, log out, and quit. **Refresh Expired** follows Codex's OAuth refresh policy: credentials with a missing or more-than-eight-day-old `last_refresh` value are refreshed and saved. The live authentication file is also updated when the refreshed account is active.

Install and launch the menu-bar app:

```bash
make bar-install
```

It is installed at `~/Applications/Go Codex Bar.app`. To rebuild, reinstall, or remove it:

```bash
make bar-reinstall
make bar-uninstall
```

Uninstalling either interface does not remove saved accounts or Codex authentication.

## Data locations

```text
~/.codex/auth.json                    Active Codex authentication
~/.go-codex-switch/*.auth.json       Saved account authentication
~/Applications/Go Codex Bar.app      Installed menu-bar application
```

Authentication files are written with owner-only permissions (`0600`).

## Development

Run commands from the repository root:

| Target | Purpose |
| --- | --- |
| `make run` | Run the Go CLI from source |
| `make bin` | Build the Go CLI binary |
| `go test ./...` | Run the Go test suite |
| `make bar-run` | Build and run Go Codex Bar |
| `make bar-test` | Verify a debug Swift build |
| `make bar-build` | Build the release Swift executable |
| `make bar-package` | Create the application bundle |
| `make bar-clean` | Remove Swift and packaged-app build artifacts |

The menu-bar app is ad-hoc signed for local use. If macOS blocks a copy built on another machine, rebuild it locally with `make bar-reinstall`.
