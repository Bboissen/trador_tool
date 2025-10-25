package api

import (
	"context"
	"errors"
	"fmt"

	"github.com/parallelbots/trading-gateway/internal/order"
	tradinggatewayv1 "github.com/parallelbots/trading-gateway/pkg/gen/proto"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// TradingService bridges the protobuf contract and the domain order facade.
type TradingService struct {
	tradinggatewayv1.UnimplementedTradingGatewayServer
	facade order.Facade
}

// NewTradingService wraps the provided facade.
func NewTradingService(facade order.Facade) *TradingService {
	return &TradingService{facade: facade}
}

// PlaceOrder validates + routes the order via the facade.
func (s *TradingService) PlaceOrder(ctx context.Context, req *tradinggatewayv1.OrderRequest) (*tradinggatewayv1.OrderResponse, error) {
	payload, err := toDomainOrder(req)
	if err != nil {
		return nil, status.Errorf(codes.InvalidArgument, "invalid order: %v", err)
	}

	res, err := s.facade.Place(ctx, payload)
	if err != nil {
		if errors.Is(err, order.ErrInvalid) {
			return nil, status.Errorf(codes.InvalidArgument, err.Error())
		}
		if errors.Is(err, order.ErrDuplicate) {
			return nil, status.Error(codes.AlreadyExists, err.Error())
		}
		return nil, status.Errorf(codes.Internal, "order placement failed: %v", err)
	}

	return &tradinggatewayv1.OrderResponse{
		ClientOrderId: req.GetClientOrderId(),
		VenueOrderId:  res.VenueOrderID,
		Status:        res.Status,
		AcceptedAt:    timestamppb.New(res.AcceptedAt),
	}, nil
}

// CancelOrder forwards cancellation to the facade.
func (s *TradingService) CancelOrder(ctx context.Context, req *tradinggatewayv1.CancelRequest) (*tradinggatewayv1.CancelResponse, error) {
	cmd := order.CancelCommand{
		Venue:          req.GetVenue(),
		VenueOrderID:   req.GetVenueOrderId(),
		ClientOrderID:  req.GetClientOrderId(),
		IdempotencyKey: req.GetIdempotencyKey(),
	}

	res, err := s.facade.Cancel(ctx, cmd)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "cancel failed: %v", err)
	}

	return &tradinggatewayv1.CancelResponse{
		VenueOrderId: res.VenueOrderID,
		Status:       res.Status,
	}, nil
}

// GetOrderStatus queries the facade for latest status.
func (s *TradingService) GetOrderStatus(ctx context.Context, req *tradinggatewayv1.OrderStatusRequest) (*tradinggatewayv1.OrderStatus, error) {
	query := order.StatusQuery{
		Venue:         req.GetVenue(),
		ClientOrderID: req.GetClientOrderId(),
		VenueOrderID:  req.GetVenueOrderId(),
	}

	res, err := s.facade.Status(ctx, query)
	if err != nil {
		return nil, status.Errorf(codes.Internal, "status lookup failed: %v", err)
	}

	return &tradinggatewayv1.OrderStatus{
		VenueOrderId:   res.VenueOrderID,
		ClientOrderId:  res.ClientOrderID,
		Status:         res.Status,
		FilledQuantity: res.FilledQuantity,
		AveragePrice:   res.AveragePrice,
		LastUpdate:     timestamppb.New(res.LastUpdate),
	}, nil
}

// StreamFills is not implemented yet; placeholder for venue streaming.
func (s *TradingService) StreamFills(*tradinggatewayv1.StreamFillsRequest, tradinggatewayv1.TradingGateway_StreamFillsServer) error {
	return status.Error(codes.Unimplemented, "stream fills not yet available")
}

func toDomainOrder(req *tradinggatewayv1.OrderRequest) (order.Order, error) {
	if req == nil {
		return order.Order{}, fmt.Errorf("request is nil")
	}
	side, err := toSideString(req.GetSide())
	if err != nil {
		return order.Order{}, err
	}
	tif, err := toTIFString(req.GetTimeInForce())
	if err != nil {
		return order.Order{}, err
	}
	return order.Order{
		ClientOrderID:  req.GetClientOrderId(),
		Venue:          req.GetVenue(),
		Symbol:         req.GetSymbol(),
		Side:           side,
		Quantity:       req.GetQuantity(),
		Price:          req.GetPrice(),
		TimeInForce:    tif,
		IdempotencyKey: req.GetIdempotencyKey(),
		Attributes:     req.GetAttributes(),
	}, nil
}

func toSideString(side tradinggatewayv1.OrderSide) (string, error) {
	switch side {
	case tradinggatewayv1.OrderSide_ORDER_SIDE_BUY:
		return "BUY", nil
	case tradinggatewayv1.OrderSide_ORDER_SIDE_SELL:
		return "SELL", nil
	case tradinggatewayv1.OrderSide_ORDER_SIDE_UNSPECIFIED:
		return "", fmt.Errorf("side unspecified")
	default:
		return "", fmt.Errorf("unknown side %v", side)
	}
}

func toTIFString(tif tradinggatewayv1.TimeInForce) (string, error) {
	switch tif {
	case tradinggatewayv1.TimeInForce_TIME_IN_FORCE_GTC:
		return "GTC", nil
	case tradinggatewayv1.TimeInForce_TIME_IN_FORCE_IOC:
		return "IOC", nil
	case tradinggatewayv1.TimeInForce_TIME_IN_FORCE_FOK:
		return "FOK", nil
	case tradinggatewayv1.TimeInForce_TIME_IN_FORCE_UNSPECIFIED:
		return "", nil
	default:
		return "", fmt.Errorf("unknown time in force %v", tif)
	}
}
