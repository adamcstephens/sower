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
func buildServicesEnv(paths []client.StorePath) error {
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
		return fmt.Errorf("failed to create tempfile: %v", err)
	}
	defer os.Remove(envFileNix.Name())

	templateParser, err := template.New("services-env").Parse(envTemplate)
	if err != nil {
		return fmt.Errorf("failed to parse template: %v", err)
	}

	err = templateParser.Execute(envFileNix, &EnvTemplate{Paths: paths, Nixpkgsref: nixpkgsref})
	if err != nil {
		return fmt.Errorf("failed to parse template: %v", err)
	}

	cmd := exec.Command("nix-build", envFileNix.Name())
	err = commands.SimpleRun(cmd)
	if err != nil {
		return fmt.Errorf("failed to build services env file: %v", err)
	}

	slog.Debug("Successfully built services environment", "nixpkgs", nixpkgsref)

	return nil
}
