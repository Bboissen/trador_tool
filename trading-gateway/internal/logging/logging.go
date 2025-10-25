package logging

import (
	"log/slog"
	"os"
	"strings"
)

// Setup configures the global structured logger with environment-aware defaults.
func Setup() *slog.Logger {
	logger := slog.New(determineHandler())
	slog.SetDefault(logger)
	return logger
}

func determineHandler() slog.Handler {
	level := getLogLevel()
	format := getLogFormat()
	opts := &slog.HandlerOptions{
		Level:     level,
		AddSource: os.Getenv("LOG_SOURCE") == "true",
	}

	switch format {
	case "json":
		return slog.NewJSONHandler(os.Stdout, opts)
	case "text":
		return slog.NewTextHandler(os.Stdout, opts)
	case "pretty":
		opts.ReplaceAttr = func(_ []string, a slog.Attr) slog.Attr {
			if a.Key == slog.TimeKey {
				return slog.String("time", a.Value.Time().Format("15:04:05.000"))
			}
			return a
		}
		return slog.NewTextHandler(os.Stdout, opts)
	default:
		if isProduction() {
			return slog.NewJSONHandler(os.Stdout, opts)
		}
		return slog.NewTextHandler(os.Stdout, opts)
	}
}

func getLogLevel() slog.Level {
	level := os.Getenv("LOG_LEVEL")
	if level == "" {
		if isProduction() {
			level = "INFO"
		} else {
			level = "DEBUG"
		}
	}

	switch strings.ToUpper(level) {
	case "DEBUG":
		return slog.LevelDebug
	case "INFO":
		return slog.LevelInfo
	case "WARN", "WARNING":
		return slog.LevelWarn
	case "ERROR":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

func getLogFormat() string {
	if format := os.Getenv("LOG_FORMAT"); format != "" {
		return strings.ToLower(format)
	}
	if isProduction() {
		return "json"
	}
	return "pretty"
}

// EnvironmentName returns the detected runtime environment (dev/prod/etc).
func EnvironmentName() string {
	for _, key := range []string{"ENV", "GO_ENV", "ENVIRONMENT", "APP_ENV"} {
		if v := os.Getenv(key); v != "" {
			return v
		}
	}
	if os.Getenv("KUBERNETES_SERVICE_HOST") != "" {
		return "kubernetes"
	}
	return "development"
}

func isProduction() bool {
	env := strings.ToLower(EnvironmentName())
	return strings.HasPrefix(env, "prod") || env == "production" || os.Getenv("KUBERNETES_SERVICE_HOST") != ""
}
