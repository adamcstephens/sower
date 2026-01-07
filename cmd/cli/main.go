package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"log"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"codeberg.org/adamcstephens/sower/client-go"
	"codeberg.org/adamcstephens/sower/cmd/cli/builder"
	"github.com/adrg/xdg"
	"github.com/alexflint/go-arg"
	"github.com/lmittmann/tint"
	"github.com/mattn/go-isatty"
)

var version = "dev"

type config struct {
	Builder  *builderCmd  `arg:"subcommand:builder"`
	Daemon   *daemonCmd   `arg:"subcommand:daemon"`
	Seed     *seedCmd     `arg:"subcommand:seed"`
	Services *servicesCmd `arg:"subcommand:services"`

	AccessTokenFile string   `arg:"--access-token-file,env:SOWER_ACCESS_TOKEN_FILE" json:"access_token_file"`
	AccessToken     string   `arg:"--access-token,env:SOWER_ACCESS_TOKEN"`
	ConfigFiles     []string `arg:"--config-file,-c,separate,env:SOWER_CONFIG_FILE" help:"Can be repeated. Defaults are root:/etc/sower/client.json, non-root:$XDG_CONFIG_HOME/sower/client.json"`
	Debug           bool     `arg:"--debug"`
	Endpoint        string   `arg:"--endpoint,-e,env:SOWER_ENDPOINT"`
	Version         bool     `arg:"--version"`
}

type builderCmd struct {
	Eval  *builderEvalCmd  `arg:"subcommand:eval"`
	Build *builderBuildCmd `arg:"subcommand:build"`
	Push  *builderPushCmd  `arg:"subcommand:push"`
}

type builderBuildCmd struct {
	Workers int    `arg:"--workers,-w"`
	System  string `arg:"--system"`
}

type builderEvalCmd struct {
	Workers int    `arg:"--workers,-w"`
	System  string `arg:"--system"`
}

type builderPushCmd struct {
	Workers int      `arg:"--workers,-w"`
	System  string   `arg:"--system"`
	Targets []string `arg:"--target,-t,required,separate" help:"Upload target (attic:<cache>[?jobs=N] or nix-copy:<remote>). Can be repeated."`
}

type daemonCmd struct {
}

type seedCmd struct {
	Download *seedDownloadCmd `arg:"subcommand:download"`
	Info     *seedInfoCmd     `arg:"subcommand:info"`
	Reboot   *seedRebootCmd   `arg:"subcommand:reboot"`
	Submit   *seedSubmitCmd   `arg:"subcommand:submit"`
	Upgrade  *seedUpgradeCmd  `arg:"subcommand:upgrade"`

	SeedType string `arg:"--type,-t" json:"type"`
	Name     string `arg:"--name,-n"`
}

type seedDownloadCmd struct {
	Initrd bool `arg:"--initrd"`
}

type seedInfoCmd struct{}

type seedRebootCmd struct {
	Yes bool `arg:"--yes,-y"`
}

type seedSubmitCmd struct {
	Artifact string   `arg:"--path,-p,required"`
	Tags     []string `arg:"--tag,separate" help:"Tags in key=value format. Can be repeated."`
}

type seedUpgradeCmd struct {
	Mode string `arg:"--mode,-m" default:"switch"`
	Yes  bool   `arg:"--yes,-y"`
}

type servicesCmd struct {
	List     *servicesListCmd    `arg:"subcommand:list"`
	Upgrade  *servicesUpgradeCmd `arg:"subcommand:upgrade"`
	Services []client.SeedSeedType
}

type servicesListCmd struct{}
type servicesUpgradeCmd struct{}

func main() {
	var cfg config

	parsedConfig, err := arg.NewParser(arg.Config{}, &cfg)
	if err != nil {
		log.Fatalf("Fatal error in argument specification")
		os.Exit(1)
	}

	// read args for finding config files
	_ = parsedConfig.Parse(os.Args[1:])

	args := cfg

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

		// merge into config
		if err := json.Unmarshal(j, &cfg); err != nil {
			slog.Error("Failed to parse configuration file", "config-file", configFile)
			os.Exit(1)
		}
	}

	// reparse args on top of config
	parseResult := parsedConfig.Parse(os.Args[1:])

	slog.Debug("CLI args", "args", args)
	slog.Debug("Final merged config", "config", cfg)

	// re-initialize logging in case level is only set in config
	initLogger(cfg.Debug)

	if cfg.AccessToken == "" && cfg.AccessTokenFile != "" {
		slog.Debug("Reading access-token file", "file", cfg.AccessTokenFile)

		token, err := os.ReadFile(cfg.AccessTokenFile)
		if err != nil {
			slog.Error("Failed to read token file", "file", cfg.AccessTokenFile)
			os.Exit(1)
		}

		cfg.AccessToken = strings.TrimSpace(string(token))
	}

	if cfg.Endpoint == "" {
		slog.Error("Missing Sower endpoint. Add to configuration file or environment.")
		os.Exit(1)
	}

	if cfg.AccessToken == "" {
		slog.Warn("Missing access token. Add to configuration file or environment.")
	}

	switch {
	case cfg.Version:
		slog.Info("Version", "version", version)
		os.Exit(0)
	case parseResult == arg.ErrHelp: // found "--help" on command line
		parsedConfig.WriteHelp(os.Stdout)
		os.Exit(0)
	case parseResult != nil:
		slog.Error("Unknown error", "error", parseResult)
		os.Exit(1)
	case args.Builder != nil:
		buildCommand(cfg)
	case args.Daemon != nil:
		daemonCommand(cfg)
	case args.Seed != nil:
		err := seedSubcommand(cfg)
		if err != nil {
			parsedConfig.WriteHelp(os.Stdout)
		}
	case cfg.Services != nil:
		servicesCommand(cfg)
	default:
		parsedConfig.WriteHelp(os.Stdout)
	}
}

