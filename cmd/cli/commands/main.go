package commands

import (
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strings"
)

func SimpleRun(cmd *exec.Cmd) error {
	// Directly attach streams for real-time output
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	slog.Debug("Running command", "cmd", cmd.String())

	err := cmd.Run()
	if err != nil {
		return fmt.Errorf("failed to run command: %v", err)
	}

	return nil
}

func Run(cmd *exec.Cmd) (string, error) {
	// Attach stderr for real-time error output
	cmd.Stderr = os.Stderr

	slog.Debug("Running command", "cmd", cmd.String())

	stdout, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("failed to run command: %v", err)
	}

	return strings.TrimSpace(string(stdout)), nil
}
