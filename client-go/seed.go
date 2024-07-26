package main

import "github.com/rs/zerolog/log"

type Seed interface {
	Activate() error
	Download() error
}

type GenericSeed struct {
	Name     string `json:"name"`
	OutPath  string `json:"out_path"`
	SeedType string `json:"seed_type"`
}

func NewSeed(name, seed_type, out_path string) Seed {
	switch seed_type {
	case "nixos":
		return &NixosSeed{
			GenericSeed: GenericSeed{Name: name,
				OutPath:  out_path,
				SeedType: seed_type,
			},
		}
	}

	return &GenericSeed{
		Name:     name,
		OutPath:  out_path,
		SeedType: seed_type,
	}
}

func (d *GenericSeed) Activate() error {
	log.Debug().Msgf("Activating seed %s", d.Name)
	return nil
}

func (d *GenericSeed) Download() error {
	log.Debug().Msgf("Downloading seed %s", d.Name)
	return nil
}

type NixosSeed struct {
	GenericSeed
}

func (d *NixosSeed) Activate() error {
	log.Debug().Msg("Nixos is a different activation")
	return nil
}