func initLogger(debug bool) {
	logLevel := slog.LevelInfo
	stderr := os.Stderr

	if debug {
		logLevel = slog.LevelDebug
	}

	logger := slog.New(tint.NewHandler(stderr, &tint.Options{
		Level:      logLevel,
		TimeFormat: time.DateTime,
		NoColor:    !isatty.IsTerminal(stderr.Fd()),
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			// if not a tty, strip the time
			if a.Key == slog.TimeKey && len(groups) == 0 && !isatty.IsTerminal(stderr.Fd()) {
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
		err := builder.Build(cfg.Builder.Build.Workers, cfg.Builder.Build.System)
		if err != nil {
			slog.Error("Failed to eval", "error", err)
			os.Exit(1)
		}
	case cfg.Builder.Eval != nil:
		err := builder.Eval(cfg.Builder.Eval.Workers, cfg.Builder.Eval.System)
		if err != nil {
			slog.Error("Failed to eval", "error", err)
			os.Exit(1)
		}
	case cfg.Builder.Push != nil:
		err := builder.Push(cfg.Builder.Push.Workers, cfg.Builder.Push.System, cfg.Builder.Push.Targets)
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
	case cfg.Seed.Download != nil:
		seedClient, err := client.NewSowerClient(cfg.Endpoint, cfg.AccessToken)
		if err != nil {
			slog.Error("Failed to initialize seed client")
			os.Exit(1)
		}

		seed, err := seedClient.GetLatestSeed(cfg.Seed.Name, cfg.Seed.SeedType)
		if err != nil {
			slog.Error("Failed to get seed", "error", err, "name", cfg.Seed.Name, "type", cfg.Seed.SeedType)
			os.Exit(1)
		}

		caches, err := seedClient.GetNixCaches()
		if err != nil {
			slog.Error("Failed to get nix caches", "error", err)
			os.Exit(1)
		}

		if err := realize(seed.Artifact, caches, cfg.Seed.Download.Initrd, ""); err != nil {
			slog.Error("Failed realizing seed", "error", err)
			os.Exit(1)
		}

		slog.Info("Downloaded seed", "name", seed.Name, "type", seed.SeedType, "artifact", seed.Artifact)

	case cfg.Seed.Info != nil:
		seedClient, err := client.NewSowerClient(cfg.Endpoint, cfg.AccessToken)
		if err != nil {
			slog.Error("Failed to initialize seed client", "error", err)
			os.Exit(1)
		}

		seed, err := seedClient.GetLatestSeed(cfg.Seed.Name, cfg.Seed.SeedType)
		if err != nil {
			slog.Error("Failed to get seed", "error", err, "name", cfg.Seed.Name, "type", cfg.Seed.SeedType)
			os.Exit(1)
		}

		slog.Info("Found seed", "name", seed.Name, "type", seed.SeedType, "artifact", seed.Artifact)

	case cfg.Seed.Reboot != nil:
		err := reboot(cfg.Seed.Reboot.Yes)
		if err != nil {
			slog.Error("Failed to reboot", "error", err)
			os.Exit(1)
		}

	case cfg.Seed.Submit != nil:
		cmdArgs := cfg.Seed.Submit

		err := preCheckSeed(cmdArgs.Artifact, cfg.Seed.SeedType)
		if err != nil {
			slog.Error("Failed to pre-check seed for submission:", "error", err)
			os.Exit(1)
		}

		seedClient, err := client.NewSowerClient(cfg.Endpoint, cfg.AccessToken)
		if err != nil {
			slog.Error("Failed to initialize seed client", "error", err)
			os.Exit(1)
		}

		var tags []client.SeedTag
		for _, tagStr := range cmdArgs.Tags {
			parts := strings.SplitN(tagStr, "=", 2)
			if len(parts) != 2 {
				slog.Error("Invalid tag format. Expected key=value", "tag", tagStr)
				os.Exit(1)
			}
			tags = append(tags, client.SeedTag{
				Key:   parts[0],
				Value: parts[1],
			})
		}

		var seed *client.Seed

		seed, err = seedClient.CreateSeed(cfg.Seed.Name, cfg.Seed.SeedType, cmdArgs.Artifact, tags)
		if err != nil {
			slog.Error("Failed to create seed", "error", err)
			os.Exit(1)
		}

		slog.Info("Submitted seed", "name", seed.Name, "type", seed.SeedType, "artifact", seed.Artifact)

	case cfg.Seed.Upgrade != nil:
		cmdArgs := cfg.Seed.Upgrade

		if cfg.Seed.SeedType == string(client.Nixos) && os.Getenv("USER") != "root" {
			slog.Error("Upgrades for nixos must be run by root")
			os.Exit(1)
		}

		seedClient, err := client.NewSowerClient(cfg.Endpoint, cfg.AccessToken)
		if err != nil {
			slog.Error("Failed to initialize seed client")
			os.Exit(1)
		}

		seed, err := seedClient.GetLatestSeed(cfg.Seed.Name, cfg.Seed.SeedType)
		if err != nil {
			slog.Error("Failed to get seed", "error", err)
			os.Exit(1)
		}

		caches, err := seedClient.GetNixCaches()
		if err != nil {
			slog.Error("Failed to get nix caches", "error", err)
			os.Exit(1)
		}

		if err := realize(seed.Artifact, caches, false, ""); err != nil {
			slog.Error("Failed realizing seed", "error", err)
			os.Exit(1)
		}

		if err := activate(seed.SeedType, seed.Artifact, cmdArgs.Mode); err != nil {
			slog.Error("Failed realizing seed", "error", err)
			os.Exit(1)
		}

		slog.Info("Upgraded seed", "name", cfg.Seed.Name, "type", seed.SeedType, "artifact", seed.Artifact)

		if seed.SeedType == client.Nixos {
			err := reboot(cmdArgs.Yes)
			if err != nil {
				slog.Error("Failed to reboot", "error", err)
				os.Exit(1)
			}
		}
	default:
		return fmt.Errorf("no seed subcommand selected")
	}

	return nil
}

func servicesCommand(cfg config) {
	if len(cfg.Services.Services) == 0 {
		slog.Warn("No services configured")
		os.Exit(0)
	}

	switch {
	case cfg.Services.List != nil:
		seedClient, err := client.NewSowerClient(cfg.Endpoint, cfg.AccessToken)
		if err != nil {
			slog.Error("Failed to initialize seed client")
			os.Exit(1)
		}

		for _, service := range cfg.Services.Services {
			seed, err := seedClient.GetLatestSeed(string(service), string(client.Service))
			if err != nil {
				slog.Error("Failed to get seed", "error", err, "name", string(service), "type", client.Service)
				continue
			}

			slog.Info("Found service", "service", service, "artifact", seed.Artifact)
		}
	case cfg.Services.Upgrade != nil:
		seedClient, err := client.NewSowerClient(cfg.Endpoint, cfg.AccessToken)
		if err != nil {
			slog.Error("Failed to initialize seed client")
			os.Exit(1)
		}

		seeds := []client.Seed{}

		if len(cfg.Services.Services) == 0 {
			slog.Error("No services configured")
			os.Exit(1)
		}

		servicesProfileDir := filepath.Join(profileParentDir(), "services")
		_, err = os.Stat(servicesProfileDir)
		if err != nil {
			slog.Debug("Creating profile directory for services", "path", servicesProfileDir)
			err = os.MkdirAll(servicesProfileDir, 0755)
			if err != nil {
				slog.Error("Failed to create profile directory for services", "error", err)
				os.Exit(1)
			}
		}

		for _, service := range cfg.Services.Services {
			seed, err := seedClient.GetLatestSeed(string(service), string(client.Service))
			if err != nil {
				slog.Error("Failed to get seed", "error", err, "name", string(service), "type", client.Service)
				continue
			}

			slog.Info("Found service", "service", service, "artifact", seed.Artifact)

			caches, err := seedClient.GetNixCaches()
			if err != nil {
				slog.Error("Failed to get nix caches", "error", err)
				os.Exit(1)
			}

			if err := realize(seed.Artifact, caches, false, filepath.Join(servicesProfileDir, string(service))); err != nil {
				slog.Error("Failed realizing seed", "error", err)
				os.Exit(1)
			}

			slog.Info("Downloaded seed", "name", seed.Name, "type", seed.SeedType, "artifact", seed.Artifact)

			seeds = append(seeds, *seed)
		}

		servicesPath, err := buildServicesUnits(seeds)
		if err != nil {
			slog.Error("Failed to build services environment", "error", err)
			os.Exit(1)
		}

		err = activateServices(servicesPath)
		if err != nil {
			slog.Error("Failed to activate services environment", "error", err)
			os.Exit(1)
		}
	}
}

func default_config_path() (string, error) {
	slog.Debug("Finding default configuration file")

	user := os.Getenv("USER")

	switch user {
	case "root":
		return "/etc/sower/client.json", nil
	case "":
		return "", fmt.Errorf("failed to detect user, not loading default config file")
	default:
		return filepath.Join(xdg.ConfigHome, "sower", "client.json"), nil
	}
}
