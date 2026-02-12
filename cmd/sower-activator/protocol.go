package main

// Request is sent by clients to request activation or reboot.
type Request struct {
	ID     string `json:"id"`               // Request correlation ID
	Type   string `json:"type"`             // "nixos", "home-manager", or "reboot"
	Path   string `json:"path,omitempty"`   // Nix store path for activation
	Mode   string `json:"mode,omitempty"`   // "switch", "boot", etc. (NixOS only)
	Reason string `json:"reason,omitempty"` // Reboot reason
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
