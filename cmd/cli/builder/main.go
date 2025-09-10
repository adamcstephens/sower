package builder

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"strings"

	"codeberg.org/adamcstephens/sower/cmd/cli/commands"
	"github.com/golang-queue/queue"
)

type evalResult struct {
	Attr      string            `json:"attr"`
	AttrPath  []string          `json:"attrPath"`
	DrvPath   string            `json:"drvPath"`
	Error     string            `json:"error"`
	InputDrvs inputDrv          `json:"inputDrvs"`
	Name      string            `json:"name"`
	Outputs   map[string]string `json:"outputs"`
	System    string            `json:"system"`
}

type inputDrv map[string][]string

func Push(workers int, system string) error {
	q := queue.NewPool(int64(workers))
	defer q.Release()

	err := evalJobs(workers, system, q, pushResult)
	if err != nil {
		return err
	}

	if q.FailureTasks() > 0 {
		return fmt.Errorf("failed to build one or more output")
	}

	return nil
}

func Build(workers int, system string) error {
	q := queue.NewPool(int64(workers))
	defer q.Release()

	err := evalJobs(workers, system, q, buildResult)
	if err != nil {
		return err
	}

	if q.FailureTasks() > 0 {
		return fmt.Errorf("failed to build one or more output")
	}

	return nil
}

func Eval(workers int, system string) error {
	q := queue.NewPool(1)
	defer q.Release()

	err := evalJobs(workers, system, q, printResult)
	if err != nil {
		return err
	}

	return nil
}

func evalJobs(workers int, system string, resultQueue *queue.Queue, resultFunc func(evalResult) error) error {
	if workers == 0 {
		return fmt.Errorf("no workers specified")
	}

	target := ".#sowerJobs"
	if system != "" {
		target = fmt.Sprintf(".#sowerJobs.%s", system)
	}

	cmd := exec.Command("nix-eval-jobs", "--flake", target, "--force-recurse", "--workers", fmt.Sprint(workers))

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("error creating stdout: %v", err)
	}

	stdoutDone := make(chan struct{})
	stdoutScanner := bufio.NewScanner(stdout)

	go func() {
		for stdoutScanner.Scan() {
			var result evalResult

			line := stdoutScanner.Text()
			err := json.Unmarshal([]byte(line), &result)

			if err != nil {
				slog.Error("failed to parse eval result", "error", err)
				continue
			}

			if result.Error != "" {
				slog.Error("failed eval result", "result", result)
			} else {
				if err := resultQueue.QueueTask(func(ctx context.Context) error {
					err := resultFunc(result)
					if err != nil {
						return err
					}

					return nil
				}); err != nil {
					panic(err)
				}
			}
		}

		stdoutDone <- struct{}{}
	}()

	slog.Debug("Running command", "cmd", cmd.String())
	err = cmd.Start()
	if err != nil {
		return fmt.Errorf("error starting command: %v", err)
	}

	<-stdoutDone
	err = cmd.Wait()
	if err != nil {
		return fmt.Errorf("failure during nix-eval-jobs: %v", err)
	}

	return nil
}

func buildResult(result evalResult) error {
	slog.Debug("Building result", "result", result)
	err := commands.SimpleRun(exec.Command("nix", "build", fmt.Sprintf("%v^*", result.DrvPath)))
	if err != nil {
		return fmt.Errorf("failed to build: %v", err)
	}

	return nil
}

func printResult(result evalResult) error {
	slog.Info("Eval result", "result", result)

	return nil
}

func pushResult(result evalResult) error {
	outputs, err := commands.Run(exec.Command("nix", "build", "--print-out-paths", fmt.Sprintf("%v^*", result.DrvPath)))
	if err != nil {
		return fmt.Errorf("failed to build: %v", err)
	}

	output_list := strings.Split(outputs, "\n")

	slog.Debug("Build result", "outputs", output_list)

	_ = printResult(result)

	attic_cache := os.Getenv("ATTIC_CACHE")
	if attic_cache == "" {
		slog.Error("Must set ATTIC_CACHE to name of pre-configured cache. e.g. myserver:mycache")
		os.Exit(1)
	}

	attic_jobs := os.Getenv("ATTIC_JOBS")
	if attic_jobs == "" {
		attic_jobs = "20"
	}

	pushCmd := exec.Command("attic", "push", "--stdin", "--ignore-upstream-cache-filter", "--jobs", attic_jobs, attic_cache)
	stdout, err := pushCmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("error creating stdout: %v", err)
	}
	stderr, err := pushCmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("error creating stderr: %v", err)
	}
	stdin, _ := pushCmd.StdinPipe()

	err = pushCmd.Start()
	if err != nil {
		return fmt.Errorf("failed to start command: %v", err)
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

	_, err = stdin.Write([]byte(outputs))
	if err != nil {
		return fmt.Errorf("failed to send stdin to push: %v", err)
	}
	stdin.Close()

	err = pushCmd.Wait()
	if err != nil {
		return fmt.Errorf("failed to wait for run command: %v", err)
	}

	return nil
}
