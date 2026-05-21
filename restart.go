package main

import (
	"fmt"
	"os"
	"os/exec"
	"time"
)

const appName = "Codex"

func RestartCodexApp() error {
	fmt.Println("Closing Codex...")

	if err := quitApp(); err != nil {
		fmt.Println("Graceful quit failed, trying force quit...")
		_ = forceQuitApp()
	}

	time.Sleep(2 * time.Second)

	fmt.Println("Starting Codex...")

	if err := openApp(); err != nil {
		return fmt.Errorf("failed to open Codex: %w", err)
	}

	fmt.Println("Codex restarted successfully.")
	return nil
}

func runCommand(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func quitApp() error {
	script := fmt.Sprintf(`quit app "%s"`, appName)
	return runCommand("osascript", "-e", script)
}

func forceQuitApp() error {
	return runCommand("pkill", "-x", appName)
}

func openApp() error {
	return runCommand("open", "-a", appName)
}
