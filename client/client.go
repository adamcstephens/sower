package main

import (
	"fmt"
	"net/url"

	"codeberg.org/adamcstephens/sower/client/seed"
	"github.com/golang-jwt/jwt/v5"
	"github.com/nshafer/phx"
	"github.com/rs/zerolog/log"
)

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

func signToken(bootstrapToken, name, seedType string) (string, error) {
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"name":      name,
		"seed_type": seedType,
	})

	return token.SignedString([]byte(bootstrapToken))
}
