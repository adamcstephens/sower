package main

import (
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"

	"codeberg.org/adamcstephens/sower/client"
	"codeberg.org/adamcstephens/sower/cmd/client/commands"
)

func activate(seedType client.SeedSeedType, storePath string, mode string) error {
	var err error

	switch {
	case seedType == client.HomeManager:
		cmd := exec.Command(fmt.Sprintf("%s/activate", storePath))
		err = commands.SimpleRun(cmd)
		if err != nil {
			return fmt.Errorf("Failed to activate home-manager generation: %v", err)
		}

	case seedType == client.Nixos:
		profileCmd := exec.Command("nix-env", "--set", "--profile", "/nix/var/nix/profiles/system", storePath)
		err = commands.SimpleRun(profileCmd)
		if err != nil {
			return fmt.Errorf("Failed to set nixos profile: %v", err)
		}

		switchCmd := exec.Command(fmt.Sprintf("%s/bin/switch-to-configuration", storePath), mode)
		err = commands.SimpleRun(switchCmd)
		if err != nil {
			return fmt.Errorf("Failed to set nixos profile: %v", err)
		}

	default:
		return fmt.Errorf("Unsupported seed type: %s", seedType)
	}

	return nil
}

func realize(storePath string, initrd bool) error {
	slog.Debug("Realizing path", "path", storePath)

	var cmd *exec.Cmd

	if storePath == "" {
		return fmt.Errorf("Cannot download without seed out_path")
	}

	if initrd {
		cmd = exec.Command("nix-store", "--realize", "--store", "/sysroot", storePath)
	} else {
		cmd = exec.Command("nix-store", "--realize", storePath)
	}

	err := commands.SimpleRun(cmd)

	return err
}

func reboot(yes bool) error {
	slog.Debug("Checking reboot")

	compPaths := []string{"", "/initrd", "/kernel", "/kernel-modules"}

	profileStorePath, err := filepath.EvalSymlinks("/nix/var/nix/profiles/system")
	if err != nil {
		return fmt.Errorf("Failed to eval symlink for %s: %v", "/nix/var/nix/profiles/system", err)
	}
	currentStorePath, err := filepath.EvalSymlinks("/run/current-system")
	if err != nil {
		return fmt.Errorf("Failed to eval symlink for %s: %v", "/run/current-system", err)
	}
	bootedStorePath, err := filepath.EvalSymlinks("/run/booted-system")
	if err != nil {
		return fmt.Errorf("Failed to eval symlink for %s: %v", "/run/booted-system", err)
	}

	var needReboot bool

	for _, path := range compPaths {
		profile := fmt.Sprintf("%s%s", profileStorePath, path)
		current := fmt.Sprintf("%s%s", currentStorePath, path)
		booted := fmt.Sprintf("%s%s", bootedStorePath, path)

		if path == "" {
			if current != profile {
				slog.Debug("Need to reboot", "path", path, "current", current, "profile", profile)
				needReboot = true
			}
		} else {
			if current != booted {
				slog.Debug("Need to reboot", "path", path, "current", current, "booted", booted)
				needReboot = true
			}
		}
	}

	if needReboot {
		if yes {
			slog.Info("Scheduling reboot in ~5 seconds")
			cmd := exec.Command("systemd-run", "--on-active=5s", "--no-block", "--unit=sower-client-reboot", "systemctl", "reboot")
			err := commands.SimpleRun(cmd)
			if err != nil {
				return fmt.Errorf("Failed to schedule reboot: %v", err)
			}
		} else {
			slog.Warn("Reboot needed, but skipping without --yes")
		}
	}

	return nil
}

func preCheckSeed(storePath, seedType string) error {
	var versionFile string

	switch seedType {
	case string(client.HomeManager):
		versionFile = fmt.Sprintf("%v/hm-version", storePath)
	case string(client.Nixos):
		versionFile = fmt.Sprintf("%v/nixos-version", storePath)
	default:
		return fmt.Errorf("Unsupported seed type %s", seedType)
	}

	_, err := os.Stat(versionFile)
	if err != nil {
		return err
	}

	return nil
}
