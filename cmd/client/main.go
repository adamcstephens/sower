package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"log"
	"log/slog"
	"os"
	"strings"
	"time"

	"codeberg.org/adamcstephens/sower/client"
	"codeberg.org/adamcstephens/sower/cmd/client/builder"
	"github.com/adrg/xdg"
	"github.com/alexflint/go-arg"
	"github.com/lmittmann/tint"
	"github.com/mattn/go-isatty"
)

var version = "dev"

type config struct {
	Builder *builderCmd `arg:"subcommand:builder"`
	Daemon  *daemonCmd  `arg:"subcommand:daemon"`
	Seed    *seedCmd    `arg:"subcommand:seed"`

	ApiTokenFile string   `arg:"--api-token-file,env:SOWER_API_TOKEN_FILE" json:"api-token-file"`
	ApiToken     string   `arg:"--api-token,env:SOWER_API_TOKEN"`
	ConfigFiles  []string `arg:"--config-file,-c,separate,env:SOWER_CONFIG_FILE" help:"Can be repeated. Defaults are root:/etc/sower/client.json, non-root:$XDG_CONFIG_HOME/sower/client.json"`
	Debug        bool     `arg:"--debug"`
	Endpoint     string   `arg:"--endpoint,-e,env:SOWER_ENDPOINT"`
	Version      bool     `arg:"--version"`
}

type builderCmd struct {
	Eval  *builderEvalCmd  `arg:"subcommand:eval"`
	Build *builderBuildCmd `arg:"subcommand:build"`
}

type builderBuildCmd struct {
	Workers int `arg:"--workers,-w"`
}

type builderEvalCmd struct {
	Workers int `arg:"--workers,-w"`
}

type daemonCmd struct {
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

	// read args for finding config files
	_ = p.Parse(os.Args[1:])

	initLogger(cfg.Debug)

	if len(cfg.ConfigFiles) == 0 {
		defaultConfig, err := default_config_path()
		if err != nil {
			slog.Error("Failed to find default configuration file.", "error", err)
			os.Exit(1)
		}

		slog.Debug("Found default configuration file", "config-file", defaultConfig)

		cfg.ConfigFiles = []string{defaultConfig}
	}

	for _, configFile := range cfg.ConfigFiles {
		slog.Debug("Loading configuration file", "config-file", configFile)

		_, err := os.Stat(configFile)
		if err != nil {
			slog.Debug("Skipping: configuration file does not exist", "config-file", configFile)
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

	// re-initialize logging in case level is only set in config
	initLogger(cfg.Debug)

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

	if cfg.Endpoint == "" {
		slog.Error("Missing Sower endpoint. Add to configuration file or environment.")
		os.Exit(1)
	}

	if cfg.ApiToken == "" {
		slog.Error("Missing API token. Add to configuration file or environment.")
		os.Exit(1)
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
	case cfg.Builder != nil:
		buildCommand(cfg)
	case cfg.Daemon != nil:
		daemonCommand(cfg)
	case cfg.Seed != nil:
		err := seedSubcommand(cfg)
		if err != nil {
			p.WriteHelp(os.Stdout)
		}
	default:
		p.WriteHelp(os.Stdout)
	}
}

func initLogger(debug bool) {
	logLevel := slog.LevelInfo
	stdout := os.Stdout

	if debug {
		logLevel = slog.LevelDebug
	}

	logger := slog.New(tint.NewHandler(stdout, &tint.Options{
		Level:      logLevel,
		TimeFormat: time.DateTime,
		NoColor:    !isatty.IsTerminal(stdout.Fd()),
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			// if not a tty, strip the time
			if a.Key == slog.TimeKey && len(groups) == 0 && !isatty.IsTerminal(stdout.Fd()) {
				return slog.Attr{}
			}
			return a
		},
	}))

	slog.SetDefault(logger)
}

func buildCommand(cfg config) {
	switch {
	case cfg.Builder.Build != nil:
		err := builder.Build(cfg.Builder.Build.Workers)
		if err != nil {
			slog.Error("Failed to eval", "error", err)
			os.Exit(1)
		}
	case cfg.Builder.Eval != nil:
		err := builder.Eval(cfg.Builder.Eval.Workers)
		if err != nil {
			slog.Error("Failed to eval", "error", err)
			os.Exit(1)
		}
	default:
		slog.Error("No subcommand specified")
		os.Exit(1)
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

func seedSubcommand(cfg config) error {
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

		err := preCheckSeed(cmdArgs.Path, cfg.Seed.SeedType)
		if err != nil {
			slog.Error("Failed to pre-check seed for submission:", "error", err)
			os.Exit(1)
		}

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

		if cfg.Seed.SeedType == string(client.Nixos) && os.Getenv("USER") != "root" {
			slog.Error("Upgrades for nixos must be run by root")
			os.Exit(1)
		}

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
	default:
		return fmt.Errorf("No seed subcommand selected")
	}

	return nil
}

func default_config_path() (string, error) {
	slog.Debug("Finding default configuration file")

	user := os.Getenv("USER")

	switch user {
	case "root":
		return "/etc/sower/client.json", nil
	case "":
		return "", fmt.Errorf("Failed to detect user, not loading default config file")
	default:
		return fmt.Sprintf("%s/sower/client.json", xdg.ConfigHome), nil
	}
}
