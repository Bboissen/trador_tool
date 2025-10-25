package order

// Package order contains the domain model plus the facade that validates,
// deduplicates, and routes orders to venue adapters.

import (
	"context"
	"fmt"
	"time"

	"github.com/parallelbots/trading-gateway/pkg/idempotency"
)

// Adapter defines the venue-specific implementation contract.
type Adapter interface {
	Place(context.Context, Order) (Result, error)
	Cancel(context.Context, CancelCommand) (Result, error)
	Status(context.Context, StatusQuery) (Result, error)
}

// Registry holds adapters keyed by venue identifier.
type Registry struct {
	adapters map[string]Adapter
}

// NewRegistry returns an empty adapter registry.
func NewRegistry() *Registry {
	return &Registry{adapters: make(map[string]Adapter)}
}

// Register stores an adapter implementation for a venue.
func (r *Registry) Register(venue string, adapter Adapter) {
	r.adapters[venue] = adapter
}

// Adapter resolves the adapter for the venue.
func (r *Registry) Adapter(venue string) (Adapter, error) {
	if adapter, ok := r.adapters[venue]; ok {
		return adapter, nil
	}
	return nil, fmt.Errorf("no adapter registered for venue %q", venue)
}

// Gateway implements Facade using a registry + idempotency cache.
type Gateway struct {
	registry    *Registry
	idempotency *idempotency.Cache
}

// NewGateway constructs an order gateway.
func NewGateway(reg *Registry, cache *idempotency.Cache) *Gateway {
	return &Gateway{
		registry:    reg,
		idempotency: cache,
	}
}

// Place validates and routes the order to the appropriate adapter.
func (g *Gateway) Place(ctx context.Context, ord Order) (Result, error) {
	if err := g.validate(ord); err != nil {
		return Result{}, err
	}
	if ord.IdempotencyKey != "" {
		if cached, ok := g.idempotency.Get(ord.IdempotencyKey); ok {
			if res, ok := cached.(Result); ok {
				return res, nil
			}
		}
	}
	adapter, err := g.registry.Adapter(ord.Venue)
	if err != nil {
		return Result{}, err
	}
	ord.ReceivedAt = time.Now().UTC()
	res, err := adapter.Place(ctx, ord)
	if err != nil {
		return Result{}, err
	}
	if res.ClientOrderID == "" {
		res.ClientOrderID = ord.ClientOrderID
	}
	if res.AcceptedAt.IsZero() {
		res.AcceptedAt = time.Now().UTC()
	}
	if res.LastUpdate.IsZero() {
		res.LastUpdate = res.AcceptedAt
	}
	if ord.IdempotencyKey != "" {
		g.idempotency.Set(ord.IdempotencyKey, res)
	}
	return res, nil
}

// Cancel routes a cancel request to the adapter.
func (g *Gateway) Cancel(ctx context.Context, cmd CancelCommand) (Result, error) {
	adapter, err := g.registry.Adapter(cmd.Venue)
	if err != nil {
		return Result{}, err
	}
	res, err := adapter.Cancel(ctx, cmd)
	if err != nil {
		return Result{}, err
	}
	if res.ClientOrderID == "" {
		res.ClientOrderID = cmd.ClientOrderID
	}
	if res.LastUpdate.IsZero() {
		res.LastUpdate = time.Now().UTC()
	}
	return res, nil
}

// Status queries the adapter for latest state.
func (g *Gateway) Status(ctx context.Context, query StatusQuery) (Result, error) {
	adapter, err := g.registry.Adapter(query.Venue)
	if err != nil {
		return Result{}, err
	}
	res, err := adapter.Status(ctx, query)
	if err != nil {
		return Result{}, err
	}
	if res.ClientOrderID == "" {
		res.ClientOrderID = query.ClientOrderID
	}
	if res.LastUpdate.IsZero() {
		res.LastUpdate = time.Now().UTC()
	}
	return res, nil
}

func (g *Gateway) validate(ord Order) error {
	switch {
	case ord.ClientOrderID == "":
		return fmt.Errorf("%w: client_order_id required", ErrInvalid)
	case ord.Venue == "":
		return fmt.Errorf("%w: venue required", ErrInvalid)
	case ord.Symbol == "":
		return fmt.Errorf("%w: symbol required", ErrInvalid)
	case ord.Quantity <= 0:
		return fmt.Errorf("%w: quantity must be positive", ErrInvalid)
	}
	return nil
}

var _ Facade = (*Gateway)(nil)
