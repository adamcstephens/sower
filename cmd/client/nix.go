package main

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
)

func Realize(path string) error {
	slog.Debug("Realizing path", "path", path)

	if path == "" {
		return fmt.Errorf("Cannot download without seed out_path")
	}

	cmd := exec.Command("nix-store", "--realize", path)

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
