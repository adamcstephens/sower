package main

import (
	"fmt"
	"net/url"
	"os"
	"strings"

	"github.com/knadh/koanf/parsers/toml/v2"
	"github.com/knadh/koanf/providers/env"
	"github.com/knadh/koanf/providers/file"
	"github.com/knadh/koanf/providers/posflag"
	"github.com/knadh/koanf/v2"
	"github.com/rs/zerolog"
	flag "github.com/spf13/pflag"
)

type config struct {
	apiEndpoint     url.URL
	apiToken        string
	channelEndpoint url.URL
	stateDirectory  string
}

func initRootConfig(flags *flag.FlagSet) (*config, error) {
	var conf = koanf.Conf{}
	var kConfig = koanf.NewWithConf(conf)

	// load config files
	configFiles, _ := flags.GetStringSlice("config")
	if len(configFiles) == 0 {
		return &config{}, fmt.Errorf("No config files provided")
	}
	for _, c := range configFiles {
		if err := kConfig.Load(file.Provider(c), toml.Parser()); err != nil {
			return &config{}, fmt.Errorf("error loading config file")
		}
	}

	// load env vars
	kConfig.Load(env.Provider("SOWER_", ".", nil), nil)

	// load cli args
	if err := kConfig.Load(posflag.Provider(flags, ".", kConfig), nil); err != nil {
		return &config{}, fmt.Errorf("error parsing arguments")
	}

	zerolog.SetGlobalLevel(zerolog.InfoLevel)
	debug, err := flags.GetBool("debug")
	if err != nil {
		return &config{}, fmt.Errorf("Failed to parse debug: %v", err)
	}
	if debug {
		zerolog.SetGlobalLevel(zerolog.DebugLevel)
	}

	if kConfig.String("api-token-file") == "" {
		return &config{}, fmt.Errorf("Missing required api-token")
	}
	apiToken, err := readSecret(kConfig.String("api-token-file"))
	if err != nil {
		return &config{}, fmt.Errorf("failed to read secret, %v", err)
	}
	if envToken := kConfig.String("SOWER_API_TOKEN"); envToken != "" {
		apiToken = envToken
	}

	channelEndpoint, err := url.Parse(fmt.Sprintf("%s/client", kConfig.String("url")))
	if err != nil {
		return &config{}, fmt.Errorf("failed to parse URL, %v", err)
	}

	apiEndpoint, err := url.Parse(kConfig.String("url"))
	if err != nil {
		return &config{}, fmt.Errorf("failed to parse URL, %v", err)
	}

	stateDirectory := kConfig.String("state-directory")

	config := &config{
		apiEndpoint:     *apiEndpoint,
		apiToken:        apiToken,
		channelEndpoint: *channelEndpoint,
		stateDirectory:  stateDirectory,
	}

	return config, nil
}

func readSecret(path string) (string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}

	return strings.TrimSpace(string(content)), nil
}
