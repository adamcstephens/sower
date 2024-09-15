package client

import (
	"context"
	"fmt"
	"net/http"

	"github.com/google/uuid"

	"github.com/rs/zerolog/log"
)

type SeedClient struct {
	hc     http.Client
	client *ClientWithResponses
}

func NewSeedClient(endpoint string) (*SeedClient, error) {
	hc := http.Client{}

	newClient, err := NewClientWithResponses(endpoint, WithHTTPClient(&hc))
	if err != nil {
		return nil, err
	}

	return &SeedClient{
		hc:     hc,
		client: newClient,
	}, nil
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

		if resp.StatusCode() != http.StatusOK {
			return nil, err
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

		if resp.StatusCode() != http.StatusOK {
			log.Error().Msg("Failed finding seed")
			return nil, err
		}
		newSeed = *resp.JSON200
	}

	return &newSeed, nil
}

func (s *SeedClient) GetSeedLatestPath(seed *Seed) (*StorePath, error) {
	pathResp, err := s.client.LatestStorePathBySeedWithResponse(context.TODO(), seed.Id.String())
	if err != nil {
		return nil, err
	}
	if pathResp.StatusCode() != http.StatusOK {
		log.Error().Msg("Failed finding seed")
		return nil, err
	}
	path := pathResp.JSON200
	log.Debug().Any("path", path).Any("seed", seed).Msg("Found path for seed")

	return path, nil
}
