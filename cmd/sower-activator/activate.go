package main

import (
	"fmt"
	"log/slog"
	"os"
	"os/exec"
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
