package main

import (
	"fmt"
	"log/slog"

	"github.com/nshafer/phx"
)

type logger struct{}

func (l *logger) Print(level phx.LoggerLevel, kind string, v ...any) { l.Println(level, kind, v) }
func (l *logger) Println(level phx.LoggerLevel, kind string, v ...any) {
	switch level {
	case phx.LogDebug:
		slog.Debug(fmt.Sprintf("%v", v))
	case phx.LogInfo:
		slog.Info(fmt.Sprintf("%v", v))
	case phx.LogWarning:
		slog.Warn(fmt.Sprintf("%v", v))
	case phx.LogError:
		slog.Error(fmt.Sprintf("%v", v))
	}
}

func (l *logger) Printf(level phx.LoggerLevel, kind string, format string, v ...any) {
	l.Println(level, kind, fmt.Sprintf(format, v...))
}
