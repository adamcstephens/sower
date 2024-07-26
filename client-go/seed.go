package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"

	"github.com/rs/zerolog/log"
)

type Seed interface {
	Activate() error
	Download() error
}

type GenericSeed struct {
	Name     string `json:"name"`
	OutPath  string `json:"out_path"`
	SeedType string `json:"seed_type"`
}

func NewSeed(name, seed_type, out_path string) Seed {
	switch seed_type {
	case "nixos":
		return &NixosSeed{
			GenericSeed: GenericSeed{Name: name,
				OutPath:  out_path,
				SeedType: seed_type,
			},
		}
	}

	return &GenericSeed{
		Name:     name,
		OutPath:  out_path,
		SeedType: seed_type,
	}
}

func (d *GenericSeed) Activate() error {
	log.Debug().Msgf("Activating seed %s", d.Name)
	return nil
}

func (d *GenericSeed) Download() error {
	log.Debug().Any("seed", d).Msgf("Downloading seed")

	cmd := exec.Command("nix-store", "--realize", d.OutPath)

	// Set up the pipes for stdout and stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("Error creating StdoutPipe: %v", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("Error creating StderrPipe: %v", err)
	}

	err = cmd.Start()
	if err != nil {
		return fmt.Errorf("Error starting command: %v", err)
	}

	var ioErr error
	go func() {
		io.Copy(os.Stdout, stdout) // Redirect stdout to terminal's stdout
	}()
	go func() {
		io.Copy(os.Stderr, stderr) // Redirect stderr to terminal's stderr
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

type NixosSeed struct {
	GenericSeed
}

func (d *NixosSeed) Activate() error {
	log.Debug().Msg("Nixos is a different activation")
	return nil
}
