# go-codex-switch

A tiny CLI for saving and switching between Codex auth sessions.

`go-codex-switch` stores copies of your Codex auth file from `~/.codex/auth.json` in `~/.go-codex-switch`, using the account email from the auth token as the filename.

For example:

```text
~/.go-codex-switch/codingmase@gmail.com.auth.json
~/.go-codex-switch/jhone@gmail.com.auth.json
```

## Install

Build the binary:

```bash
make bin
```

Optionally move it somewhere on your `PATH`:

```bash
make install
```

To remove it later:

```bash
make uninstall
```

## Usage

```bash
go-codex-switch <command>
```

Available commands:

```text
save
ls
load <number>
load <number> --no-restart
next
next --no-restart
```

## Save Current Account

Save the currently active Codex auth session:

```bash
go-codex-switch save
```

This reads:

```text
~/.codex/auth.json
```

Then it extracts the account email from the `id_token` without verifying the JWT signature, creates `~/.go-codex-switch` if needed, and writes:

```text
~/.go-codex-switch/<email>.auth.json
```

If `~/.codex/auth.json` does not exist, the command prints:

```text
please login to codex first
```

## List Saved Accounts

List saved auth sessions:

```bash
go-codex-switch ls
```

Example output:

```text
1. codingmase@gmail.com
2. jhone@gmail.com *
```

The trailing `*` marks the account currently active in `~/.codex/auth.json`.

If `~/.codex/auth.json` does not exist, saved accounts are still listed, but no account is marked active.

## Load An Account

Load a saved account by the number shown in `ls`:

```bash
go-codex-switch load 1
```

Before switching, `go-codex-switch` saves the current active auth session so the latest token state is preserved. Then it replaces:

```text
~/.codex/auth.json
```

with:

```text
~/.go-codex-switch/<selected-email>.auth.json
```

If the selected account is already active, nothing changes.

By default, Codex is restarted after a successful switch:

```text
Closing Codex...
Starting Codex...
Codex restarted successfully.
```

To switch without restarting Codex:

```bash
go-codex-switch load 1 --no-restart
```

This also works:

```bash
go-codex-switch load --no-restart 1
```

## Load The Next Account

Rotate to the next saved account:

```bash
go-codex-switch next
```

If the active account is account `1`, this loads account `2`. If the active account is the last saved account, it wraps back to account `1`.

If `~/.codex/auth.json` does not exist, `next` loads account `1`.

If there is only one saved account, nothing changes.

Like `load`, `next` restarts Codex after a successful switch by default.

To rotate without restarting Codex:

```bash
go-codex-switch next --no-restart
```

## Data Locations

Active Codex auth:

```text
~/.codex/auth.json
```

Saved auth sessions:

```text
~/.go-codex-switch
```

## Development

Run tests:

```bash
go test ./...
```

Build:

```bash
make bin
```

## Notes

This tool copies local auth files. Treat files in `~/.go-codex-switch` with the same care as `~/.codex/auth.json`.

The email is read from the JWT payload without verifying the token, because the token is only used to name and match local auth files.
