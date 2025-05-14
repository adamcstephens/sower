package main

import (
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"text/template"

	"codeberg.org/adamcstephens/sower/client"
	"codeberg.org/adamcstephens/sower/cmd/client/commands"
	"github.com/adrg/xdg"
)

var nixpkgsref = "refs/heads/nixos-unstable"

type EnvTemplate struct {
	Nixpkgsref string
	Paths      []client.StorePath
}

// https://github.com/NixOS/nixpkgs/archive/refs/heads/master.zip
func buildServicesUnits(paths []client.StorePath) (string, error) {
	slog.Debug("Collecting services units", "nixpkgs", nixpkgsref)

	unitsTemplate := `{
  pkgs ?
		import <nixpkgs>
	# import (fetchTarball "https://github.com/NixOS/nixpkgs/archive/{{ .Nixpkgsref }}.tar.gz")
      { },
}:
pkgs.runCommand "sower-services"
  {
    nativeBuildInputs = [{{ range .Paths }}
    {{ .Path }}
{{ end }}  ];
  }
  ''
    mkdir -p $out/nix-support

    for path in $nativeBuildInputs; do
      echo "Copying $path"
      cp --recursive --no-clobber $path/.sower $out/
      chmod --recursive +w $out/
    done

    if [  ! -e $out/.sower/systemd ]; then
      echo "No services found"
      exit 1
    fi

    mv $out/.sower/* $out/
    rmdir $out/.sower
  ''
`

	unitsFileNix, err := os.CreateTemp("", "services-units-*.nix")
	if err != nil {
		return "", fmt.Errorf("failed to create tempfile: %v", err)
	}
	slog.Debug("Created temp file", "units-file", unitsFileNix.Name())
	// defer os.Remove(unitsFileNix.Name())

	templateParser, err := template.New("services-units").Parse(unitsTemplate)
	if err != nil {
		return "", fmt.Errorf("failed to parse template: %v", err)
	}

	err = templateParser.Execute(unitsFileNix, &EnvTemplate{Paths: paths, Nixpkgsref: nixpkgsref})
	if err != nil {
		return "", fmt.Errorf("failed to parse template: %v", err)
	}

	cmd := exec.Command("nix-build", "--no-out-link", unitsFileNix.Name())
	stdout, err := commands.Run(cmd)
	if err != nil {
		return "", fmt.Errorf("failed to build services units file: %v", err)
	}

	slog.Debug("Successfully built services units output", "nixpkgs", nixpkgsref, "path", stdout)

	return stdout, nil
}

func activateServices(storePath string) error {
	parentDir := profileParentDir()
	_, err := os.Stat(parentDir)
	if err != nil {
		slog.Debug("Creating profile directory", "dir", parentDir)
		err = os.MkdirAll(parentDir, 0755)
		if err != nil {
			return fmt.Errorf("failed to create sower profile directory: %v", err)
		}
	}

	profile := filepath.Join(parentDir, "services-units")
	var oldProfile string

	_, err = os.Stat(profile)
	if err != nil {
		slog.Warn("No old profile", "profile", profile)
		oldProfile, err = os.MkdirTemp("", "fake-old-units")
		if err != nil {
			return fmt.Errorf("unable to create fake old profile: %v", err)
		}
		err = os.MkdirAll(filepath.Join(oldProfile, "systemd", "system"), 0755)
		if err != nil {
			return fmt.Errorf("failed to create fake systemd dir: %v", err)
		}
	} else {
		oldProfile, err = filepath.EvalSymlinks(profile)
		if err != nil {
			return fmt.Errorf("unable to read old profile: %v", err)
		}
	}

	if oldProfile == storePath {
		slog.Debug("Services already activated")
		return nil
	}

	oldUnits := filepath.Join(oldProfile, "systemd", "system")
	newUnits := filepath.Join(storePath, "systemd", "system")

	err = setProfile(profile, storePath)
	if err != nil {
		return fmt.Errorf("failed to set services profile: %v", err)
	}

	err = commands.SimpleRun(exec.Command("sd-switch", "--verbose", "--system", "--old-units", oldUnits, "--new-units", newUnits))
	if err != nil {
		return fmt.Errorf("failed to run sd-switch: %v", err)
	}

	return nil
}

func profileParentDir() string {
	if user, exists := os.LookupEnv("USER"); user != "root" && exists {
		return filepath.Join(xdg.StateHome, "nix", "profiles", "sower")
	}

	return "/nix/var/nix/profiles/sower"
}
