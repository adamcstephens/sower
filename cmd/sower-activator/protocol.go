package main

// ActivateRequest is sent by clients to request activation.
type ActivateRequest struct {
	ID   string `json:"id"`   // Request correlation ID
	Type string `json:"type"` // "nixos" or "home-manager"
	Path string `json:"path"` // Nix store path
	Mode string `json:"mode"` // "switch", "boot", etc. (NixOS only)
}

// ResponseType indicates the type of response message.
type ResponseType string

const (
	ResponseTypeOutput   ResponseType = "output"
	ResponseTypeError    ResponseType = "error"
	ResponseTypeComplete ResponseType = "complete"
)

// ActivateResponse is streamed back to clients during activation.
type ActivateResponse struct {
	ID       string       `json:"id"`
	Type     ResponseType `json:"type"`
	Data     string       `json:"data,omitempty"`
	ExitCode *int         `json:"exit_code,omitempty"`
}
