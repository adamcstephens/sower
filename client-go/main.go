package main

import (
	"fmt"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/knadh/koanf/parsers/toml/v2"
	"github.com/knadh/koanf/providers/file"
	"github.com/knadh/koanf/providers/posflag"
	"github.com/knadh/koanf/v2"
	"github.com/nshafer/phx"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"

	flag "github.com/spf13/pflag"
)

type config struct {
	endpoint url.URL
}

var conf = koanf.Conf{}

var kConfig = koanf.NewWithConf(conf)

func main() {
	log.Logger = log.Output(zerolog.ConsoleWriter{Out: os.Stderr})

	flags := flag.NewFlagSet("config", flag.ExitOnError)
	flags.Usage = func() {
		fmt.Println(flags.FlagUsages())
		os.Exit(0)
	}
	// TODO fix default config path
	flags.StringSlice("config", []string{"./dev-client.toml"}, "path to one or more toml config files")
	flags.String("bootstrap-token-file", "", "bootstrap token")
	// TODO fix default name and seed_type
	flags.String("name", "", "seed name")
	flags.String("type", "", "seed type")
	flags.Bool("debug", false, "enable debug logging")
	flags.Parse(os.Args[1:])

	// load config files
	configFiles, _ := flags.GetStringSlice("config")
	for _, c := range configFiles {
		if err := kConfig.Load(file.Provider(c), toml.Parser()); err != nil {
			log.Error().Err(err).Msg("error loading config file")
			os.Exit(1)
		}
	}

	// load cli args
	if err := kConfig.Load(posflag.Provider(flags, ".", kConfig), nil); err != nil {
		log.Error().Err(err).Msg("error parsing arguments")
		os.Exit(1)
	}

	zerolog.SetGlobalLevel(zerolog.InfoLevel)
	if kConfig.Bool("debug") {
		zerolog.SetGlobalLevel(zerolog.DebugLevel)
	}

	if kConfig.String("bootstrap-token-file") == "" {
		log.Error().Msg("Missing required bootstrap-token")
		os.Exit(1)
	}
	bootstrapToken, err := readSecret(kConfig.String("bootstrap-token-file"))
	if err != nil {
		log.Error().Msgf("failed to read secret, %v", err)
		os.Exit(1)
	}
	token, err := signToken(bootstrapToken, kConfig.String("name"), kConfig.String("type"))
	if err != nil {
		log.Error().Msgf("failed to sign jwt, %v", err)
		os.Exit(1)
	}

	endpoint, err := url.Parse(fmt.Sprintf("%s/client?token=%s", kConfig.String("url"), token))
	if err != nil {
		log.Error().Msgf("failed to parse URL, %v", err)
		os.Exit(1)
	}

	config := config{
		endpoint: *endpoint,
	}

	run(config)
}

func run(config config) {
	log.Info().Msg("Starting")
	log.Debug().Any("config", config).Msg("")

	socket := phx.NewSocket(&config.endpoint)
	socket.HeartbeatInterval = 60 * time.Second
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

	seedPush, err := dedicatedChannel.Push("seed:submit", map[string]any{"name": "blank", "seed_type": "nixos", "out_path": "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaabb-nixos-system-blank-24.11.20240716.ad0b5ee"})
	if err != nil {
		log.Error().Err(err).Msg("failed to push seed:submit")
	}
	seedPush.Receive("ok", func(response any) {
		log.Info().Msgf("%v", response.(map[string]interface{})["seed_id"].(string))
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
