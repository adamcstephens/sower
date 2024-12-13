package client

import (
	"context"
	"fmt"
	"net/http"

	"github.com/google/uuid"
	"github.com/oapi-codegen/oapi-codegen/v2/pkg/securityprovider"

	"github.com/rs/zerolog/log"
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
		return nil, fmt.Errorf("Failed to load API token, %s", err)
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
	st, err := stringToSeedSeedType(seedType)
	if err != nil {
		return nil, err
	}

	resp, err := s.client.NewSeedWithResponse(context.TODO(), Seed{Name: name, SeedType: st})
	if err != nil {
		return nil, err
	}

	if resp.StatusCode() == http.StatusUnauthorized {
		return nil, fmt.Errorf(*(*resp.JSON401).Error)
	}

	if resp.StatusCode() != http.StatusCreated {
		return nil, fmt.Errorf("unknown error")
	}

	seed := resp.JSON201
	log.Debug().Any("seed_id", seed.Id).Msg("Created seed")

	return seed, nil
}

func (s *SeedClient) GetSeed(id, name, seedType string) (*Seed, error) {
	newSeed := Seed{}

	if id == "" {
		if name == "" && seedType == "" {
			return nil, fmt.Errorf("Must specify both name and type if not querying by id")
		}

		resp, err := s.client.ListSeedsWithResponse(context.TODO(), &ListSeedsParams{Name: &name, SeedType: &seedType})
		if err != nil {
			return nil, err
		}

		if resp.StatusCode() == http.StatusUnauthorized {
			return nil, fmt.Errorf(*(*resp.JSON401).Error)
		}

		if resp.StatusCode() == http.StatusNotFound {
			return nil, fmt.Errorf(*(*resp.JSON404).Error)
		}

		if resp.StatusCode() != http.StatusOK {
			return nil, fmt.Errorf("unknown error")
		}

		newSeed = (*resp.JSON200)[0]

	} else {
		id, err := uuid.Parse(id)
		if err != nil {
			return nil, err
		}

		resp, err := s.client.GetSeedWithResponse(context.TODO(), id.String())
		if err != nil {
			return nil, err
		}

		if resp.StatusCode() == http.StatusUnauthorized {
			return nil, fmt.Errorf(*(*resp.JSON401).Error)
		}

		if resp.StatusCode() != http.StatusOK {
			return nil, fmt.Errorf("unknown error")
		}

		newSeed = *resp.JSON200
	}

	log.Debug().Any("seed", newSeed).Msg("Found seed")

	return &newSeed, nil
}

func (s *SeedClient) GetSeedLatestPath(seed *Seed) (*StorePath, error) {
	resp, err := s.client.LatestStorePathBySeedWithResponse(context.TODO(), seed.Id.String())
	if err != nil {
		return nil, err
	}

	if resp.StatusCode() == http.StatusUnauthorized {
		return nil, fmt.Errorf(*(*resp.JSON401).Error)
	}

	if resp.StatusCode() != http.StatusOK {
		return nil, fmt.Errorf("unknown error")
	}

	path := resp.JSON200
	log.Debug().Any("path", path).Any("seed", seed).Msg("Found path for seed")

	return path, nil
}

func (s *SeedClient) SubmitSeedPath(seed *Seed, path string) (*StorePath, error) {
	resp, err := s.client.NewSeedStorePathWithResponse(context.TODO(), seed.Id.String(), StorePath{Path: path})
	if err != nil {
		return nil, err
	}

	if resp.StatusCode() == http.StatusUnauthorized {
		return nil, fmt.Errorf(*(*resp.JSON401).Error)
	}

	if resp.StatusCode() != http.StatusCreated {
		return nil, fmt.Errorf("unknown error")
	}

	storePath := resp.JSON201
	log.Debug().Any("seed_id", seed.Id).Any("path", storePath).Msg("Created path for seed")

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
	default:
		return "", fmt.Errorf("unknown seed type: %s", s)
	}
}
