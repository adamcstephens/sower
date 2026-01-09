package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"path/filepath"
	"slices"
	"strings"
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
	return &ConnectionHandler{
		conn:        conn,
		allowedUIDs: allowedUIDs,
		allowedGIDs: allowedGIDs,
		encoder:     json.NewEncoder(conn),
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

	var req ActivateRequest
	if err := json.Unmarshal(line, &req); err != nil {
		slog.Error("Failed to parse request", "error", err)
		h.sendError("", "invalid JSON")
		return
	}

	slog.Info("Received activation request", "id", req.ID, "type", req.Type, "path", req.Path, "mode", req.Mode)

	// Validate request
	if err := h.validateRequest(&req); err != nil {
		slog.Warn("Invalid request", "id", req.ID, "error", err)
		h.sendError(req.ID, err.Error())
		return
	}

	// Execute activation with streaming output
	exitCode := h.executeActivation(&req)
	h.sendComplete(req.ID, exitCode)
}

// validateRequest checks that the request is valid.
func (h *ConnectionHandler) validateRequest(req *ActivateRequest) error {
	if req.ID == "" {
		return fmt.Errorf("missing request ID")
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

// executeActivation runs the activation and streams output.
func (h *ConnectionHandler) executeActivation(req *ActivateRequest) int {
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

	exitCode, err := activateStreaming(req.Type, req.Path, req.Mode, outputCallback)
	if err != nil {
		slog.Error("Activation failed", "id", req.ID, "error", err)
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
