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
	Seed *seedCmd `arg:"subcommand:seed"`

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
	Path string `arg:"--path,-p,required"`
}

func main() {
	var args config
	p, err := arg.NewParser(arg.Config{}, &args)
	if err != nil {
		log.Fatalf("Fatal error in argument specification")
		os.Exit(1)
	}
	err = p.Parse(os.Args[1:])

	logLevel := slog.LevelInfo
	if args.Debug {
		logLevel = slog.LevelDebug
	}

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: logLevel}))
	slog.SetDefault(logger)

	slog.Debug("Loaded args", "args", args)

	if args.ApiToken == "" && args.ApiTokenFile != "" {
		slog.Debug("Reading api-token file", "file", args.ApiTokenFile)

		token, err := os.ReadFile(args.ApiTokenFile)
		if err != nil {
			slog.Error("Failed to read token file", "file", args.ApiTokenFile)
			os.Exit(1)
		}

		args.ApiToken = strings.TrimSpace(string(token))
	}

	switch {
	case args.Version:
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
	case args.Seed != nil:
		seedSubcommand(args)
	default:
		p.WriteHelp(os.Stdout)
	}
}

func seedSubcommand(args config) {
	switch {
	case args.Seed.Create != nil:
		cmdArgs := args.Seed.Create

		seedClient, err := client.NewSeedClient(args.Endpoint, args.ApiToken)
		if err != nil {
			slog.Error("Failed to initialize seed client")
			os.Exit(1)
		}

		s, err := seedClient.CreateSeed(cmdArgs.Name, cmdArgs.SeedType)
		if err != nil {
			slog.Error("Failed to create seed", "error", err)
			os.Exit(1)
		}

		slog.Info("Created seed", "name", cmdArgs.Name, "type", cmdArgs.SeedType, "id", s.Id)

	case args.Seed.Download != nil:
		cmdArgs := args.Seed.Download

		seedClient, err := client.NewSeedClient(args.Endpoint, args.ApiToken)
		if err != nil {
			slog.Error("Failed to initialize seed client")
			os.Exit(1)
		}

		s, err := seedClient.GetSeed(cmdArgs.Name, cmdArgs.SeedType)
		if err != nil {
			slog.Error("Failed to get seed", "error", err)
			os.Exit(1)
		}

		storePath, err := seedClient.GetSeedLatestPath(s)
		if err != nil {
			slog.Error("Failed to get seed store path", "error", err)
			os.Exit(1)
		}

		if err := Realize(storePath.Path); err != nil {
			slog.Error("Failed realizing seed", "error", err)
			os.Exit(1)
		}

		slog.Info("Downloaded seed", "name", cmdArgs.Name, "type", cmdArgs.SeedType, "path", storePath.Path)

	case args.Seed.Info != nil:
		cmdArgs := args.Seed.Info

		seedClient, err := client.NewSeedClient(args.Endpoint, args.ApiToken)
		if err != nil {
			slog.Error("Failed to initialize seed client", "error", err)
			os.Exit(1)
		}

		s, err := seedClient.GetSeed(cmdArgs.Name, cmdArgs.SeedType)
		if err != nil {
			slog.Error("Failed to get seed", "error", err)
			os.Exit(1)
		}

		storePath, err := seedClient.GetSeedLatestPath(s)
		if err != nil {
			slog.Error("Failed to get seed store path", "error", err)
			os.Exit(1)
		}

		slog.Info("Found seed", "name", cmdArgs.Name, "type", cmdArgs.SeedType, "path", storePath.Path)

	case args.Seed.Submit != nil:
		cmdArgs := args.Seed.Submit

		seedClient, err := client.NewSeedClient(args.Endpoint, args.ApiToken)
		if err != nil {
			slog.Error("Failed to initialize seed client", "error", err)
			os.Exit(1)
		}

		s, err := seedClient.GetSeed(cmdArgs.Name, cmdArgs.SeedType)
		if err != nil {
			slog.Error("Failed to get seed", "error", err)
			os.Exit(1)
		}

		storePath, err := seedClient.SubmitSeedPath(s, cmdArgs.Path)
		if err != nil {
			slog.Error("Failed submitting seed")
			os.Exit(1)
		}

		slog.Info("Submitted seed", "name", cmdArgs.Name, "type", cmdArgs.SeedType, "path", storePath.Path)
	}
}

// func daemonCommand(args args) {
// 	client := newClient(config)
//
// 	err := client.connect()
// 	if err != nil {
// 		slog.Error("failed to connect")
// 	}
//
// 	client.run()
// }
