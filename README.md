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
[*] 1. codingmase@gmail.com | session: 58% left, weekly: 87.5% left, reset in: 5d 15h
[_] 2. jhone@gmail.com      | session: 92% left, weekly: 97% left
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

Switch to the next account without restarting Codex:

```bash
go-codex-switch next --no-restart
```

## Development

```bash
make run
make bin
go test ./...
```
