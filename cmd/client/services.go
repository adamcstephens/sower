package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"

	"codeberg.org/adamcstephens/sower/client"
	"codeberg.org/adamcstephens/sower/cmd/client/commands"
	"github.com/adrg/xdg"
)

var nixpkgsref = "refs/heads/nixos-unstable"

type ServicesManifest struct {
	Paths []string `json:"paths"`
}

// https://github.com/NixOS/nixpkgs/archive/refs/heads/master.zip
func buildServicesUnits(paths []client.StorePath) (string, error) {
	if len(paths) == 0 {
		return "", fmt.Errorf("no paths specified")
	}

	profileDir := filepath.Join(profileParentDir(), "services", servicesHash(paths))
	manifest := &ServicesManifest{}
	slog.Debug("Collecting services units", "profile", profileDir)

	_, err := os.Stat(profileDir)
	if err != nil {
		slog.Debug("Creating profile directory", "dir", profileDir)
		err = os.MkdirAll(profileDir, 0755)
		if err != nil {
			return "", fmt.Errorf("failed to create sower profile directory: %v", err)
		}
	}

	for _, path := range paths {
		sourceDir := filepath.Join(path.Path, ".sower", "systemd")

		// revisit in 1.24 to see if the CopyFS behavior changes, but currently fails on symlinks
		// err = os.CopyFS(profileDir, os.DirFS(sourceDir))

		cmd := exec.Command("cp", "--recursive", "--no-clobber", sourceDir, profileDir)
		err = cmd.Run()
		if err != nil {
			return "", fmt.Errorf("failed to copy path %s to profile %s: %v", path.Path, profileDir, err)
		}

		manifest.Paths = append(manifest.Paths, path.Path)
	}

	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return "", err
	}
	err = os.WriteFile(filepath.Join(profileDir, "manifest.json"), data, 0644)
	if err != nil {
		return "", err
	}

	slog.Debug("Successfully built services units output", "nixpkgs", nixpkgsref, "path", profileDir)

	return profileDir, nil
}

func servicesHash(paths []client.StorePath) string {
	hash := sha256.New()
	for _, path := range paths {
		hash.Write([]byte(path.Path))
	}

	return hex.EncodeToString(hash.Sum(nil))
}

func activateServices(profilePath string) error {
	var oldProfile string

	_, err := os.Stat(profilePath)
	if err != nil {
		// If no previous profile, we'll create a fake one
		slog.Warn("No old profile", "profile", profilePath)
		oldProfile, err = os.MkdirTemp("", "fake-old-units")
		if err != nil {
			return fmt.Errorf("unable to create fake old profile: %v", err)
		}
		err = os.MkdirAll(filepath.Join(oldProfile, "systemd", "system"), 0755)
		if err != nil {
			return fmt.Errorf("failed to create fake systemd dir: %v", err)
		}
	} else {
		oldProfile, err = filepath.EvalSymlinks(profilePath)
		if err != nil {
			return fmt.Errorf("unable to read old profile: %v", err)
		}
	}

	if oldProfile == profilePath {
		slog.Debug("Services already activated")
		return nil
	}

	oldUnits := filepath.Join(profilePath, "systemd", "system")
	newUnits := filepath.Join(profilePath, "systemd", "system")

	err = commands.SimpleRun(exec.Command("sd-switch", "--verbose", "--system", "--old-units", oldUnits, "--new-units", newUnits))
	if err != nil {
		return fmt.Errorf("failed to run sd-switch: %v", err)
	}

	return nil
}

func profileParentDir() string {
	root := "/var/lib/sower"

	if user, exists := os.LookupEnv("USER"); user != "root" && exists {
		root = filepath.Join(xdg.StateHome, "sower")
	}

	return filepath.Join(root, "profiles")
}
