package mock

import (
	"context"
	"time"

	"github.com/parallelbots/trading-gateway/internal/order"
)

// Adapter is a placeholder venue implementation that echos requests.
type Adapter struct{}

// New returns a mock adapter.
func New() *Adapter { return &Adapter{} }

func (a *Adapter) Place(_ context.Context, ord order.Order) (order.Result, error) {
	now := time.Now().UTC()
	return order.Result{
		VenueOrderID:  "mock-" + ord.ClientOrderID,
		ClientOrderID: ord.ClientOrderID,
		Status:        "ACCEPTED",
		AcceptedAt:    now,
		LastUpdate:    now,
	}, nil
}

func (a *Adapter) Cancel(_ context.Context, cmd order.CancelCommand) (order.Result, error) {
	now := time.Now().UTC()
	return order.Result{
		VenueOrderID:  cmd.VenueOrderID,
		ClientOrderID: cmd.ClientOrderID,
		Status:        "CANCELLED",
		AcceptedAt:    now,
		LastUpdate:    now,
	}, nil
}

func (a *Adapter) Status(_ context.Context, query order.StatusQuery) (order.Result, error) {
	now := time.Now().UTC()
	return order.Result{
		VenueOrderID:   fallback(query.VenueOrderID, "mock-"+query.ClientOrderID),
		ClientOrderID:  query.ClientOrderID,
		Status:         "FILLED",
		FilledQuantity: 1.0,
		AveragePrice:   1.0,
		AcceptedAt:     now,
		LastUpdate:     now,
	}, nil
}

func fallback(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}
