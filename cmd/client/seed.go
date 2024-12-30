package main

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"

	"codeberg.org/adamcstephens/sower/client"
)

func activate(seedType client.SeedSeedType, storePath string, mode string) error {
	var err error

	switch {
	case seedType == client.HomeManager:
		cmd := exec.Command(fmt.Sprintf("%s/activate", storePath))
		err = simpleRun(cmd)
		if err != nil {
			return fmt.Errorf("Failed to activate home-manager generation: %v", err)
		}

	case seedType == client.Nixos:
		profileCmd := exec.Command("nix-env", "--set", "--profile", "/nix/var/nix/profiles/system", storePath)
		err = simpleRun(profileCmd)
		if err != nil {
			return fmt.Errorf("Failed to set nixos profile: %v", err)
		}

		switchCmd := exec.Command(fmt.Sprintf("%s/bin/switch-to-configuration", storePath), mode)
		err = simpleRun(switchCmd)
		if err != nil {
			return fmt.Errorf("Failed to set nixos profile: %v", err)
		}

	default:
		return fmt.Errorf("Unsupported seed type: %s", seedType)
	}

	return nil
}

func realize(storePath string) error {
	slog.Debug("Realizing path", "path", storePath)

	if storePath == "" {
		return fmt.Errorf("Cannot download without seed out_path")
	}

	cmd := exec.Command("nix-store", "--realize", storePath)

	err := simpleRun(cmd)

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
			err := simpleRun(cmd)
			if err != nil {
				return fmt.Errorf("Failed to schedule reboot: %v", err)
			}
		} else {
			slog.Warn("Reboot needed, but skipping without --yes")
		}
	}

	return nil
}

func simpleRun(cmd *exec.Cmd) error {
	// Set up the pipes for stdout and stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("Error creating stdout: %v", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("Error creating stderr: %v", err)
	}

	slog.Debug("Running command", "cmd", cmd.String())
	err = cmd.Start()
	if err != nil {
		return fmt.Errorf("Error starting command: %v", err)
	}

	var ioErr error
	go func() {
		_, ioErr = io.Copy(os.Stdout, stdout) // Redirect stdout to terminal's stdout
		if ioErr != nil {
			slog.Error("Failed to configure stdout")
		}
	}()
	go func() {
		_, ioErr = io.Copy(os.Stderr, stderr) // Redirect stderr to terminal's stderr
		if ioErr != nil {
			slog.Error("Failed to configure stderr")
		}
	}()

	err = cmd.Wait()
	if err != nil {
		return fmt.Errorf("Failed to download seed: %v", err)
	}

	if ioErr != nil {
		return fmt.Errorf("Error copying output: %v", ioErr)
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
