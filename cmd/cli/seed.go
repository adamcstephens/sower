package main

import (
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"codeberg.org/adamcstephens/sower/client"
	"codeberg.org/adamcstephens/sower/cmd/cli/commands"
)

func activate(seedType client.SeedSeedType, storePath string, mode string) error {
	var err error

	switch seedType {
	case client.HomeManager:
		cmd := exec.Command(fmt.Sprintf("%s/activate", storePath))
		err = commands.SimpleRun(cmd)
		if err != nil {
			return fmt.Errorf("failed to activate home-manager generation: %v", err)
		}

	case client.Nixos:
		err = setProfile("/nix/var/nix/profiles/system", storePath)
		if err != nil {
			return fmt.Errorf("failed to set nixos profile: %v", err)
		}

		switchCmd := exec.Command(fmt.Sprintf("%s/bin/switch-to-configuration", storePath), mode)
		err = commands.SimpleRun(switchCmd)
		if err != nil {
			return fmt.Errorf("failed to set nixos profile: %v", err)
		}

	default:
		return fmt.Errorf("unsupported seed type: %s", seedType)
	}

	return nil
}

func realize(storePath string, caches *[]client.NixCache, initrd bool, profile string) error {
	slog.Debug("Realizing path", "path", storePath)

	if storePath == "" {
		return fmt.Errorf("cannot download without seed out_path")
	}

	_, err := os.Stat(storePath)
	if err == nil {
		slog.Debug("Already downloaded seed", "path", storePath)
		return nil
	}

	cmd := []string{"build", storePath}

	if initrd {
		cmd = append(cmd, "--store", "/sysroot")
	}

	if len(*caches) > 0 {
		var substituters, publicKeys []string

		for _, cache := range *caches {
			substituters = append(substituters, *cache.Url)
			publicKeys = append(publicKeys, *cache.PublicKey)
		}

		cmd = append(cmd, "--extra-substituters", strings.Join(substituters, ","))
		cmd = append(cmd, "--extra-trusted-public-keys", strings.Join(publicKeys, ","))
	}

	if profile != "" {
		cmd = append(cmd, "--profile", profile)
	}

	err = commands.SimpleRun(exec.Command("nix", cmd...))

	return err
}

func reboot(yes bool) error {
	slog.Debug("Checking reboot")

	compPaths := []string{"", "/initrd", "/kernel", "/kernel-modules"}

	profileStorePath, err := filepath.EvalSymlinks("/nix/var/nix/profiles/system")
	if err != nil {
		return fmt.Errorf("failed to eval symlink for %s: %v", "/nix/var/nix/profiles/system", err)
	}
	currentStorePath, err := filepath.EvalSymlinks("/run/current-system")
	if err != nil {
		return fmt.Errorf("failed to eval symlink for %s: %v", "/run/current-system", err)
	}
	bootedStorePath, err := filepath.EvalSymlinks("/run/booted-system")
	if err != nil {
		return fmt.Errorf("failed to eval symlink for %s: %v", "/run/booted-system", err)
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
				return fmt.Errorf("failed to schedule reboot: %v", err)
			}
		} else {
			slog.Warn("Reboot needed, but skipping without --yes")
		}
	}

	return nil
}

func setProfile(profile, storePath string) error {
	profileCmd := exec.Command("nix-env", "--set", "--profile", profile, storePath)
	err := commands.SimpleRun(profileCmd)
	if err != nil {
		return fmt.Errorf("failed to set profile: %v", err)
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
	case string(client.Service):
		versionFile = fmt.Sprintf("%v/.sower/systemd", storePath)
	default:
		return fmt.Errorf("unsupported seed type %s", seedType)
	}

	_, err := os.Stat(versionFile)
	if err != nil {
		return err
	}

	return nil
}
