package main

import (
	_ "embed"
	"fmt"
	"os"

	"codeberg.org/adamcstephens/sower/client"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"

	"github.com/spf13/cobra"
)

var version string

func main() {
	log.Logger = log.Output(zerolog.ConsoleWriter{Out: os.Stderr})

	var config *config

	var rootCmd = &cobra.Command{
		Use:   "sower",
		Short: "sower client",
		PersistentPreRunE: func(cmd *cobra.Command, args []string) error {
			var err error

			// load the configuration for every subcommand
			config, err = initRootConfig(cmd.Flags())
			if err != nil {
				return fmt.Errorf("Failed loading configuration, %v", err)
			}

			return nil
		},
	}
	rootCmd.PersistentFlags().Bool("debug", false, "enable debug logging")
	rootCmd.PersistentFlags().StringSlice("config", []string{}, "path to toml config file, repeatable")

	var versionCmd = &cobra.Command{
		Use:   "version",
		Short: "Print the version",
		Run: func(cmd *cobra.Command, args []string) {
			if version == "" {
				fmt.Println("dev")
			} else {
				fmt.Println(version)
			}
		},
	}
	rootCmd.AddCommand(versionCmd)

	var daemonCmd = &cobra.Command{
		Use:   "daemon",
		Short: "Run the daemon",
		Run: func(cmd *cobra.Command, args []string) {
			client := newClient(config)

			err := client.connect()
			if err != nil {
				log.Error().Err(err).Msg("failed to connect")
			}

			client.run()
		},
	}
	rootCmd.AddCommand(daemonCmd)

	var seedCmd = &cobra.Command{
		Use:   "seed",
		Short: "Run seed related actions",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Println(args)
		},
	}
	rootCmd.AddCommand(seedCmd)

	var seedCreateCommand = &cobra.Command{
		Use:   "create name seed_type",
		Short: "Create a seed",
		PreRunE: func(cmd *cobra.Command, args []string) error {
			if len(args) != 2 {
				return fmt.Errorf("Expected 2 arguments, got %d", len(args))
			}
			return nil
		},
		Run: func(cmd *cobra.Command, args []string) {
			name := args[0]
			seedType := args[1]

			seedClient, err := client.NewSeedClient(config.apiEndpoint.String(), config.apiToken)
			if err != nil {
				log.Error().Err(err).Msg("Failed to initialize seed client")
				os.Exit(1)
			}

			seed, err := seedClient.CreateSeed(name, seedType)
			if err != nil {
				log.Error().Err(err).Msg("Failed to create seed")
				os.Exit(1)
			}

			log.Info().Any("seed", seed).Msg("created")
		},
	}
	seedCmd.AddCommand(seedCreateCommand)

	var seedDownloadCommand = &cobra.Command{
		Use:   "download id",
		Short: "Download a seed",
		Run: func(cmd *cobra.Command, args []string) {
			var id, name, seedType string
			if len(args) == 0 {
				name, _ = cmd.Flags().GetString("name")
				seedType, _ = cmd.Flags().GetString("type")
			} else if len(args) == 1 {
				id = args[0]
			} else {
				log.Error().Msg("Unknown extra arguments")
				os.Exit(1)
			}

			seedClient, err := client.NewSeedClient(config.apiEndpoint.String(), config.apiToken)
			if err != nil {
				log.Error().Err(err).Msg("Failed to initialize seed client")
				os.Exit(1)
			}

			s, err := seedClient.GetSeed(id, name, seedType)
			if err != nil {
				log.Error().Err(err).Msg("Failed to get seed")
				os.Exit(1)
			}

			path, err := seedClient.GetSeedLatestPath(s)
			if err != nil {
				log.Error().Err(err).Msg("Failed to get seed path")
				os.Exit(1)
			}

			if err := Realize(path.Path); err != nil {
				log.Error().Err(err).Msg("Failed realizing seed")
				os.Exit(1)
			}
		},
	}
	seedCmd.AddCommand(seedDownloadCommand)

	var seedInfoCommand = &cobra.Command{
		Use:   "info id",
		Short: "Display seed information",
		Run: func(cmd *cobra.Command, args []string) {
			var id, name, seedType string
			if len(args) == 0 {
				name, _ = cmd.Flags().GetString("name")
				seedType, _ = cmd.Flags().GetString("type")
			} else if len(args) == 1 {
				id = args[0]
			} else {
				log.Error().Msg("Unknown extra arguments")
				os.Exit(1)
			}

			seedClient, err := client.NewSeedClient(config.apiEndpoint.String(), config.apiToken)
			if err != nil {
				log.Error().Err(err).Msg("Failed to initialize seed client")
				os.Exit(1)
			}

			s, err := seedClient.GetSeed(id, name, seedType)
			if err != nil {
				log.Error().Err(err).Msg("Failed to get seed")
				os.Exit(1)
			}

			path, err := seedClient.GetSeedLatestPath(s)
			if err != nil {
				log.Error().Err(err).Msg("Failed to get seed path")
				os.Exit(1)
			}

			fmt.Printf("Seed: %v\n", s)
			fmt.Printf("Path: %v\n", path)
		},
	}
	seedCmd.AddCommand(seedInfoCommand)
	seedInfoCommand.Flags().String("name", "", "seed name")
	seedInfoCommand.Flags().String("type", "", "seed type")

	var seedSubmitCommand = &cobra.Command{
		Use:   "submit name type out_path",
		Short: "submit a seed",
		PreRunE: func(cmd *cobra.Command, args []string) error {
			if len(args) != 3 {
				return fmt.Errorf("Expected 3 arguments, got %d", len(args))
			}
			return nil
		},
		Run: func(cmd *cobra.Command, args []string) {
			log.Debug().Any("args", args).Msg("submit seed")

			seedClient, err := client.NewSeedClient(config.apiEndpoint.String(), config.apiToken)
			if err != nil {
				log.Error().Err(err).Msg("Failed to initialize seed client")
				os.Exit(1)
			}

			s, err := seedClient.GetSeed("", args[0], args[1])
			if err != nil {
				log.Error().Err(err).Msg("Failed to get seed")
				os.Exit(1)
			}

			_, err = seedClient.SubmitSeedPath(s, args[2])
			if err != nil {
				log.Error().Err(err).Msg("Failed submitting seed")
				os.Exit(1)
			}

			log.Info().Any("args", args).Msg("Submitted seed")
		},
	}
	seedCmd.AddCommand(seedSubmitCommand)
	seedCmd.Flags().Bool("create", false, "create seed on submission")

	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
