package main

import (
	"fmt"
	"log"
	"os"

	"github.com/knadh/koanf/parsers/toml/v2"
	"github.com/knadh/koanf/providers/file"
	"github.com/knadh/koanf/providers/posflag"
	"github.com/knadh/koanf/v2"

	flag "github.com/spf13/pflag"
)

var conf = koanf.Conf{}

var kConfig = koanf.NewWithConf(conf)

func main() {
	flags := flag.NewFlagSet("config", flag.ExitOnError)
	flags.Usage = func() {
		fmt.Println(flags.FlagUsages())
		os.Exit(0)
	}
	flags.StringSlice("config", []string{"./dev-client.toml"}, "path to one or more toml config files")
	flags.Parse(os.Args[1:])

	// load config files
	configFiles, _ := flags.GetStringSlice("config")
	for _, c := range configFiles {
		if err := kConfig.Load(file.Provider(c), toml.Parser()); err != nil {
			log.Fatalf("error loading file: %v", err)
		}
	}

	// load cli args
	if err := kConfig.Load(posflag.Provider(flags, ".", kConfig), nil); err != nil {
		log.Fatalf("error loading config: %v", err)
	}

	fmt.Println(kConfig)
}
