package main

import (
	_ "embed"
	"fmt"
	"net/url"
	"os"
	"strings"

	"codeberg.org/adamcstephens/sower/client/seed"
	"github.com/golang-jwt/jwt/v5"
	"github.com/knadh/koanf/parsers/toml/v2"
	"github.com/knadh/koanf/providers/file"
	"github.com/knadh/koanf/providers/posflag"
	"github.com/knadh/koanf/v2"
	"github.com/nshafer/phx"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"

	"github.com/spf13/cobra"
	flag "github.com/spf13/pflag"
)

var version string

type config struct {
	bootstrapToken string
	endpoint       url.URL
	stateDirectory string
}

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

func initRootConfig(flags *flag.FlagSet) (*config, error) {
	var conf = koanf.Conf{}
	var kConfig = koanf.NewWithConf(conf)

	// load config files
	configFiles, _ := flags.GetStringSlice("config")
	if len(configFiles) == 0 {
		return &config{}, fmt.Errorf("No config files provided")
	}
	for _, c := range configFiles {
		if err := kConfig.Load(file.Provider(c), toml.Parser()); err != nil {
			return &config{}, fmt.Errorf("error loading config file")
		}
	}

	// load cli args
	if err := kConfig.Load(posflag.Provider(flags, ".", kConfig), nil); err != nil {
		return &config{}, fmt.Errorf("error parsing arguments")
	}

	zerolog.SetGlobalLevel(zerolog.InfoLevel)
	debug, err := flags.GetBool("debug")
	if err != nil {
		return &config{}, fmt.Errorf("Failed to parse debug: %v", err)
	}
	if debug {
		zerolog.SetGlobalLevel(zerolog.DebugLevel)
	}

	if kConfig.String("bootstrap-token-file") == "" {
		return &config{}, fmt.Errorf("Missing required bootstrap-token")
	}
	bootstrapToken, err := readSecret(kConfig.String("bootstrap-token-file"))
	if err != nil {
		return &config{}, fmt.Errorf("failed to read secret, %v", err)
	}

	endpoint, err := url.Parse(fmt.Sprintf("%s/client", kConfig.String("url")))
	if err != nil {
		return &config{}, fmt.Errorf("failed to parse URL, %v", err)
	}

	stateDirectory := kConfig.String("state-directory")

	config := &config{
		bootstrapToken: bootstrapToken,
		endpoint:       *endpoint,
		stateDirectory: stateDirectory,
	}

	log.Debug().Any("config", config).Msg("")

	return config, nil
}

func run(config *config) {
	log.Info().Msg("Starting")

	endpoint := config.endpoint
	token, _ := signToken(config.bootstrapToken, "name", "type")
	endpoint.RawQuery = fmt.Sprintf("token=%s", url.QueryEscape(token))

	socket := phx.NewSocket(&endpoint)
	zerologLogger := logger{}
	socket.Logger = &zerologLogger

	// Wait for the socket to connect before continuing. If it's not able to, it will keep
	// retrying forever.
	cont := make(chan bool)
	socket.OnOpen(func() {
		cont <- true
	})
	socket.OnError(func(err error) {
		log.Error().Err(err).Msg("failed to open socket connection")
	})

	// Tell the socket to connect (or start retrying until it can connect)
	err := socket.Connect()
	if err != nil {
		log.Error().Err(err).Msg("failed to connect to server")
	}

	// Wait for the connection
	<-cont

	tree_id, err := joinLobby(socket)
	if err != nil {
		log.Error().Err(err).Msg("failed to join lobby")
	}

	dedicatedChannel, err := joinDedicated(socket, tree_id)
	if err != nil {
		log.Error().Err(err).Msg("failed to join dedicated channel")
	}

	seed := seed.NewSeed("blank", "home-manager", "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaabb-nixos-system-blank-24.11.20240716.ad0b5ee")
	seedPush, err := dedicatedChannel.Push("seed:submit", seed)
	if err != nil {
		log.Error().Err(err).Msg("failed to push seed:submit")
	}
	seedPush.Receive("ok", func(response any) {
		seed_id := response.(map[string]interface{})["seed_id"].(string)
		log.Info().Any("seed", seed).Str("seed_id", seed_id).Msgf("Received seed id")
		if err := seed.Download(); err != nil {
			log.Error().Err(err).Msg("")
		}
	})

	select {}
}

func joinLobby(socket *phx.Socket) (string, error) {
	cont := make(chan bool)
	treeChan := make(chan string)
	channel := socket.Channel("client:all", nil)

	// server sends this message immediately after join, so subscribe prior to joining
	channel.On("tree:id", func(response any) {
		treeChan <- response.(map[string]interface{})["tree_id"].(string)
	})

	join, err := channel.Join()
	if err != nil {
		return "", fmt.Errorf("failed to join client:all")
	}

	// ensure successfully joined
	join.Receive("ok", func(response any) {
		cont <- true
	})

	<-cont

	return <-treeChan, nil
}

func joinDedicated(socket *phx.Socket, tree_id string) (*phx.Channel, error) {
	cont := make(chan bool)
	channelName := fmt.Sprintf("client:%s", tree_id)
	channel := socket.Channel(channelName, map[string]string{"tree_id": tree_id})

	join, err := channel.Join()
	if err != nil {
		return nil, fmt.Errorf("failed to join %s", channelName)
	}

	join.Receive("ok", func(response any) {
		cont <- true
	})

	<-cont

	return channel, nil
}

func readSecret(path string) (string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}

	return strings.TrimSpace(string(content)), nil
}

func signToken(bootstrapToken, name, seedType string) (string, error) {
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"name":      name,
		"seed_type": seedType,
	})

	return token.SignedString([]byte(bootstrapToken))
}
