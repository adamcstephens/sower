package main

import (
	_ "embed"
	"log"
	"log/slog"
	"os"
	"strings"

	"codeberg.org/adamcstephens/sower/client"
	"github.com/alexflint/go-arg"
)

var version = "dev"

type config struct {
	Daemon *seedCmd `arg:"subcommand:daemon"`
	Seed   *seedCmd `arg:"subcommand:seed"`

	ApiTokenFile string `arg:"--api-token-file,env:SOWER_API_TOKEN_FILE"`
	ApiToken     string `arg:"--api-token,env:SOWER_API_TOKEN"`
	Debug        bool   `arg:"--debug"`
	Endpoint     string `arg:"--endpoint,-e,env:SOWER_ENDPOINT"`
	Version      bool   `arg:"--version"`
}

type seedCmd struct {
	Create   *seedCreateCmd   `arg:"subcommand:create"`
	Download *seedDownloadCmd `arg:"subcommand:download"`
	Info     *seedInfoCmd     `arg:"subcommand:info"`
	Submit   *seedSubmitCmd   `arg:"subcommand:submit"`
	Upgrade  *seedUpgradeCmd  `arg:"subcommand:upgrade"`
}

type seedFields struct {
	SeedType string `arg:"--type,-t,required"`
	Name     string `arg:"--name,-n,required"`
}

type seedCreateCmd struct {
	seedFields
}

type seedDownloadCmd struct {
	seedFields
}

type seedInfoCmd struct {
	seedFields
}

type seedSubmitCmd struct {
	seedFields
	Path   string `arg:"--path,-p,required"`
	Create bool   `arg:"--create"`
}

type seedUpgradeCmd struct {
	seedFields
}

func main() {
	var cfg config
	p, err := arg.NewParser(arg.Config{}, &cfg)
	if err != nil {
		log.Fatalf("Fatal error in argument specification")
		os.Exit(1)
	}
	err = p.Parse(os.Args[1:])

	logLevel := slog.LevelInfo
	if cfg.Debug {
		logLevel = slog.LevelDebug
	}

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: logLevel}))
	slog.SetDefault(logger)

	slog.Debug("Loaded args", "args", cfg)

	if cfg.ApiToken == "" && cfg.ApiTokenFile != "" {
		slog.Debug("Reading api-token file", "file", cfg.ApiTokenFile)

		token, err := os.ReadFile(cfg.ApiTokenFile)
		if err != nil {
			slog.Error("Failed to read token file", "file", cfg.ApiTokenFile)
			os.Exit(1)
		}

		cfg.ApiToken = strings.TrimSpace(string(token))
	}

	switch {
	case cfg.Version:
		slog.Info("Version", "version", version)
		os.Exit(0)
	case err == arg.ErrHelp: // found "--help" on command line
		p.WriteHelp(os.Stdout)
		os.Exit(0)
	case err != nil:
		slog.Error("Unknown error", "error", err)
		os.Exit(1)
	}

	switch {
	case cfg.Seed != nil:
		seedSubcommand(cfg)
	case cfg.Daemon != nil:
		daemonCommand(cfg)
	default:
		p.WriteHelp(os.Stdout)
	}
}

func daemonCommand(cfg config) {
	client := newClient(cfg)

	err := client.connect()
	if err != nil {
		slog.Error("failed to connect")
	}

	client.run()
}

