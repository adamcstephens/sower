package client

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/oapi-codegen/oapi-codegen/v2/pkg/securityprovider"
)

type SeedClient struct {
	hc     http.Client
	client *ClientWithResponses
}

func NewSeedClient(endpoint, token string) (*SeedClient, error) {
	if token == "" {
		return nil, fmt.Errorf("API token missing")
	}
	hc := http.Client{}

	bearerAuth, err := securityprovider.NewSecurityProviderBearerToken(token)
	if err != nil {
		return nil, fmt.Errorf("failed to load API token, %s", err)
	}

	newClient, err := NewClientWithResponses(endpoint, WithRequestEditorFn(bearerAuth.Intercept), WithHTTPClient(&hc))
	if err != nil {
		return nil, err
	}

	return &SeedClient{
		hc:     hc,
		client: newClient,
	}, nil
}

func (s *SeedClient) CreateSeed(name, seedType string) (*Seed, error) {
	if name == "" || seedType == "" {
		return nil, fmt.Errorf("seed name and type are required")
	}

	st, err := stringToSeedSeedType(seedType)
	if err != nil {
		return nil, err
	}

	resp, err := s.client.NewSeedWithResponse(context.TODO(), Seed{Name: name, SeedType: st})
	if err != nil {
		return nil, err
	}

	if resp.StatusCode() == http.StatusUnauthorized {
		return nil, fmt.Errorf("%s", *(*resp.JSON401).Error)
	}

	if resp.StatusCode() == http.StatusConflict {
		return nil, fmt.Errorf("%s", *(*resp.JSON409).Error)
	}

	if resp.StatusCode() != http.StatusCreated {
		return nil, fmt.Errorf("unknown error")
	}

	seed := resp.JSON201
	slog.Debug("Created seed", "sid", seed.Sid)

	return seed, nil
}

func (s *SeedClient) GetSeed(name, seedType string) (*Seed, error) {
	if name == "" || seedType == "" {
		return nil, fmt.Errorf("seed name and type are required")
	}

	newSeed := Seed{}

	if name == "" && seedType == "" {
		return nil, fmt.Errorf("must specify both name and type")
	}

	resp, err := s.client.ListSeedsWithResponse(context.TODO(), &ListSeedsParams{Name: &name, SeedType: &seedType})
	if err != nil {
		return nil, err
	}

	if resp.StatusCode() == http.StatusUnauthorized {
		return nil, fmt.Errorf("%s", *(*resp.JSON401).Error)
	}

	if resp.StatusCode() == http.StatusNotFound {
		return nil, fmt.Errorf("%s", *(*resp.JSON404).Error)
	}

	if resp.StatusCode() != http.StatusOK {
		return nil, fmt.Errorf("unknown error")
	}

	newSeed = (*resp.JSON200)[0]

	slog.Debug("Found seed", "name", newSeed.Name, "type", newSeed.SeedType, "sid", *newSeed.Sid)

	return &newSeed, nil
}

func (s *SeedClient) GetSeedById(id string) (*Seed, error) {
	newSeed := Seed{}

	if id == "" {
		return nil, fmt.Errorf("seed id is required")
	}

	resp, err := s.client.GetSeedWithResponse(context.TODO(), id)
	if err != nil {
		return nil, err
	}

	if resp.StatusCode() == http.StatusUnauthorized {
		return nil, fmt.Errorf("%s", *(*resp.JSON401).Error)
	}

	if resp.StatusCode() == http.StatusNotFound {
		return nil, fmt.Errorf("%s", *(*resp.JSON404).Error)
	}

	if resp.StatusCode() != http.StatusOK {
		return nil, fmt.Errorf("unknown error")
	}

	newSeed = *resp.JSON200

	slog.Debug("Found seed", "name", newSeed.Name, "type", newSeed.SeedType, "sid", *newSeed.Sid)

	return &newSeed, nil
}

func (s *SeedClient) GetSeedLatestPath(seed *Seed) (*StorePath, error) {
	resp, err := s.client.LatestStorePathBySeedWithResponse(context.TODO(), *seed.Sid)
	if err != nil {
		return nil, err
	}

	if resp.StatusCode() == http.StatusUnauthorized {
		return nil, fmt.Errorf("%s", *(*resp.JSON401).Error)
	}

	if resp.StatusCode() == http.StatusNotFound {
		return nil, fmt.Errorf("%s", *(*resp.JSON404).Error)
	}

	if resp.StatusCode() != http.StatusOK {
		return nil, fmt.Errorf("unknown error")
	}

	seedPath := resp.JSON200
	slog.Debug("Found path for seed", "path", seedPath.Path, "seed_sid", *seed.Sid)

	return seedPath, nil
}

func (s *SeedClient) SubmitSeedPath(seed *Seed, path string) (*StorePath, error) {
	resp, err := s.client.NewSeedStorePathWithResponse(context.TODO(), *seed.Sid, StorePath{Path: path})
	if err != nil {
		return nil, err
	}

	if resp.StatusCode() == http.StatusUnauthorized {
		return nil, fmt.Errorf("%s", *(*resp.JSON401).Error)
	}

	if resp.StatusCode() != http.StatusCreated {
		return nil, fmt.Errorf("unknown error")
	}

	storePath := resp.JSON201

	slog.Debug("Created path for seed", "path", storePath, "sid", seed.Sid)

	return storePath, nil
}

func stringToSeedSeedType(s string) (SeedSeedType, error) {
	switch s {
	case "home-manager":
		return HomeManager, nil
	case "nix-darwin":
		return NixDarwin, nil
	case "nixos":
		return Nixos, nil
	case "service":
		return Service, nil
	default:
		return "", fmt.Errorf("unknown seed type: %s", s)
	}
}

func (s *SeedClient) GetNixCaches() (*[]NixCache, error) {
	resp, err := s.client.ListNixCachesWithResponse(context.TODO())
	if err != nil {
		return nil, err
	}

	if resp.StatusCode() == http.StatusUnauthorized {
		return nil, fmt.Errorf("%s", *(*resp.JSON401).Error)
	}

	if resp.StatusCode() != http.StatusOK {
		return nil, fmt.Errorf("unknown error")
	}

	caches := (*resp.JSON200)

	slog.Debug("Found nix caches", "count", len(caches))

	return &caches, nil
}
