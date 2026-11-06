package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

const codexBundleID = "com.openai.codex"

func RestartCodexApp(syncProjects bool) error {
	running, err := codexIsRunning()
	if err != nil {
		return err
	}
	if running {
		fmt.Println("Closing Codex...")
		if err := runCommand("osascript", "-e", `with timeout of 10 seconds
tell application id "`+codexBundleID+`" to quit
end timeout`); err != nil {
			return fmt.Errorf("quit Codex: %w", err)
		}
		deadline := time.Now().Add(5 * time.Second)
		for running {
			if time.Now().After(deadline) {
				return errors.New("Codex did not exit; quit it manually and run sync-projects")
			}
			time.Sleep(100 * time.Millisecond)
			running, err = codexIsRunning()
			if err != nil {
				return err
			}
		}
	}

	var syncErr error
	if syncProjects {
		syncErr = syncProjectsForLaunch()
	}
	fmt.Println("Starting Codex...")
	if err := runCommand("open", "-b", codexBundleID); err != nil {
		return errors.Join(syncErr, fmt.Errorf("failed to open Codex: %w", err))
	}
	return syncErr
}

func syncProjectsForLaunch() error {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	count, err := syncLocalProjects(homeDir)
	if err != nil {
		return fmt.Errorf("sync local Codex projects: %w", err)
	}
	if count > 0 {
		fmt.Printf("Synced %d local projects to the incoming account.\n", count)
	}
	return nil
}

func codexIsRunning() (bool, error) {
	out, err := exec.Command("osascript", "-e", `application id "`+codexBundleID+`" is running`).Output()
	if err != nil {
		return false, fmt.Errorf("check whether Codex is running: %w", err)
	}
	return strings.TrimSpace(string(out)) == "true", nil
}

func runCommand(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
