package main

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"

	"codeberg.org/adamcstephens/sower/client"
)

func activate(seedType client.SeedSeedType, storePath string) error {
	var err error

	switch {
	case seedType == client.HomeManager:
		cmd := exec.Command(fmt.Sprintf("%s/activate", storePath))
		err = run(cmd)
	case seedType == client.Nixos:
		return fmt.Errorf("TODO %v", storePath)
	default:
		err = fmt.Errorf("Unsupported seed type: %s", seedType)
	}

	return err
}

func realize(storePath string) error {
	slog.Debug("Realizing path", "path", storePath)

	if storePath == "" {
		return fmt.Errorf("Cannot download without seed out_path")
	}

	cmd := exec.Command("nix-store", "--realize", storePath)

	err := run(cmd)

	return err
}

func run(cmd *exec.Cmd) error {
	// Set up the pipes for stdout and stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("Error creating stdout: %v", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("Error creating stderr: %v", err)
	}

	err = cmd.Start()
	if err != nil {
		return fmt.Errorf("Error starting command: %v", err)
	}

	var ioErr error
	go func() {
		_, err = io.Copy(os.Stdout, stdout) // Redirect stdout to terminal's stdout
		if err != nil {
			slog.Error("Failed to configure stdout")
		}
	}()
	go func() {
		_, err = io.Copy(os.Stderr, stderr) // Redirect stderr to terminal's stderr
		if err != nil {
			slog.Error("Failed to configure stderr")
		}
	}()

	slog.Debug("Running command", "cmd", cmd.String())
	err = cmd.Wait()
	if err != nil {
		return fmt.Errorf("Failed to download seed: %v", err)
	}

	if ioErr != nil {
		return fmt.Errorf("Error copying output: %v", ioErr)
	}

	return nil
}
