package main

import (
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"text/template"

	"codeberg.org/adamcstephens/sower/client"
	"codeberg.org/adamcstephens/sower/cmd/client/commands"
)

var nixpkgsref = "refs/heads/nixos-unstable"

type EnvTemplate struct {
	Nixpkgsref string
	Paths      []client.StorePath
}

// https://github.com/NixOS/nixpkgs/archive/refs/heads/master.zip
func buildServicesEnv(paths []client.StorePath) (string, error) {
	slog.Debug("Building services environment", "nixpkgs", nixpkgsref)

	envTemplate := `{
  pkgs ?
    import
      (fetchTarball "https://github.com/NixOS/nixpkgs/archive/{{ .Nixpkgsref }}.tar.gz")
      { },
}:
pkgs.buildEnv {
  name = "sower-services";
  paths = [{{ range .Paths }}
    {{ .Path }}
{{ end }}  ];

  pathsToLink = [
    "/.sower"
  ];

  postBuild = ''
    mv $out/.sower/* $out/
    rmdir $out/.sower
  '';
}
`

	envFileNix, err := os.CreateTemp("", "services-env")
	if err != nil {
		return "", fmt.Errorf("failed to create tempfile: %v", err)
	}
	defer os.Remove(envFileNix.Name())

	templateParser, err := template.New("services-env").Parse(envTemplate)
	if err != nil {
		return "", fmt.Errorf("failed to parse template: %v", err)
	}

	err = templateParser.Execute(envFileNix, &EnvTemplate{Paths: paths, Nixpkgsref: nixpkgsref})
	if err != nil {
		return "", fmt.Errorf("failed to parse template: %v", err)
	}

	cmd := exec.Command("nix-build", "--no-out-link", envFileNix.Name())
	stdout, err := commands.Run(cmd)
	if err != nil {
		return "", fmt.Errorf("failed to build services env file: %v", err)
	}

	slog.Debug("Successfully built services environment", "nixpkgs", nixpkgsref, "path", stdout)

	return stdout, nil
}

func activateServices(storePath string) error {
	profileDir := "/nix/var/nix/profiles/sower"
	_, err := os.Stat(profileDir)
	if err != nil {
		slog.Debug("Creating profile directory", "dir", profileDir)
		err = os.Mkdir(profileDir, 0x0755)
		if err != nil {
			return fmt.Errorf("failed to create sower profile directory: %v", err)
		}
	}

	err = setProfile(fmt.Sprintf("%s/services", profileDir), storePath)
	if err != nil {
		return fmt.Errorf("failed to set services profile: %v", err)
	}

	return nil
}
