package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"

	orderpb "order-gateway/pkg/pb/trading/order/v1"
	"order-gateway/server"

	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"
)

type Config struct {
	DBURL    string
	Host     string
	Port     int
	GRPCPort int
}

func loadConfig() Config {
	// Prefer DATABASE_URL when provided, otherwise compose from parts
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		host := getenv("DB_HOST", "localhost")
		port := getenv("DB_PORT", "5432")
		user := getenv("DB_USER", "postgres")
		pass := getenv("DB_PASSWORD", "postgres")
		name := getenv("DB_NAME", "orders")
		dbURL = fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=disable", user, pass, host, port, name)
	}
	h := getenv("HOST", "0.0.0.0")
	pStr := getenv("PORT", "8080")
	p, _ := strconv.Atoi(pStr)
	gpStr := getenv("GRPC_PORT", "9090")
	gp, _ := strconv.Atoi(gpStr)
	return Config{DBURL: dbURL, Host: h, Port: p, GRPCPort: gp}
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	cfg := loadConfig()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	pool, err := pgxpool.New(ctx, cfg.DBURL)
	if err != nil {
		log.Fatalf("failed to create pgx pool: %v", err)
	}
	defer pool.Close()

	if err := pool.Ping(ctx); err != nil {
		log.Printf("warning: initial DB ping failed: %v", err)
	} else {
		log.Printf("connected to database")
	}

	// Start gRPC server (OrderService)
	grpcAddr := fmt.Sprintf("%s:%d", cfg.Host, cfg.GRPCPort)
	lis, err := net.Listen("tcp", grpcAddr)
	if err != nil {
		log.Fatalf("failed to listen on %s: %v", grpcAddr, err)
	}
	grpcServer := grpc.NewServer()
	orderpb.RegisterOrderServiceServer(grpcServer, server.NewOrderService(pool))
	reflection.Register(grpcServer)
	go func() {
		log.Printf("gRPC OrderService listening on %s", grpcAddr)
		if err := grpcServer.Serve(lis); err != nil {
			log.Fatalf("grpc server error: %v", err)
		}
	}()

	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"healthy"}`))
	})

	mux.HandleFunc("/ready", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := pool.Ping(ctx); err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(fmt.Sprintf(`{"status":"not_ready","error":%q}`, err.Error())))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ready"}`))
	})

	// Simple check endpoint: counts rows in trading.orders if available
	mux.HandleFunc("/orders/count", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		var count int64
		// Use a safe query; table may not exist if init hasn’t run
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM trading.orders`).Scan(&count); err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(fmt.Sprintf(`{"ok":true,"orders_table":"unavailable","error":%q}`, err.Error())))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(fmt.Sprintf(`{"ok":true,"orders":%d}`, count)))
	})

	addr := fmt.Sprintf("%s:%d", cfg.Host, cfg.Port)
	log.Printf("order-service HTTP listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("http server error: %v", err)
	}
}
