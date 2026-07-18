# go-codex-switch

A small CLI for saving and switching between Codex accounts.

## Install

```bash
make install
```

If `/usr/local/bin` needs admin permission:

```bash
sudo make install
```

Uninstall:

```bash
make uninstall
```

## Usage

Save the current Codex account:

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

List with usage:

```bash
go-codex-switch ls --usage
```

```text
[*] 1. codingmase@gmail.com | session: 93% left (5h)     | weekly: 99% left (6d 23h) | 3 reset credits (2026-07-20, 2026-07-24, 2026-07-31)
[_] 2. jhone@gmail.com      | session: 92% left (4h 12m) | weekly: 97% left (6d 8h)  | 0 reset credits
```

Load an account by number:

```bash
go-codex-switch load 2
```

Load without restarting Codex:

```bash
go-codex-switch load 2 --no-restart
```

Switch to the next saved account:

```bash
go-codex-switch next
```

Switch to the account with the best available usage:

```bash
go-codex-switch maxing
```

`maxing` prefers accounts with more than 95% remaining, choosing the one with the earliest upcoming reset. If none exceed 95%, it chooses the account with the nearest reset.

Switch to the next account without restarting Codex:

```bash
go-codex-switch next --no-restart
```

Logout from Codex:

```bash
go-codex-switch logout
```

## Development

```bash
make run
make bin
go test ./...
```
