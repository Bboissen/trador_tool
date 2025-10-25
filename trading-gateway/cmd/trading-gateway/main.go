package main

// cmd/trading-gateway is the process entrypoint. It wires config, logging,
// constructs the shared GatewayServer, and blocks until shutdown signals.

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/parallelbots/trading-gateway/internal/api"
	"github.com/parallelbots/trading-gateway/internal/config"
	"github.com/parallelbots/trading-gateway/internal/logging"
	"github.com/parallelbots/trading-gateway/internal/order"
	"github.com/parallelbots/trading-gateway/internal/server"
	"github.com/parallelbots/trading-gateway/internal/venue/mock"
	tradinggatewayv1 "github.com/parallelbots/trading-gateway/pkg/gen/proto"
	"github.com/parallelbots/trading-gateway/pkg/idempotency"
)

var (
	version   = "dev"
	buildTime = "unknown"
	gitCommit = "unknown"
)

func main() {
	var (
		printVersion bool
	)
	flag.BoolVar(&printVersion, "version", false, "print version information and exit")
	// TODO: add --config flag when we support file-based configuration.
	flag.Parse()

	if printVersion {
		fmt.Printf("trading-gateway version %s\n", version)
		fmt.Printf("build time: %s\n", buildTime)
		fmt.Printf("git commit: %s\n", gitCommit)
		return
	}

	cfg := config.Load()
	logger := logging.Setup()

	logger.Info("starting trading-gateway",
		"grpc_addr", cfg.GRPCListenAddr,
		"metrics_addr", cfg.MetricsListenAddr,
		"default_venue", cfg.DefaultVenue,
		"environment", logging.EnvironmentName(),
	)

	// Wire domain components (adapter registry, facade, service implementation).
	registry := order.NewRegistry()
	registry.Register(cfg.DefaultVenue, mock.New())

	cache := idempotency.New(cfg.IdempotencyTTL)
	facade := order.NewGateway(registry, cache)
	service := api.NewTradingService(facade)

	gw := server.New(cfg, logger)
	tradinggatewayv1.RegisterTradingGatewayServer(gw.GRPC(), service)
	gw.TrackService(tradinggatewayv1.TradingGateway_ServiceDesc.ServiceName)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// Block until either a signal arrives or one of the servers returns an error.
	if err := gw.Serve(ctx); err != nil {
		logger.Error("server stopped with error", "error", err)
		os.Exit(1)
	}

	logger.Info("shutdown complete", "uptime", time.Since(startTime))
}

var startTime = time.Now()
