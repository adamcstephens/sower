package main

import (
	"bufio"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"sync"
	"time"
)

// Seed type constants
const (
	SeedTypeHomeManager = "home-manager"
	SeedTypeNixOS       = "nixos"
)

// activate activates a seed based on its type
func activate(seedType, storePath, mode string) error {
	var err error

	switch seedType {
	case SeedTypeHomeManager:
		cmd := exec.Command(fmt.Sprintf("%s/activate", storePath))
		err = runCommand(cmd)
		if err != nil {
			return fmt.Errorf("failed to activate home-manager generation: %v", err)
		}

	case SeedTypeNixOS:
		err = setProfile("/nix/var/nix/profiles/system", storePath)
		if err != nil {
			return fmt.Errorf("failed to set nixos profile: %v", err)
		}

		switchCmd := exec.Command(fmt.Sprintf("%s/bin/switch-to-configuration", storePath), mode)
		err = runCommand(switchCmd)
		if err != nil {
			return fmt.Errorf("failed to run switch-to-configuration: %v", err)
		}

	default:
		return fmt.Errorf("unsupported seed type: %s", seedType)
	}

	return nil
}

// setProfile sets a nix profile to point to the given store path
func setProfile(profile, storePath string) error {
	profileCmd := exec.Command("nix-env", "--set", "--profile", profile, storePath)
	err := runCommand(profileCmd)
	if err != nil {
		return fmt.Errorf("failed to set profile: %v", err)
	}

	return nil
}

// runCommand executes a command with stdout and stderr attached
func runCommand(cmd *exec.Cmd) error {
	// Directly attach streams for real-time output
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	slog.Debug("Running command", "cmd", cmd.String())

	err := cmd.Run()
	if err != nil {
		return fmt.Errorf("failed to run command: %v", err)
	}

	return nil
}

// OutputCallback is called for each line of output during streaming execution.
type OutputCallback func(line string, isError bool)

// activateStreaming activates a seed with streaming output.
// Returns the exit code (0 for success) and any error that occurred.
func activateStreaming(seedType, storePath, mode string, callback OutputCallback) (int, error) {
	switch seedType {
	case SeedTypeHomeManager:
		cmd := exec.Command(fmt.Sprintf("%s/activate", storePath))
		return runCommandStreaming(cmd, callback)

	case SeedTypeNixOS:
		// First set the profile
		profileCmd := exec.Command("nix-env", "--set", "--profile", "/nix/var/nix/profiles/system", storePath)
		exitCode, err := runCommandStreaming(profileCmd, callback)
		if err != nil || exitCode != 0 {
			return exitCode, err
		}

		// Then run switch-to-configuration
		switchCmd := exec.Command(fmt.Sprintf("%s/bin/switch-to-configuration", storePath), mode)
		return runCommandStreaming(switchCmd, callback)

	default:
		return 1, fmt.Errorf("unsupported seed type: %s", seedType)
	}
}

// rebootStreaming requests a system reboot and streams output via callback.
func rebootStreaming(callback OutputCallback) (int, error) {
	args := []string{"reboot"}

	cmd := exec.Command("systemctl", args...)
	return runCommandStreaming(cmd, callback)
}

// runCommandStreaming executes a command and streams output via callback.
// Returns the exit code and any error that occurred.
func runCommandStreaming(cmd *exec.Cmd, callback OutputCallback) (int, error) {
	slog.Debug("Running command (streaming)", "cmd", cmd.String())

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return 1, fmt.Errorf("stdout pipe: %w", err)
	}

	stderr, err := cmd.StderrPipe()
	if err != nil {
		return 1, fmt.Errorf("stderr pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return 1, fmt.Errorf("start: %w", err)
	}

	// Stream output from both pipes concurrently
	var wg sync.WaitGroup
	wg.Add(2)

	go func() {
		defer wg.Done()
		streamLines(stdout, nil, callback, false)
	}()

	go func() {
		defer wg.Done()
		streamLines(stderr, os.Stderr, callback, true)
	}()

	wg.Wait()

	err = cmd.Wait()
	exitCode := 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			return 1, fmt.Errorf("wait: %w", err)
		}
	}

	return exitCode, nil
}

// streamLines reads lines from a reader, optionally mirrors to a writer,
// and calls the callback for each line.
func streamLines(r io.Reader, mirror io.Writer, callback OutputCallback, isError bool) {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := scanner.Text()
		if mirror != nil {
			fmt.Fprintln(mirror, line)
		}
		timestamped := time.Now().UTC().Format(time.RFC3339) + " " + line
		callback(timestamped, isError)
	}
}
