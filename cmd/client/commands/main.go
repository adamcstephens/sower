package commands

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
)

func SimpleRun(cmd *exec.Cmd) error {
	// Set up the pipes for stdout and stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("error creating stdout: %v", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("error creating stderr: %v", err)
	}

	slog.Debug("Running command", "cmd", cmd.String())
	err = cmd.Start()
	if err != nil {
		return fmt.Errorf("error starting command: %v", err)
	}

	var ioErr error
	go func() {
		_, ioErr = io.Copy(os.Stdout, stdout) // Redirect stdout to terminal's stdout
		if ioErr != nil {
			slog.Error("failed to configure stdout")
		}
	}()
	go func() {
		_, ioErr = io.Copy(os.Stderr, stderr) // Redirect stderr to terminal's stderr
		if ioErr != nil {
			slog.Error("failed to configure stderr")
		}
	}()

	err = cmd.Wait()
	if err != nil {
		return fmt.Errorf("failed to download seed: %v", err)
	}

	if ioErr != nil {
		return fmt.Errorf("error copying output: %v", ioErr)
	}

	return nil
}
