package main

import (
	"fmt"
	"net/url"

	"codeberg.org/adamcstephens/sower/client/seed"

	"github.com/golang-jwt/jwt/v5"
	"github.com/nshafer/phx"
	"github.com/rs/zerolog/log"
)

type channelClient struct {
	config *config
	socket *phx.Socket
}

func newClient(config *config) *channelClient {
	return &channelClient{config: config}
}

func (c *channelClient) connect() error {
	log.Info().Msg("Starting")

	endpoint := c.config.channelEndpoint
	token, _ := signToken(c.config.bootstrapToken, "name", "type")
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

	c.socket = socket

	err = c.joinLobby()
	if err != nil {
		log.Error().Err(err).Msg("failed to join lobby")
	}

	return nil
}

func (c *channelClient) run() {
	select {}
}

func (c *channelClient) joinLobby() error {
	cont := make(chan bool)
	channel := c.socket.Channel("client:all", nil)

	join, err := channel.Join()
	if err != nil {
		return fmt.Errorf("failed to join client:all")
	}

	// ensure successfully joined
	join.Receive("ok", func(response any) {
		cont <- true
	})

	<-cont

	return nil
}

func (c *channelClient) submitSeed(seed seed.Seed) error {
	cont := make(chan error)
	channel := c.socket.Channel("client:all", nil)

	push, err := channel.Push("seed:submit", seed)
	if err != nil {
		return fmt.Errorf("failed to push seed:submit")
	}

	push.Receive("ok", func(response any) {
		cont <- nil
	})

	push.Receive("error", func(response any) {
		cont <- fmt.Errorf("failed to submit seed")
	})

	return <-cont
}

func signToken(bootstrapToken, name, seedType string) (string, error) {
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"name":      name,
		"seed_type": seedType,
	})

	return token.SignedString([]byte(bootstrapToken))
}
