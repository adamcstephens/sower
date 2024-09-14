package seed

import (
	"fmt"
	"io"
	"os"
	"os/exec"

	"codeberg.org/adamcstephens/sower/client/client"
	"github.com/rs/zerolog/log"
)

type Seed interface {
	Activate() error
	Download() error
}

type GenericSeed struct {
	Name     string `json:"name"`
	OutPath  string `json:"out_path"`
	SeedType string `json:"seed_type"`
}

func (d *GenericSeed) Activate() error {
	log.Debug().Msgf("Activating seed %s", d.Name)
	return nil
}

func (d *GenericSeed) Download() error {
	log.Debug().Any("seed", d).Msgf("Downloading seed")

	if d.OutPath == "" {
		return fmt.Errorf("Cannot download without seed out_path")
	}

	cmd := exec.Command("nix-store", "--realize", d.OutPath)

	// Set up the pipes for stdout and stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("Error creating stdout: %v", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("Error creating stderr: %v", err)
	}

	err = cmd.Start()
	if err != nil {
		return fmt.Errorf("Error starting command: %v", err)
	}

	var ioErr error
	go func() {
		io.Copy(os.Stdout, stdout) // Redirect stdout to terminal's stdout
	}()
	go func() {
		io.Copy(os.Stderr, stderr) // Redirect stderr to terminal's stderr
	}()

	err = cmd.Wait()
	if err != nil {
		return fmt.Errorf("Failed to download seed: %v", err)
	}

	if ioErr != nil {
		return fmt.Errorf("Error copying output: %v", ioErr)
	}

	return nil
}

type NixosSeed struct {
	GenericSeed
}

func (d *NixosSeed) Activate() error {
	log.Debug().Msg("Nixos is a different activation")
	return nil
}

func NewSeed(seed *client.Seed, storePath *client.StorePath) Seed {
	newSeed := &GenericSeed{
		Name:     seed.Name,
		OutPath:  storePath.Path,
		SeedType: seed.SeedType,
	}

	switch newSeed.SeedType {
	case "nixos":
		return &NixosSeed{
			GenericSeed: *newSeed,
		}
	}

	return newSeed
}

func DefaultName() string {
	name := "blank"

	// SeedType::Nixos | SeedType::NixDarwin => nix::unistd::gethostname()
	//     .expect("Failed getting hostname")
	//     .into_string()
	//     .unwrap(),
	// SeedType::HomeManager => env::var("USER").expect("can not detect username"),

	return name
}

func DefaultType() string {
	name := "nixos"

	// SeedType::Nixos | SeedType::NixDarwin => nix::unistd::gethostname()
	//     .expect("Failed getting hostname")
	//     .into_string()
	//     .unwrap(),
	// SeedType::HomeManager => env::var("USER").expect("can not detect username"),

	return name
}
