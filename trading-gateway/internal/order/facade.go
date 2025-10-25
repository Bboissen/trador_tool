package order

import (
	"context"
	"errors"
	"time"
)

// Normalized order model shared across adapters.
type Order struct {
	ClientOrderID  string
	Venue          string
	Symbol         string
	Side           string
	Quantity       float64
	Price          float64
	TimeInForce    string
	IdempotencyKey string
	Attributes     map[string]string
	ReceivedAt     time.Time
}

// Result represents the gateway's view of an acknowledged order.
type Result struct {
	VenueOrderID   string
	Status         string
	AcceptedAt     time.Time
	ClientOrderID  string
	FilledQuantity float64
	AveragePrice   float64
	LastUpdate     time.Time
}

// Facade drives validation, idempotency checks, routing, and persistence.
type Facade interface {
	Place(context.Context, Order) (Result, error)
	Cancel(context.Context, CancelCommand) (Result, error)
	Status(context.Context, StatusQuery) (Result, error)
}

// CancelCommand describes a cancellation request.
type CancelCommand struct {
	Venue          string
	VenueOrderID   string
	ClientOrderID  string
	IdempotencyKey string
}

// StatusQuery fetches the latest status for an order.
type StatusQuery struct {
	Venue         string
	ClientOrderID string
	VenueOrderID  string
}

var (
	// ErrDuplicate indicates the order was previously accepted.
	ErrDuplicate = errors.New("duplicate order")
	// ErrInvalid signals validation failure.
	ErrInvalid = errors.New("invalid order")
)
