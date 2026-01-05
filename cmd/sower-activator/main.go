package main

import (
	"flag"
	"log/slog"
	"os"
	"time"
)

func main() {
	// Define command-line flags
	var (
		seedType = flag.String("type", "", "Seed type (nixos, home-manager)")
		path     = flag.String("path", "", "Nix store path to activate")
		mode     = flag.String("mode", "switch", "Activation mode for NixOS (switch, boot, test, etc.)")
		debug    = flag.Bool("debug", false, "Enable debug logging")
	)

	flag.Parse()

	// Setup logger
	initLogger(*debug)

	// Validate required arguments
	if *seedType == "" {
		slog.Error("Missing required flag: --type")
		flag.Usage()
		os.Exit(1)
	}

	if *path == "" {
		slog.Error("Missing required flag: --path")
		flag.Usage()
		os.Exit(1)
	}

	// Validate seed type
	if *seedType != SeedTypeNixOS && *seedType != SeedTypeHomeManager {
		slog.Error("Invalid seed type. Must be 'nixos' or 'home-manager'", "type", *seedType)
		os.Exit(1)
	}

	// Check if running as root for NixOS
	if *seedType == SeedTypeNixOS && os.Getuid() != 0 {
		slog.Error("NixOS activation must be run as root")
		os.Exit(1)
	}

	// Log what we're about to do
	slog.Info("Activating seed", "type", *seedType, "path", *path, "mode", *mode)

	// Perform activation
	err := activate(*seedType, *path, *mode)
	if err != nil {
		slog.Error("Activation failed", "error", err)
		os.Exit(1)
	}

	slog.Info("Activation complete", "type", *seedType, "path", *path)
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
