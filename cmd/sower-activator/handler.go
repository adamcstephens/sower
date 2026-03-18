package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// ConnectionHandler handles a single client connection.
type ConnectionHandler struct {
	conn        net.Conn
	allowedUIDs []uint32
	allowedGIDs []uint32
	encoder     *json.Encoder
}

// NewConnectionHandler creates a new handler for a connection.
func NewConnectionHandler(conn net.Conn, allowedUIDs, allowedGIDs []uint32) *ConnectionHandler {
	return NewConnectionHandlerWithWriter(conn, conn, allowedUIDs, allowedGIDs)
}

// NewConnectionHandlerWithWriter creates a new handler with explicit response writer.
func NewConnectionHandlerWithWriter(conn net.Conn, writer io.Writer, allowedUIDs, allowedGIDs []uint32) *ConnectionHandler {
	return &ConnectionHandler{
		conn:        conn,
		allowedUIDs: allowedUIDs,
		allowedGIDs: allowedGIDs,
		encoder:     json.NewEncoder(writer),
	}
}

// Handle processes a single request on the connection.
func (h *ConnectionHandler) Handle() {
	defer h.conn.Close()

	// Get peer credentials
	creds, err := GetPeerCredentials(h.conn)
	if err != nil {
		slog.Error("Failed to get peer credentials", "error", err)
		h.sendError("", "failed to get peer credentials")
		return
	}

	slog.Debug("Connection from peer", "pid", creds.PID, "uid", creds.UID, "gid", creds.GID)

	// Check authorization
	if !IsAuthorized(creds, h.allowedUIDs, h.allowedGIDs) {
		slog.Warn("Unauthorized connection attempt", "uid", creds.UID, "gid", creds.GID)
		h.sendError("", "unauthorized")
		return
	}

	// Read request
	reader := bufio.NewReader(h.conn)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		slog.Error("Failed to read request", "error", err)
		h.sendError("", "failed to read request")
		return
	}

	var req Request
	if err := json.Unmarshal(line, &req); err != nil {
		slog.Error("Failed to parse request", "error", err)
		h.sendError("", "invalid JSON")
		return
	}

	slog.Info(
		"Received request",
		"id",
		req.ID,
		"type",
		req.Type,
		"path",
		req.Path,
		"mode",
		req.Mode,
		"reason",
		req.Reason,
	)

	// Validate request
	if err := h.validateRequest(&req); err != nil {
		slog.Warn("Invalid request", "id", req.ID, "error", err)
		h.sendError(req.ID, err.Error())
		return
	}

	// Execute request with streaming output
	exitCode := h.executeRequest(&req)
	h.sendComplete(req.ID, exitCode)
}

// validateRequest checks that the request is valid.
func (h *ConnectionHandler) validateRequest(req *Request) error {
	if req.ID == "" {
		return fmt.Errorf("missing request ID")
	}

	if req.Type == "reboot" {
		return nil
	}

	if req.Type != SeedTypeNixOS && req.Type != SeedTypeHomeManager {
		return fmt.Errorf("invalid type: %s", req.Type)
	}

	// Validate store path
	if !strings.HasPrefix(req.Path, "/nix/store/") {
		return fmt.Errorf("path must be in /nix/store")
	}

	// Clean and re-validate to prevent path traversal
	cleaned := filepath.Clean(req.Path)
	if !strings.HasPrefix(cleaned, "/nix/store/") {
		return fmt.Errorf("invalid path")
	}
	req.Path = cleaned

	// Validate mode for NixOS
	if req.Type == SeedTypeNixOS {
		validModes := []string{"switch", "boot", "test", "dry-activate"}
		if !slices.Contains(validModes, req.Mode) {
			return fmt.Errorf("invalid mode: %s", req.Mode)
		}
	}

	return nil
}

// callbackSlogHandler tees slog records to an OutputCallback in addition to
// delegating to an underlying handler (e.g. the stderr text handler).
type callbackSlogHandler struct {
	base     slog.Handler
	callback OutputCallback
}

func (h *callbackSlogHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.base.Enabled(ctx, level)
}

func (h *callbackSlogHandler) Handle(ctx context.Context, r slog.Record) error {
	var sb strings.Builder
	sb.WriteString(r.Time.UTC().Format(time.RFC3339))
	sb.WriteString(" [activator] ")
	sb.WriteString(r.Message)
	r.Attrs(func(a slog.Attr) bool {
		sb.WriteString(" ")
		sb.WriteString(a.String())
		return true
	})
	h.callback(sb.String(), r.Level >= slog.LevelError)
	return h.base.Handle(ctx, r)
}

func (h *callbackSlogHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &callbackSlogHandler{base: h.base.WithAttrs(attrs), callback: h.callback}
}

func (h *callbackSlogHandler) WithGroup(name string) slog.Handler {
	return &callbackSlogHandler{base: h.base.WithGroup(name), callback: h.callback}
}

// executeRequest runs the request action and streams output.
func (h *ConnectionHandler) executeRequest(req *Request) int {
	outputCallback := func(line string, isError bool) {
		respType := ResponseTypeOutput
		if isError {
			respType = ResponseTypeError
		}
		h.sendResponse(ActivateResponse{
			ID:   req.ID,
			Type: respType,
			Data: line,
		})
	}

	// Tee activator slog messages into the output stream for this request.
	orig := slog.Default()
	slog.SetDefault(slog.New(&callbackSlogHandler{base: orig.Handler(), callback: outputCallback}))
	defer slog.SetDefault(orig)

	var (
		exitCode int
		err      error
	)

	if req.Type == "reboot" {
		exitCode, err = rebootStreaming(outputCallback)
	} else {
		exitCode, err = activateStreaming(req.Type, req.Path, req.Mode, outputCallback)
	}

	if err != nil {
		slog.Error("Request failed", "id", req.ID, "type", req.Type, "error", err)
		h.sendResponse(ActivateResponse{
			ID:   req.ID,
			Type: ResponseTypeError,
			Data: err.Error(),
		})
	}

	return exitCode
}

// sendResponse sends a response to the client.
func (h *ConnectionHandler) sendResponse(resp ActivateResponse) {
	if err := h.encoder.Encode(resp); err != nil {
		slog.Error("Failed to send response", "error", err)
	}
}

// sendError sends an error response.
func (h *ConnectionHandler) sendError(id, message string) {
	h.sendResponse(ActivateResponse{
		ID:   id,
		Type: ResponseTypeError,
		Data: message,
	})
}

// sendComplete sends a completion response.
func (h *ConnectionHandler) sendComplete(id string, exitCode int) {
	h.sendResponse(ActivateResponse{
		ID:       id,
		Type:     ResponseTypeComplete,
		ExitCode: &exitCode,
	})
}
