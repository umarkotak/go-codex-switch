package main

import (
	"errors"
	"fmt"
	"os"
	"strconv"
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
		if len(args) != 1 {
			return fmt.Errorf("ls does not accept arguments\n\n%w", usageError())
		}

		accounts, err := ListSavedAuthAccountsFromHome()
		if err != nil {
			return err
		}

		for i, account := range accounts {
			if account.IsActive {
				fmt.Printf("%d. %s *\n", i+1, account.Email)
				continue
			}

			fmt.Printf("%d. %s\n", i+1, account.Email)
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
	noRestart := false

	for _, arg := range args {
		switch arg {
		case "--no-restart":
			noRestart = true
		default:
			return false, fmt.Errorf("unknown next argument %q\n\n%w", arg, usageError())
		}
	}

	return noRestart, nil
}

func usage() string {
	return "usage: go-codex-switch <command>\n\ncommands:\n  save                  save ~/.codex/auth.json as ~/.go-codex-switch/<email>.auth.json\n  ls                    list saved auth files\n  load <n>              load a saved auth file by number from ls\n  load <n> --no-restart load without restarting Codex\n  next                  load the next saved auth account\n  next --no-restart     load next without restarting Codex"
}
