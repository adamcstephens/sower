package builder

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"

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

// Uploader defines the interface for pushing built outputs to a remote cache
type Uploader interface {
	Push(outputs []string) error
}

// AtticUploader pushes to an Attic cache
type AtticUploader struct {
	Cache string
	Jobs  string
}

// Push implements Uploader for AtticUploader
func (a *AtticUploader) Push(outputs []string) error {
	outputStr := strings.Join(outputs, "\n")

	pushCmd := exec.Command("attic", "push", "--stdin", "--ignore-upstream-cache-filter", "--jobs", a.Jobs, a.Cache)
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
		_, ioErr = io.Copy(os.Stdout, stdout)
		if ioErr != nil {
			slog.Error("failed to configure stdout")
		}
	}()
	go func() {
		_, ioErr = io.Copy(os.Stderr, stderr)
		if ioErr != nil {
			slog.Error("failed to configure stderr")
		}
	}()

	_, err = stdin.Write([]byte(outputStr))
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

// NixCopyUploader pushes using nix copy
type NixCopyUploader struct {
	Remote string
}

// Push implements Uploader for NixCopyUploader
func (n *NixCopyUploader) Push(outputs []string) error {
	args := append([]string{"copy", "--to", n.Remote}, outputs...)
	cmd := exec.Command("nix", args...)

	err := commands.SimpleRun(cmd)
	if err != nil {
		return fmt.Errorf("failed to run nix copy: %v", err)
	}

	return nil
}

// MultiUploader pushes to multiple targets in parallel
type MultiUploader struct {
	Uploaders []Uploader
}

// Push implements Uploader for MultiUploader
func (m *MultiUploader) Push(outputs []string) error {
	var wg sync.WaitGroup
	errChan := make(chan error, len(m.Uploaders))

	for _, u := range m.Uploaders {
		wg.Add(1)
		go func(uploader Uploader) {
			defer wg.Done()
			if err := uploader.Push(outputs); err != nil {
				slog.Error("Failed to push to target", "error", err)
				errChan <- err
			}
		}(u)
	}

	wg.Wait()
	close(errChan)

	// Collect all errors
	var errs []error
	for err := range errChan {
		errs = append(errs, err)
	}

	if len(errs) > 0 {
		return fmt.Errorf("failed to push to %d target(s): %w", len(errs), errors.Join(errs...))
	}
	return nil
}

// NewUploader creates an Uploader from a target string
func NewUploader(target string) (Uploader, error) {
	parts := strings.SplitN(target, ":", 2)
	if len(parts) != 2 {
		return nil, fmt.Errorf("invalid target format: %s (expected type:target)", target)
	}

	uploadType := parts[0]
	targetSpec := parts[1]

	switch uploadType {
	case "attic":
		// Parse cache name and optional query params
		cache := targetSpec
		jobs := "20" // default

		// Check if there are query params
		if idx := strings.Index(targetSpec, "?"); idx != -1 {
			cache = targetSpec[:idx]
			queryStr := targetSpec[idx+1:]

			params, err := url.ParseQuery(queryStr)
			if err != nil {
				return nil, fmt.Errorf("invalid query parameters in attic target: %v", err)
			}

			if j := params.Get("jobs"); j != "" {
				jobs = j
			}
		}

		return &AtticUploader{Cache: cache, Jobs: jobs}, nil

	case "nix-copy":
		return &NixCopyUploader{Remote: targetSpec}, nil

	default:
		return nil, fmt.Errorf("unknown upload target type %q, supported types: attic, nix-copy", uploadType)
	}
}

// NewMultiUploader creates an Uploader from multiple target strings
func NewMultiUploader(targets []string) (Uploader, error) {
	if len(targets) == 0 {
		return nil, fmt.Errorf("at least one upload target is required")
	}

	// Single target - return simple uploader (no wrapper overhead)
	if len(targets) == 1 {
		return NewUploader(targets[0])
	}

	// Multiple targets - create MultiUploader
	uploaders := make([]Uploader, 0, len(targets))
	for _, target := range targets {
		u, err := NewUploader(target)
		if err != nil {
			return nil, err
		}
		uploaders = append(uploaders, u)
	}

	return &MultiUploader{Uploaders: uploaders}, nil
}

func Push(workers int, system string, uploadTargets []string) error {
	uploader, err := NewMultiUploader(uploadTargets)
	if err != nil {
		return err
	}

	q := queue.NewPool(int64(workers))
	defer q.Release()

	// Create a closure that captures the uploader
	pushResultFunc := func(result evalResult) error {
		return pushResult(result, uploader)
	}

	err = evalJobs(workers, system, q, pushResultFunc)
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

func pushResult(result evalResult, uploader Uploader) error {
	outputs, err := commands.Run(exec.Command("nix", "build", "--print-out-paths", fmt.Sprintf("%v^*", result.DrvPath)))
	if err != nil {
		return fmt.Errorf("failed to build: %v", err)
	}

	output_list := strings.Split(outputs, "\n")
	// Filter out empty strings
	var filteredOutputs []string
	for _, output := range output_list {
		if output != "" {
			filteredOutputs = append(filteredOutputs, output)
		}
	}

	slog.Debug("Build result", "outputs", filteredOutputs)

	_ = printResult(result)

	return uploader.Push(filteredOutputs)
}
