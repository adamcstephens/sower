package builder

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os/exec"

	"codeberg.org/adamcstephens/sower/cmd/client/commands"
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

// func All() error {
// 	err := Eval()
// 	if err != nil {
// 		return fmt.Errorf("failed to build: %v", err)
// 	}
//
// 	return nil
// }

func Push(workers int) error {
	q := queue.NewPool(int64(workers))
	defer q.Release()

	err := evalJobs(workers, q, pushResult)
	if err != nil {
		return err
	}

	if q.FailureTasks() > 0 {
		return fmt.Errorf("failed to build one or more output")
	}

	return nil
}

func Build(workers int) error {
	q := queue.NewPool(int64(workers))
	defer q.Release()

	err := evalJobs(workers, q, buildResult)
	if err != nil {
		return err
	}

	if q.FailureTasks() > 0 {
		return fmt.Errorf("failed to build one or more output")
	}

	return nil
}

func Eval(workers int) error {
	q := queue.NewPool(1)
	defer q.Release()

	err := evalJobs(workers, q, printResult)
	if err != nil {
		return err
	}

	return nil
}

func evalJobs(workers int, resultQueue *queue.Queue, resultFunc func(evalResult) error) error {
	if workers == 0 {
		return fmt.Errorf("no workers specified")
	}

	cmd := exec.Command("nix-eval-jobs", "--flake", ".#sowerJobs", "--force-recurse", "--workers", fmt.Sprint(workers))

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
	err := commands.SimpleRun(exec.Command("nix", "build", fmt.Sprintf("%v^*", result.DrvPath)))
	if err != nil {
		return fmt.Errorf("failed to build: %v", err)
	}

	return nil
}
