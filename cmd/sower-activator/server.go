package main

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
)

// Server handles Unix socket connections for activation requests.
type Server struct {
	socketPath  string
	allowedUIDs []uint32
	allowedGIDs []uint32
	listener    net.Listener
	wg          sync.WaitGroup
}

// NewServer creates a new activation server.
func NewServer(socketPath string, allowedUIDs, allowedGIDs []uint32) *Server {
	return &Server{
		socketPath:  socketPath,
		allowedUIDs: allowedUIDs,
		allowedGIDs: allowedGIDs,
	}
}

// Run starts the server and blocks until shutdown.
func (s *Server) Run(ctx context.Context) error {
	// Remove existing socket file if present
	if err := os.Remove(s.socketPath); err != nil && !os.IsNotExist(err) {
		return err
	}

	// Create listener
	var err error
	s.listener, err = net.Listen("unix", s.socketPath)
	if err != nil {
		return err
	}
	defer s.listener.Close()

	// Set socket permissions (owner rw, group rw)
	if err := os.Chmod(s.socketPath, 0660); err != nil {
		return err
	}

	slog.Info("Server listening", "socket", s.socketPath)

	// Handle shutdown
	go func() {
		<-ctx.Done()
		slog.Info("Shutting down server")
		s.listener.Close()
	}()

	// Accept connections
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				break
			}
			slog.Error("Accept error", "error", err)
			continue
		}

		s.wg.Go(func() {
			handler := NewConnectionHandler(conn, s.allowedUIDs, s.allowedGIDs)
			handler.Handle()
		})
	}

	// Wait for active connections to finish
	s.wg.Wait()
	slog.Info("Server stopped")

	return nil
}

// RunServer is the entry point for server mode.
func RunServer(socketPath string, allowedUIDs, allowedGIDs []uint32) error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Handle signals
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigCh
		slog.Info("Received signal", "signal", sig)
		cancel()
	}()

	server := NewServer(socketPath, allowedUIDs, allowedGIDs)
	return server.Run(ctx)
}
