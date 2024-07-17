package main

import (
	"fmt"
	"net/url"
	"os"

	"github.com/knadh/koanf/parsers/toml/v2"
	"github.com/knadh/koanf/providers/file"
	"github.com/knadh/koanf/providers/posflag"
	"github.com/knadh/koanf/v2"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"

	flag "github.com/spf13/pflag"
)

var conf = koanf.Conf{}

var kConfig = koanf.NewWithConf(conf)

func main() {
	log.Logger = log.Output(zerolog.ConsoleWriter{Out: os.Stderr})

	flags := flag.NewFlagSet("config", flag.ExitOnError)
	flags.Usage = func() {
		fmt.Println(flags.FlagUsages())
		os.Exit(0)
	}
	flags.StringSlice("config", []string{"./dev-client.toml"}, "path to one or more toml config files")
	flags.Bool("debug", false, "enable debug logging")
	flags.Parse(os.Args[1:])

	// load config files
	configFiles, _ := flags.GetStringSlice("config")
	for _, c := range configFiles {
		if err := kConfig.Load(file.Provider(c), toml.Parser()); err != nil {
			log.Error().Err(err).Msg("error loading config file")
			os.Exit(1)
		}
	}

	// load cli args
	if err := kConfig.Load(posflag.Provider(flags, ".", kConfig), nil); err != nil {
		log.Error().Err(err).Msg("error parsing arguments")
		os.Exit(1)
	}

	zerolog.SetGlobalLevel(zerolog.InfoLevel)
	if kConfig.Bool("debug") {
		zerolog.SetGlobalLevel(zerolog.DebugLevel)
	}
	run(kConfig)
}

func run(kConfig *koanf.Koanf) {
	log.Info().Msg("Starting")
	log.Debug().Any("config", kConfig).Msg("")

	endPoint, _ := url.Parse(fmt.Sprintf("%s/client/websocket", kConfig.String("url")))
	log.Debug().Any("endpoint", endPoint).Msg("")
}
