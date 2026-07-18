package main

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return usageError()
	}

	switch args[0] {
	case "save":
		if len(args) != 1 {
			return fmt.Errorf("save does not accept arguments\n\n%w", usageError())
		}

		result, err := SaveAuthFromHome()
		if err != nil {
			return err
		}

		fmt.Printf("saved %s to %s\n", result.Email, result.DestinationPath)
		return nil
	case "ls":
		showUsage, err := parseLsArgs(args[1:])
		if err != nil {
			return err
		}

		var accounts []SavedAuthAccount
		if showUsage {
			accounts, err = ListSavedAuthAccountsWithUsageFromHome()
		} else {
			accounts, err = ListSavedAuthAccountsFromHome()
		}
		if err != nil {
			return err
		}

		for _, row := range formatSavedAuthAccountRows(accounts, showUsage, time.Now()) {
			fmt.Println(row)
		}
		return nil
	case "load":
		index, noRestart, err := parseLoadArgs(args[1:])
		if err != nil {
			return err
		}

		result, err := LoadSavedAuthFromHome(index)
		if err != nil {
			return err
		}

		if result.AlreadyActive {
			fmt.Printf("%s is already active\n", result.Email)
			return nil
		}

		fmt.Printf("loaded %s\n", result.Email)
		if !noRestart {
			if err := RestartCodexApp(); err != nil {
				return err
			}
		}
		return nil
	case "next":
		noRestart, err := parseNextArgs(args[1:])
		if err != nil {
			return err
		}

		result, err := NextSavedAuthFromHome()
		if err != nil {
			return err
		}

		if !result.Loaded {
			fmt.Println("nothing to switch")
			return nil
		}

		fmt.Printf("loaded %s\n", result.Email)
		if !noRestart {
			if err := RestartCodexApp(); err != nil {
				return err
			}
		}
		return nil
	case "maxing":
		noRestart, err := parseMaxingArgs(args[1:])
		if err != nil {
			return err
		}

		result, err := MaxingSavedAuthFromHome()
		if err != nil {
			return err
		}
		if result.AlreadyActive {
			fmt.Printf("%s is already optimal\n", result.Email)
			return nil
		}

		fmt.Printf("loaded %s\n", result.Email)
		if !noRestart {
			if err := RestartCodexApp(); err != nil {
				return err
			}
		}
		return nil
	case "logout":
		if len(args) != 1 {
			return fmt.Errorf("logout does not accept arguments\n\n%w", usageError())
		}

		result, err := LogoutFromHome()
		if err != nil {
			return err
		}

		fmt.Printf("logged out %s\n", result.Email)
		if err := RestartCodexApp(); err != nil {
			return err
		}
		return nil
	case "help", "-h", "--help":
		fmt.Println(usage())
		return nil
	default:
		return fmt.Errorf("unknown command %q\n\n%w", args[0], usageError())
	}
}

func usageError() error {
	return errors.New(usage())
}

func parseLsArgs(args []string) (bool, error) {
	showUsage := false

	for _, arg := range args {
		switch arg {
		case "--usage":
			showUsage = true
		default:
			return false, fmt.Errorf("unknown ls argument %q\n\n%w", arg, usageError())
		}
	}

	return showUsage, nil
}

func maxSavedAuthEmailWidth(accounts []SavedAuthAccount) int {
	maxWidth := 0
	for _, account := range accounts {
		if len(account.Email) > maxWidth {
			maxWidth = len(account.Email)
		}
	}

	return maxWidth
}

func maxSavedAuthSessionUsageWidth(accounts []SavedAuthAccount, now time.Time) int {
	maxWidth := 0
	for _, account := range accounts {
		parts := FormatCodexUsagePartsAt(account.Usage, account.UsageError, now)
		if len(parts) > 0 && len(parts[0]) > maxWidth {
			maxWidth = len(parts[0])
		}
	}

	return maxWidth
}

