package main

import (
	"fmt"
	"net"
	"slices"

	"golang.org/x/sys/unix"
)

// PeerCredentials holds the credentials of a Unix socket peer.
type PeerCredentials struct {
	PID uint32
	UID uint32
	GID uint32
}

// GetPeerCredentials extracts credentials from a Unix socket connection.
func GetPeerCredentials(conn net.Conn) (*PeerCredentials, error) {
	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return nil, fmt.Errorf("not a unix connection")
	}

	raw, err := unixConn.SyscallConn()
	if err != nil {
		return nil, fmt.Errorf("getting raw connection: %w", err)
	}

	var cred *unix.Ucred
	var credErr error

	err = raw.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	})
	if err != nil {
		return nil, fmt.Errorf("control: %w", err)
	}
	if credErr != nil {
		return nil, fmt.Errorf("getsockopt: %w", credErr)
	}

	return &PeerCredentials{
		PID: uint32(cred.Pid),
		UID: uint32(cred.Uid),
		GID: uint32(cred.Gid),
	}, nil
}

// IsAuthorized checks if the peer credentials are in the allowed list.
func IsAuthorized(creds *PeerCredentials, allowedUIDs, allowedGIDs []uint32) bool {
	// Root is always allowed
	if creds.UID == 0 {
		return true
	}

	return slices.Contains(allowedUIDs, creds.UID) || slices.Contains(allowedGIDs, creds.GID)
}
