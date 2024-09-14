package main

import (
	"context"
	_ "embed"
	"fmt"
	"net/http"
	"os"

	"codeberg.org/adamcstephens/sower/client/client"
	"codeberg.org/adamcstephens/sower/client/seed"
	"github.com/google/uuid"
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
	var seedDownloadCommand = &cobra.Command{
		Use:   "download id",
		Short: "Download a seed",
		Run: func(cmd *cobra.Command, args []string) {
			var hc = http.Client{}

			c, err := client.NewClientWithResponses("http://localhost:7150", client.WithHTTPClient(&hc))
			if err != nil {
				log.Error().Err(err).Msg("Failed to create client")
				os.Exit(1)
			}

			id, err := uuid.Parse(args[0])
			if err != nil {
				log.Error().Err(err).Msg("Failed to parse uuid")
				return
			}

			resp, err := c.GetSeedWithResponse(context.TODO(), id.String())
			if err != nil {
				log.Error().Err(err).Any("resp", resp).Msg("Failed getting seed")
				os.Exit(1)
			}
			if resp.StatusCode() != http.StatusOK {
				log.Error().Msg("Failed finding seed")
				os.Exit(1)
			}
			newSeed := resp.JSON200

			pathResp, err := c.LatestStorePathBySeedWithResponse(context.TODO(), newSeed.Id.String())
			if err != nil {
				os.Exit(1)
			}
			if resp.StatusCode() != http.StatusOK {
				log.Error().Msg("Failed finding seed")
				os.Exit(1)
			}
			path := pathResp.JSON200
			log.Debug().Any("path", path).Any("seed", newSeed).Msg("Found path for seed")

			wantedSeed := seed.NewSeed(newSeed, path)

			if err := wantedSeed.Download(); err != nil {
				log.Error().Err(err).Msg("Failed downloading seed")
				os.Exit(1)
			}
		},
	}

	seedCmd.AddCommand(seedDownloadCommand)
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

			newSeed := client.Seed{
				Name:     args[0],
				SeedType: args[1],
			}

			c, err := client.NewClientWithResponses(config.apiEndpoint.String())
			if err != nil {
				log.Error().Err(err).Msg("Failed to create client")
				os.Exit(1)
			}

			resp, err := c.NewSeedWithResponse(context.TODO(), newSeed)
			if err != nil {
				os.Exit(1)
			}
			if resp.StatusCode() != http.StatusCreated {
				log.Error().Msg("Failed submitting seed")
				os.Exit(1)
			}

			fmt.Printf("resp.JSON200: %v\n", resp.JSON200)
		},
	}
	seedCmd.AddCommand(seedSubmitCommand)

	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