func formatSavedAuthAccountRows(accounts []SavedAuthAccount, showUsage bool, now time.Time) []string {
	emailWidth := maxSavedAuthEmailWidth(accounts)
	sessionWidth := maxSavedAuthSessionUsageWidth(accounts, now)
	rows := make([]string, 0, len(accounts))
	for i, account := range accounts {
		rows = append(rows, formatSavedAuthAccountRow(
			i+1,
			account,
			emailWidth,
			sessionWidth,
			showUsage,
			now))
	}
	if !showUsage {
		return rows
	}

	recommendedIndex, err := selectMaxingAccountIndex(accounts, now)
	if err != nil {
		return rows
	}
	rowWidth := 0
	for _, row := range rows {
		if len(row) > rowWidth {
			rowWidth = len(row)
		}
	}
	for i, row := range rows {
		label := "-"
		if i == recommendedIndex {
			label = "recommended"
		}
		rows[i] = fmt.Sprintf("%-*s | %s", rowWidth, row, label)
	}

	return rows
}

func formatSavedAuthAccountRow(
	index int,
	account SavedAuthAccount,
	emailWidth int,
	sessionWidth int,
	showUsage bool,
	now time.Time) string {
	activeMarker := "_"
	if account.IsActive {
		activeMarker = "*"
	}

	if !showUsage {
		return fmt.Sprintf("[%s] %d. %s", activeMarker, index, account.Email)
	}

	line := fmt.Sprintf("[%s] %d. %-*s", activeMarker, index, emailWidth, account.Email)
	parts := FormatCodexUsagePartsAt(account.Usage, account.UsageError, now)
	if resetCredits := FormatCodexResetCreditsAt(account.ResetCredits, now); resetCredits != "" {
		parts = append(parts, resetCredits)
	}
	if len(parts) == 0 {
		return line
	}
	if len(parts) == 1 {
		return line + " | " + parts[0]
	}
	if sessionWidth == 0 {
		return line + " | " + strings.Join(parts, " | ")
	}

	return line + fmt.Sprintf(" | %-*s | %s", sessionWidth, parts[0], strings.Join(parts[1:], " | "))
}

func parseLoadArgs(args []string) (int, bool, error) {
	if len(args) == 0 {
		return 0, false, fmt.Errorf("load requires an account number\n\n%w", usageError())
	}

	var (
		indexText string
		noRestart bool
	)

	for _, arg := range args {
		switch arg {
		case "--no-restart":
			noRestart = true
		default:
			if indexText != "" {
				return 0, false, fmt.Errorf("load accepts only one account number\n\n%w", usageError())
			}

			indexText = arg
		}
	}

	if indexText == "" {
		return 0, false, fmt.Errorf("load requires an account number\n\n%w", usageError())
	}

	index, err := strconv.Atoi(indexText)
	if err != nil {
		return 0, false, fmt.Errorf("invalid account number %q", indexText)
	}

	return index, noRestart, nil
}

func parseNextArgs(args []string) (bool, error) {
	return parseNoRestartArgs("next", args)
}

func parseMaxingArgs(args []string) (bool, error) {
	return parseNoRestartArgs("maxing", args)
}

func parseNoRestartArgs(command string, args []string) (bool, error) {
	noRestart := false

	for _, arg := range args {
		switch arg {
		case "--no-restart":
			noRestart = true
		default:
			return false, fmt.Errorf("unknown %s argument %q\n\n%w", command, arg, usageError())
		}
	}

	return noRestart, nil
}

func usage() string {
	return "usage: go-codex-switch <command>\n\ncommands:\n  save                     save ~/.codex/auth.json as ~/.go-codex-switch/<email>.auth.json\n  ls                       list saved auth files\n  ls --usage               list saved auth files with Codex usage\n  load <n>                 load a saved auth file by number from ls\n  load <n> --no-restart    load without restarting Codex\n  next                     load the next saved auth account\n  next --no-restart        load next without restarting Codex\n  maxing                   load the account with the best available usage\n  maxing --no-restart      load the best account without restarting Codex\n  logout                   save current auth, delete ~/.codex/auth.json, and restart Codex"
}
