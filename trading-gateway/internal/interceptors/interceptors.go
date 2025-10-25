package interceptors

// Package interceptors defines the unary interceptor chain applied to every
// gRPC call (request ID propagation, panic recovery, rate limiting, logging).

import (
	"context"
	"log/slog"
	"time"

	"github.com/google/uuid"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	"github.com/parallelbots/trading-gateway/internal/ratelimit"
)

const requestIDHeader = "x-request-id"

// UnaryChain builds a grpc.ChainUnaryInterceptor with the provided components.
func UnaryChain(logger *slog.Logger, limiter *ratelimit.Limiter) grpc.ServerOption {
	return grpc.ChainUnaryInterceptor(
		requestIDInterceptor(),
		recoveryInterceptor(logger),
		rateLimitInterceptor(limiter),
		loggingInterceptor(logger),
	)
}

func requestIDInterceptor() grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		md, ok := metadata.FromIncomingContext(ctx)
		if !ok {
			md = metadata.MD{}
		}

		var requestID string
		if ids := md.Get(requestIDHeader); len(ids) > 0 && ids[0] != "" {
			requestID = ids[0]
		} else {
			requestID = uuid.NewString()
			md.Set(requestIDHeader, requestID)
			ctx = metadata.NewIncomingContext(ctx, md)
		}

		ctx = context.WithValue(ctx, requestIDKey{}, requestID)
		return handler(ctx, req)
	}
}

func rateLimitInterceptor(limiter *ratelimit.Limiter) grpc.UnaryServerInterceptor {
	if limiter == nil {
		return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
			return handler(ctx, req)
		}
	}
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		md, _ := metadata.FromIncomingContext(ctx)
		key := "anonymous"
		if md != nil {
			if ids := md.Get("x-forwarded-for"); len(ids) > 0 {
				key = ids[0]
			} else if ids := md.Get(requestIDHeader); len(ids) > 0 {
				key = ids[0]
			}
		}
		if !limiter.Allow(key) {
			return nil, status.Errorf( /* codes.ResourceExhausted */ 8, "rate limit exceeded")
		}
		return handler(ctx, req)
	}
}

func loggingInterceptor(logger *slog.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		start := time.Now()
		resp, err := handler(ctx, req)
		elapsed := time.Since(start)
		fields := []any{
			"method", info.FullMethod,
			"duration", elapsed,
		}
		if rid := RequestIDFromContext(ctx); rid != "" {
			fields = append(fields, "request_id", rid)
		}
		if err != nil {
			fields = append(fields, "error", err.Error())
			logger.Error("grpc request failed", fields...)
		} else {
			logger.Info("grpc request completed", fields...)
		}
		return resp, err
	}
}

func recoveryInterceptor(logger *slog.Logger) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (resp any, err error) {
		defer func() {
			if r := recover(); r != nil {
				logger.Error("panic recovered", "method", info.FullMethod, "panic", r)
				err = status.Errorf(13, "internal server error") // codes.Internal
			}
		}()
		return handler(ctx, req)
	}
}

type requestIDKey struct{}

// RequestIDFromContext extracts the request ID set by the interceptor.
func RequestIDFromContext(ctx context.Context) string {
	if v, ok := ctx.Value(requestIDKey{}).(string); ok {
		return v
	}
	return ""
}
