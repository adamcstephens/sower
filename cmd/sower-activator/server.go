package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
)

var errSystemdSocketUnavailable = errors.New("systemd socket activation unavailable")

const systemdListenFDStart = 3

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
	listener, err := listenerFromSystemd()
	if err != nil && !errors.Is(err, errSystemdSocketUnavailable) {
		return err
	}

	if errors.Is(err, errSystemdSocketUnavailable) {
		// Remove existing socket file if present
		if err := os.Remove(s.socketPath); err != nil && !os.IsNotExist(err) {
			return err
		}

		// Create listener when not socket-activated
		listener, err = net.Listen("unix", s.socketPath)
		if err != nil {
			return err
		}

		// Set socket permissions (owner rw, group rw)
		if err := os.Chmod(s.socketPath, 0660); err != nil {
			return err
		}

		slog.Info("Server listening", "socket", s.socketPath, "mode", "standalone")
	} else {
		slog.Info("Server listening", "socket", s.socketPath, "mode", "systemd-socket-activation")
	}

	s.listener = listener
	defer s.listener.Close()

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

func listenerFromSystemd() (net.Listener, error) {
	pidStr := os.Getenv("LISTEN_PID")
	fdsStr := os.Getenv("LISTEN_FDS")
	if pidStr == "" && fdsStr == "" {
		return nil, errSystemdSocketUnavailable
	}
	if pidStr == "" || fdsStr == "" {
		return nil, fmt.Errorf("incomplete systemd socket activation environment")
	}

	listenPID, err := strconv.Atoi(pidStr)
	if err != nil {
		return nil, fmt.Errorf("invalid LISTEN_PID: %w", err)
	}
	if listenPID != os.Getpid() {
		return nil, errSystemdSocketUnavailable
	}

	listenFDs, err := strconv.Atoi(fdsStr)
	if err != nil {
		return nil, fmt.Errorf("invalid LISTEN_FDS: %w", err)
	}
	if listenFDs <= 0 {
		return nil, errSystemdSocketUnavailable
	}
	if listenFDs != 1 {
		return nil, fmt.Errorf("expected exactly 1 socket from systemd, got %d", listenFDs)
	}

	_ = os.Unsetenv("LISTEN_PID")
	_ = os.Unsetenv("LISTEN_FDS")
	_ = os.Unsetenv("LISTEN_FDNAMES")

	file := os.NewFile(uintptr(systemdListenFDStart), "systemd-activator-socket")
	if file == nil {
		return nil, fmt.Errorf("failed to access systemd socket FD")
	}
	defer file.Close()

	listener, err := net.FileListener(file)
	if err != nil {
		return nil, fmt.Errorf("creating listener from systemd socket: %w", err)
	}

	if _, ok := listener.(*net.UnixListener); !ok {
		listener.Close()
		return nil, fmt.Errorf("systemd socket is not a unix listener")
	}

	return listener, nil
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
