package server

// Package server owns the lifecycle of the gRPC listener and the sidecar HTTP
// server that exposes Prometheus metrics. Main wires protobuf implementations
// onto the gRPC server returned by GRPC() before calling Serve.

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	"google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"

	"github.com/parallelbots/trading-gateway/internal/config"
	"github.com/parallelbots/trading-gateway/internal/interceptors"
	"github.com/parallelbots/trading-gateway/internal/logging"
	"github.com/parallelbots/trading-gateway/internal/ratelimit"
)

// GatewayServer bundles the gRPC and metrics servers.
type GatewayServer struct {
	cfg           config.Config
	logger        *slog.Logger
	grpcServer    *grpc.Server
	healthServer  *health.Server
	metricsServer *http.Server
	services      []string
}

// New creates a configured GatewayServer with health + reflection enabled.
// It wires the unary interceptor chain (request ID, recovery, rate limiting,
// logging) and prepares the Prometheus HTTP handler.
func New(cfg config.Config, logger *slog.Logger) *GatewayServer {
	var limiter *ratelimit.Limiter
	if cfg.RateLimitEnabled {
		limiter = ratelimit.New(cfg.RateLimitRPS, cfg.RateLimitBurst)
	}

	serverOpts := []grpc.ServerOption{
		interceptors.UnaryChain(logger, limiter),
	}

	grpcServer := grpc.NewServer(serverOpts...)

	healthServer := health.NewServer()
	healthServer.SetServingStatus("", grpc_health_v1.HealthCheckResponse_NOT_SERVING)

	grpc_health_v1.RegisterHealthServer(grpcServer, healthServer)
	reflection.Register(grpcServer)

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	metricsServer := &http.Server{
		Addr:              cfg.MetricsListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	return &GatewayServer{
		cfg:           cfg,
		logger:        logger,
		grpcServer:    grpcServer,
		healthServer:  healthServer,
		metricsServer: metricsServer,
		services:      make([]string, 0, 4),
	}
}

// Serve starts the gRPC and metrics servers and blocks until context
// cancellation. Shutdown is graceful: ongoing RPCs are drained and the metrics
// listener is given 15 seconds to finish in-flight scrapes.
func (g *GatewayServer) Serve(ctx context.Context) error {
	lis, err := net.Listen("tcp", g.cfg.GRPCListenAddr)
	if err != nil {
		return fmt.Errorf("listen gRPC: %w", err)
	}

	errCh := make(chan error, 2)

	go func() {
		g.logger.Info("metrics server starting", "addr", g.cfg.MetricsListenAddr)
		if err := g.metricsServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			errCh <- fmt.Errorf("metrics server: %w", err)
		}
	}()

	go func() {
		g.logger.Info("gRPC server starting", "addr", g.cfg.GRPCListenAddr)
		g.healthServer.SetServingStatus("", grpc_health_v1.HealthCheckResponse_SERVING)
		for _, svc := range g.services {
			g.healthServer.SetServingStatus(svc, grpc_health_v1.HealthCheckResponse_SERVING)
		}
		if err := g.grpcServer.Serve(lis); err != nil {
			errCh <- fmt.Errorf("grpc serve: %w", err)
		}
	}()

	select {
	case <-ctx.Done():
		g.logger.Info("shutdown requested")
	case err := <-errCh:
		if err != nil {
			return err
		}
	}
	g.healthServer.SetServingStatus("", grpc_health_v1.HealthCheckResponse_NOT_SERVING)
	for _, svc := range g.services {
		g.healthServer.SetServingStatus(svc, grpc_health_v1.HealthCheckResponse_NOT_SERVING)
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	g.grpcServer.GracefulStop()
	if err := g.metricsServer.Shutdown(shutdownCtx); err != nil {
		g.logger.Warn("metrics shutdown error", "error", err)
	}
	return nil
}

// RegisterTradingGateway should be called by main after generating protobuf stubs.
// Example:
//
//	var impl tradinggatewayv1.TradingGatewayServer = api.New(orderFacade)
//	tradinggatewayv1.RegisterTradingGatewayServer(server.GRPC(), impl)
//
// Keeping this helper clarifies the intended extension point.
func (g *GatewayServer) GRPC() *grpc.Server {
	return g.grpcServer
}

// Health returns the underlying gRPC health server for service-level updates.
func (g *GatewayServer) Health() *health.Server {
	return g.healthServer
}

// Logger exposes the configured slog logger (useful for dependent components).
func (g *GatewayServer) Logger() *slog.Logger {
	return g.logger
}

// TrackService registers a service name with the health server so its status
// is updated alongside the global one.
func (g *GatewayServer) TrackService(name string) {
	if name == "" {
		return
	}
	g.services = append(g.services, name)
	g.healthServer.SetServingStatus(name, grpc_health_v1.HealthCheckResponse_NOT_SERVING)
}

// NewDefault constructs a server with config/logging defaults for quick tests.
func NewDefault() *GatewayServer {
	cfg := config.Load()
	logger := logging.Setup()
	return New(cfg, logger)
}
