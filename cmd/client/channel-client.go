package main

import (
	"fmt"
	"log/slog"
	"net/url"

	"github.com/nshafer/phx"
)

type channelClient struct {
	config *config
	socket *phx.Socket
}

func newClient(config *config) *channelClient {
	return &channelClient{config: config}
}

func (c *channelClient) connect() error {
	slog.Debug("Starting daemon")

	endpoint, err := url.Parse(fmt.Sprintf("%s/client", c.config.Endpoint))
	endpoint.RawQuery = fmt.Sprintf("token=%s", url.QueryEscape(c.config.ApiToken))

	socket := phx.NewSocket(endpoint)
	socket.Logger = &logger{}

	// Wait for the socket to connect before continuing. If it's not able to, it will keep
	// retrying forever.
	cont := make(chan bool)
	socket.OnOpen(func() {
		cont <- true
	})
	socket.OnError(func(err error) {
		slog.Error("failed to open socket connection", "error", err)
	})

	// Tell the socket to connect (or start retrying until it can connect)
	err = socket.Connect()
	if err != nil {
		slog.Error("failed to connect to server", "error", err)
	}

	// Wait for the connection
	<-cont

	c.socket = socket

	err = c.joinLobby()
	if err != nil {
		slog.Error("failed to join lobby", "error", err)
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

// func (c *channelClient) submitSeed(seed seed.Seed) error {
// 	cont := make(chan error)
// 	channel := c.socket.Channel("client:all", nil)
//
// 	push, err := channel.Push("seed:submit", seed)
// 	if err != nil {
// 		return fmt.Errorf("failed to push seed:submit")
// 	}
//
// 	push.Receive("ok", func(response any) {
// 		cont <- nil
// 	})
//
// 	push.Receive("error", func(response any) {
// 		cont <- fmt.Errorf("failed to submit seed")
// 	})
//
// 	return <-cont
// }
