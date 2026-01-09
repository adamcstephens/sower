package main

import (
	"flag"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"time"
)

func main() {
	// Define command-line flags
	var (
		// Server mode flags
		serverMode  = flag.Bool("server", false, "Run as server daemon")
		socketPath  = flag.String("socket", "/run/sower-activator/activator.sock", "Unix socket path")
		allowedUIDs = flag.String("allowed-uids", "", "Comma-separated list of allowed UIDs")
		allowedGIDs = flag.String("allowed-gids", "", "Comma-separated list of allowed GIDs")

		// CLI mode flags
		seedType = flag.String("type", "", "Seed type (nixos, home-manager)")
		path     = flag.String("path", "", "Nix store path to activate")
		mode     = flag.String("mode", "switch", "Activation mode for NixOS (switch, boot, test, etc.)")

		// Common flags
		debug = flag.Bool("debug", false, "Enable debug logging")
	)

	flag.Parse()

	// Setup logger
	initLogger(*debug)

	if *serverMode {
		runServerMode(*socketPath, *allowedUIDs, *allowedGIDs)
	} else {
		runCLIMode(*seedType, *path, *mode)
	}
}

func runServerMode(socketPath, allowedUIDsStr, allowedGIDsStr string) {
	// Check if running as root
	if os.Getuid() != 0 {
		slog.Error("Server mode must be run as root")
		os.Exit(1)
	}

	uids, err := parseIDList(allowedUIDsStr)
	if err != nil {
		slog.Error("Invalid allowed-uids", "error", err)
		os.Exit(1)
	}

	gids, err := parseIDList(allowedGIDsStr)
	if err != nil {
		slog.Error("Invalid allowed-gids", "error", err)
		os.Exit(1)
	}

	if err := RunServer(socketPath, uids, gids); err != nil {
		slog.Error("Server error", "error", err)
		os.Exit(1)
	}
}

func runCLIMode(seedType, path, mode string) {
	// Validate required arguments
	if seedType == "" {
		slog.Error("Missing required flag: --type")
		flag.Usage()
		os.Exit(1)
	}

	if path == "" {
		slog.Error("Missing required flag: --path")
		flag.Usage()
		os.Exit(1)
	}

	// Validate seed type
	if seedType != SeedTypeNixOS && seedType != SeedTypeHomeManager {
		slog.Error("Invalid seed type. Must be 'nixos' or 'home-manager'", "type", seedType)
		os.Exit(1)
	}

	// Check if running as root for NixOS
	if seedType == SeedTypeNixOS && os.Getuid() != 0 {
		slog.Error("NixOS activation must be run as root")
		os.Exit(1)
	}

	// Log what we're about to do
	slog.Info("Activating seed", "type", seedType, "path", path, "mode", mode)

	// Perform activation
	err := activate(seedType, path, mode)
	if err != nil {
		slog.Error("Activation failed", "error", err)
		os.Exit(1)
	}

	slog.Info("Activation complete", "type", seedType, "path", path)
}

// parseIDList parses a comma-separated list of IDs into a slice of uint32.
func parseIDList(s string) ([]uint32, error) {
	if s == "" {
		return nil, nil
	}

	parts := strings.Split(s, ",")
	result := make([]uint32, 0, len(parts))

	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		id, err := strconv.ParseUint(p, 10, 32)
		if err != nil {
			return nil, err
		}
		result = append(result, uint32(id))
	}

	return result, nil
}

func initLogger(debug bool) {
	logLevel := slog.LevelInfo
	if debug {
		logLevel = slog.LevelDebug
	}

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level: logLevel,
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			// Format time more compactly
			if a.Key == slog.TimeKey {
				return slog.Attr{
					Key:   a.Key,
					Value: slog.StringValue(time.Now().Format(time.DateTime)),
				}
			}
			return a
		},
	}))

	slog.SetDefault(logger)
}
