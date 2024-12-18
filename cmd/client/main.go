package main

import (
	_ "embed"
	"encoding/json"
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

	ApiTokenFile string   `arg:"--api-token-file,env:SOWER_API_TOKEN_FILE" json:"api-token-file"`
	ApiToken     string   `arg:"--api-token,env:SOWER_API_TOKEN"`
	ConfigFiles  []string `arg:"--config-file,-c,separate,env:SOWER_CONFIG_FILE"`
	Debug        bool     `arg:"--debug"`
	Endpoint     string   `arg:"--endpoint,-e,env:SOWER_ENDPOINT"`
	Version      bool     `arg:"--version"`
}

type seedCmd struct {
	Create   *seedCreateCmd   `arg:"subcommand:create"`
	Download *seedDownloadCmd `arg:"subcommand:download"`
	Info     *seedInfoCmd     `arg:"subcommand:info"`
	Reboot   *seedRebootCmd   `arg:"subcommand:reboot"`
	Submit   *seedSubmitCmd   `arg:"subcommand:submit"`
	Upgrade  *seedUpgradeCmd  `arg:"subcommand:upgrade"`

	SeedType string `arg:"--type,-t" json:"type"`
	Name     string `arg:"--name,-n"`
}

type seedCreateCmd struct{}

type seedDownloadCmd struct{}

type seedInfoCmd struct{}

type seedRebootCmd struct {
	Yes bool `arg:"--yes,-y"`
}

type seedSubmitCmd struct {
	Path   string `arg:"--path,-p,required"`
	Create bool   `arg:"--create"`
}

type seedUpgradeCmd struct {
	Mode string `arg:"--mode,-m" default:"switch"`
	Yes  bool   `arg:"--yes,-y"`
}

func main() {
	var cfg config
	var parseResult error
	p, err := arg.NewParser(arg.Config{}, &cfg)
	if err != nil {
		log.Fatalf("Fatal error in argument specification")
		os.Exit(1)
	}
	parseResult = p.Parse(os.Args[1:])

	if len(cfg.ConfigFiles) != 0 {
		for _, configFile := range cfg.ConfigFiles {
			_, err := os.Stat(configFile)
			if err != nil {
				slog.Warn("Configuration file does not exist", "config-file", configFile)
				continue
			}

			j, err := os.ReadFile(configFile)
			if err != nil {
				slog.Error("Failed to read configuration file", "config-file", configFile)
				os.Exit(1)
			}

			if err := json.Unmarshal(j, &cfg); err != nil {
				slog.Error("Failed to parse configuration file", "config-file", configFile)
				os.Exit(1)
			}
		}
		// reparse flags on top of config
		parseResult = p.Parse(os.Args[1:])
	}

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
	case parseResult == arg.ErrHelp: // found "--help" on command line
		p.WriteHelp(os.Stdout)
		os.Exit(0)
	case parseResult != nil:
		slog.Error("Unknown error", "error", parseResult)
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
		seedClient, err := client.NewSeedClient(cfg.Endpoint, cfg.ApiToken)
		if err != nil {
			slog.Error("Failed to initialize seed client")
			os.Exit(1)
		}

		seed, err := seedClient.CreateSeed(cfg.Seed.Name, cfg.Seed.SeedType)
		if err != nil {
			slog.Error("Failed to create seed", "error", err)
			os.Exit(1)
		}

		slog.Info("Created seed", "name", seed.Name, "type", seed.SeedType, "id", seed.Id)

	case cfg.Seed.Download != nil:
		seedClient, err := client.NewSeedClient(cfg.Endpoint, cfg.ApiToken)
		if err != nil {
			slog.Error("Failed to initialize seed client")
			os.Exit(1)
		}

		seed, err := seedClient.GetSeed(cfg.Seed.Name, cfg.Seed.SeedType)
		if err != nil {
			slog.Error("Failed to get seed", "error", err, "name", cfg.Seed.Name, "type", cfg.Seed.SeedType)
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

		slog.Info("Downloaded seed", "name", seed.Name, "type", seed.SeedType, "path", storePath.Path)

	case cfg.Seed.Info != nil:
		seedClient, err := client.NewSeedClient(cfg.Endpoint, cfg.ApiToken)
		if err != nil {
			slog.Error("Failed to initialize seed client", "error", err)
			os.Exit(1)
		}

		seed, err := seedClient.GetSeed(cfg.Seed.Name, cfg.Seed.SeedType)
		if err != nil {
			slog.Error("Failed to get seed", "error", err, "name", cfg.Seed.Name, "type", cfg.Seed.SeedType)
			os.Exit(1)
		}

		storePath, err := seedClient.GetSeedLatestPath(seed)
		if err != nil {
			slog.Error("Failed to get seed store path", "error", err)
			os.Exit(1)
		}

		slog.Info("Found seed", "name", seed.Name, "type", seed.SeedType, "path", storePath.Path)

	case cfg.Seed.Reboot != nil:
		err := reboot(cfg.Seed.Reboot.Yes)
		if err != nil {
			slog.Error("Failed to reboot", "error", err)
			os.Exit(1)
		}

	case cfg.Seed.Submit != nil:
		cmdArgs := cfg.Seed.Submit

		seedClient, err := client.NewSeedClient(cfg.Endpoint, cfg.ApiToken)
		if err != nil {
			slog.Error("Failed to initialize seed client", "error", err)
			os.Exit(1)
		}

		var seed *client.Seed

		seed, err = seedClient.GetSeed(cfg.Seed.Name, cfg.Seed.SeedType)
		if err != nil && cmdArgs.Create {
			seed, err = seedClient.CreateSeed(cfg.Seed.Name, cfg.Seed.SeedType)
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

		slog.Info("Submitted seed", "name", seed.Name, "type", seed.SeedType, "path", storePath.Path)

	case cfg.Seed.Upgrade != nil:
		cmdArgs := cfg.Seed.Upgrade

		seedClient, err := client.NewSeedClient(cfg.Endpoint, cfg.ApiToken)
		if err != nil {
			slog.Error("Failed to initialize seed client")
			os.Exit(1)
		}

		seed, err := seedClient.GetSeed(cfg.Seed.Name, cfg.Seed.SeedType)
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

		if err := activate(seed.SeedType, storePath.Path, cmdArgs.Mode); err != nil {
			slog.Error("Failed realizing seed", "error", err)
			os.Exit(1)
		}

		slog.Info("Upgraded seed", "name", cfg.Seed.Name, "type", seed.SeedType, "path", storePath.Path)

		if seed.SeedType == client.Nixos {
			err := reboot(cmdArgs.Yes)
			if err != nil {
				slog.Error("Failed to reboot", "error", err)
				os.Exit(1)
			}
		}
	}
}
