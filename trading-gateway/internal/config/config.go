package config

import (
	"os"
	"strconv"
	"strings"
	"time"
)

// Config holds runtime configuration.
type Config struct {
	GRPCListenAddr    string
	MetricsListenAddr string

	// TLS
	TLSCertPath string
	TLSKeyPath  string

	// Routing
	DefaultVenue string

	// Idempotency cache
	IdempotencyTTL time.Duration

	// Rate limiting
	RateLimitEnabled bool
	RateLimitRPS     float64
	RateLimitBurst   int

	// Persistence
	EventStoreDSN string
}

// Load populates Config using environment variables.
func Load() Config {
	cfg := Config{
		GRPCListenAddr:    getenv("GRPC_LISTEN_ADDR", "0.0.0.0:50051"),
		MetricsListenAddr: getenv("METRICS_LISTEN_ADDR", "0.0.0.0:9100"),
		TLSCertPath:       os.Getenv("TLS_CERT_PATH"),
		TLSKeyPath:        os.Getenv("TLS_KEY_PATH"),
		DefaultVenue:      getenv("DEFAULT_VENUE", "demo"),
		IdempotencyTTL:    parseDurationEnv("IDEMPOTENCY_TTL", 10*time.Minute),
		RateLimitEnabled:  strings.EqualFold(os.Getenv("RATE_LIMIT_ENABLED"), "true"),
		RateLimitRPS:      parseFloatEnv("RATE_LIMIT_RPS", 50),
		RateLimitBurst:    parseIntEnv("RATE_LIMIT_BURST", 100),
		EventStoreDSN:     os.Getenv("EVENT_STORE_DSN"),
	}
	return cfg
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func parseFloatEnv(key string, def float64) float64 {
	if v := os.Getenv(key); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return def
}

func parseIntEnv(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}
	return def
}

func parseDurationEnv(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
		if i, err := strconv.Atoi(v); err == nil {
			return time.Duration(i) * time.Second
		}
	}
	return def
}
