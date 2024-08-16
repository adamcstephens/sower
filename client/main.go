package main

import (
	_ "embed"
	"fmt"
	"os"

	"codeberg.org/adamcstephens/sower/client/seed"
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
			run(config)
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
	var seedDownloadCommand = &cobra.Command{
		Use:   "download",
		Short: "Download a seed",
		Run: func(cmd *cobra.Command, args []string) {
			name, err := cmd.Flags().GetString("name")
			if err != nil {
				log.Error().Err(err).Msg("Failed loading seed name")
				os.Exit(1)
			}
			if name == "" {
				name = seed.DefaultName()
			}

			seedType, err := cmd.Flags().GetString("type")
			if err != nil {
				log.Error().Err(err).Msg("Failed loading seed type")
				os.Exit(1)
			}
			if seedType == "" {
				seedType = seed.DefaultType()
			}

			wantedSeed := seed.NewSeed(name, seedType, "")

			if err := wantedSeed.Download(); err != nil {
				log.Error().Err(err).Msg("Failed downloading seed")
				os.Exit(1)
			}
		},
	}
	seedCmd.AddCommand(seedDownloadCommand)
	seedDownloadCommand.Flags().String("name", "", "seed name")
	seedDownloadCommand.Flags().String("type", "", "seed type")

	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
