package main

import (
	"fmt"

	"github.com/nshafer/phx"
	"github.com/rs/zerolog/log"
)

// type Logger interface {
// 	Print(level LoggerLevel, kind string, v ...any)
// 	Println(level LoggerLevel, kind string, v ...any)
// 	Printf(level LoggerLevel, kind string, format string, v ...any)
// }

type logger struct{}

func (l *logger) Print(level phx.LoggerLevel, kind string, v ...any) { l.Println(level, kind, v) }
func (l *logger) Println(level phx.LoggerLevel, kind string, v ...any) {
	switch level {
	case phx.LogDebug:
		log.Debug().Msg(fmt.Sprintf("%v", v))
	case phx.LogInfo:
		log.Info().Msg(fmt.Sprintf("%v", v))
	case phx.LogWarning:
		log.Warn().Msg(fmt.Sprintf("%v", v))
	case phx.LogError:
		log.Error().Msg(fmt.Sprintf("%v", v))
	}
}

func (l *logger) Printf(level phx.LoggerLevel, kind string, format string, v ...any) {
	l.Println(level, kind, fmt.Sprintf(format, v...))
}