func seedSubcommand(cfg config) {
	switch {
	case cfg.Seed.Create != nil:
		cmdArgs := cfg.Seed.Create

		seedClient, err := client.NewSeedClient(cfg.Endpoint, cfg.ApiToken)
		if err != nil {
			slog.Error("Failed to initialize seed client")
			os.Exit(1)
		}

		seed, err := seedClient.CreateSeed(cmdArgs.Name, cmdArgs.SeedType)
		if err != nil {
			slog.Error("Failed to create seed", "error", err)
			os.Exit(1)
		}

		slog.Info("Created seed", "name", cmdArgs.Name, "type", cmdArgs.SeedType, "id", seed.Id)

	case cfg.Seed.Download != nil:
		cmdArgs := cfg.Seed.Download

		seedClient, err := client.NewSeedClient(cfg.Endpoint, cfg.ApiToken)
		if err != nil {
			slog.Error("Failed to initialize seed client")
			os.Exit(1)
		}

		seed, err := seedClient.GetSeed(cmdArgs.Name, cmdArgs.SeedType)
		if err != nil {
			slog.Error("Failed to get seed", "error", err)
			os.Exit(1)
		}

		storePath, err := seedClient.GetSeedLatestPath(seed)
		if err != nil {
			slog.Error("Failed to get seed store path", "error", err)
			os.Exit(1)
		}

		if err := realize(storePath.Path); err != nil {
			slog.Error("Failed realizing seed", "error", err)
			os.Exit(1)
		}

		slog.Info("Downloaded seed", "name", cmdArgs.Name, "type", cmdArgs.SeedType, "path", storePath.Path)

	case cfg.Seed.Info != nil:
		cmdArgs := cfg.Seed.Info

		seedClient, err := client.NewSeedClient(cfg.Endpoint, cfg.ApiToken)
		if err != nil {
			slog.Error("Failed to initialize seed client", "error", err)
			os.Exit(1)
		}

		seed, err := seedClient.GetSeed(cmdArgs.Name, cmdArgs.SeedType)
		if err != nil {
			slog.Error("Failed to get seed", "error", err)
			os.Exit(1)
		}

		storePath, err := seedClient.GetSeedLatestPath(seed)
		if err != nil {
			slog.Error("Failed to get seed store path", "error", err)
			os.Exit(1)
		}

		slog.Info("Found seed", "name", cmdArgs.Name, "type", cmdArgs.SeedType, "path", storePath.Path)

	case cfg.Seed.Submit != nil:
		cmdArgs := cfg.Seed.Submit

		seedClient, err := client.NewSeedClient(cfg.Endpoint, cfg.ApiToken)
		if err != nil {
			slog.Error("Failed to initialize seed client", "error", err)
			os.Exit(1)
		}

		var seed *client.Seed

		seed, err = seedClient.GetSeed(cmdArgs.Name, cmdArgs.SeedType)
		if err != nil && cmdArgs.Create {
			seed, err = seedClient.CreateSeed(cmdArgs.Name, cmdArgs.SeedType)
			if err != nil {
				slog.Error("Failed to create seed", "error", err)
				os.Exit(1)
			}
		}
		if err != nil {
			slog.Error("Failed to get seed", "error", err)
			os.Exit(1)
		}

		storePath, err := seedClient.SubmitSeedPath(seed, cmdArgs.Path)
		if err != nil {
			slog.Error("Failed submitting seed")
			os.Exit(1)
		}

		slog.Info("Submitted seed", "name", cmdArgs.Name, "type", cmdArgs.SeedType, "path", storePath.Path)

	case cfg.Seed.Upgrade != nil:
		cmdArgs := cfg.Seed.Upgrade

		seedClient, err := client.NewSeedClient(cfg.Endpoint, cfg.ApiToken)
		if err != nil {
			slog.Error("Failed to initialize seed client")
			os.Exit(1)
		}

		seed, err := seedClient.GetSeed(cmdArgs.Name, cmdArgs.SeedType)
		if err != nil {
			slog.Error("Failed to get seed", "error", err)
			os.Exit(1)
		}

		storePath, err := seedClient.GetSeedLatestPath(seed)
		if err != nil {
			slog.Error("Failed to get seed store path", "error", err)
			os.Exit(1)
		}

		if err := realize(storePath.Path); err != nil {
			slog.Error("Failed realizing seed", "error", err)
			os.Exit(1)
		}

		if err := activate(seed.SeedType, storePath.Path); err != nil {
			slog.Error("Failed realizing seed", "error", err)
			os.Exit(1)
		}

		slog.Info("Upgraded seed", "name", cmdArgs.Name, "type", cmdArgs.SeedType, "path", storePath.Path)

	}
}
