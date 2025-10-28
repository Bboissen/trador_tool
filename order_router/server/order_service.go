package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"time"

	orderpb "order-gateway/pkg/pb/trading/order/v1"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/protobuf/types/known/structpb"
	"google.golang.org/protobuf/types/known/timestamppb"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

type OrderService struct {
	orderpb.UnimplementedOrderServiceServer
	pool *pgxpool.Pool
}

func NewOrderService(pool *pgxpool.Pool) *OrderService {
	return &OrderService{pool: pool}
}

// CreateOrder issues a new order via api.create_order and returns the created snapshot
func (s *OrderService) CreateOrder(ctx context.Context, req *orderpb.CreateOrderRequest) (*orderpb.CreateOrderResponse, error) {
	orderID, err := s.createOrder(ctx, req)
	if err != nil {
		return nil, err
	}
	ord, err := s.loadOrderByID(ctx, orderID)
	if err != nil {
		return nil, err
	}
	return &orderpb.CreateOrderResponse{Order: ord}, nil
}

// AddOrderFill records a new fill and returns the fill and updated order
func (s *OrderService) AddOrderFill(ctx context.Context, req *orderpb.AddOrderFillRequest) (*orderpb.AddOrderFillResponse, error) {
	fillID, err := s.addOrderFill(ctx, req)
	if err != nil {
		return nil, err
	}
	f, err := s.loadFillByID(ctx, fillID)
	if err != nil {
		return nil, err
	}
	ord, err := s.loadOrderByID(ctx, f.OrderId)
	if err != nil {
		return nil, err
	}
	return &orderpb.AddOrderFillResponse{Fill: f, Order: ord}, nil
}

// UpdateOrderLifecycle advances an order and returns the updated order
func (s *OrderService) UpdateOrderLifecycle(ctx context.Context, req *orderpb.UpdateOrderLifecycleRequest) (*orderpb.UpdateOrderLifecycleResponse, error) {
	if _, err := s.pool.Exec(ctx,
		`SELECT api.update_order_lifecycle($1, $2, $3, $4, $5)`,
		req.GetOrderId(), fromPbOrderStatus(req.GetNewStatus()), tsOrNil(req.GetTriggeredAt()), tsOrNil(req.GetCompletedAt()), structOrNil(req.GetMetadata()),
	); err != nil {
		return nil, err
	}
	ord, err := s.loadOrderByID(ctx, req.GetOrderId())
	if err != nil {
		return nil, err
	}
	return &orderpb.UpdateOrderLifecycleResponse{Order: ord}, nil
}

// GetOrder returns the order and its fills
func (s *OrderService) GetOrder(ctx context.Context, req *orderpb.GetOrderRequest) (*orderpb.GetOrderResponse, error) {
	ord, err := s.loadOrderByID(ctx, req.GetOrderId())
	if err != nil {
		return nil, err
	}
	fills, err := s.listFills(ctx, req.GetOrderId(), nil, 0)
	if err != nil {
		return nil, err
	}
	return &orderpb.GetOrderResponse{Order: ord, Fills: fills}, nil
}

// ListOrderFills returns paginated fills after an optional timestamp
func (s *OrderService) ListOrderFills(ctx context.Context, req *orderpb.ListOrderFillsRequest) (*orderpb.ListOrderFillsResponse, error) {
	var after *time.Time
	if req.GetExecutedAfter() != nil {
		t := req.GetExecutedAfter().AsTime()
		after = &t
	}
	sz := req.GetPageSize()
	if sz <= 0 || sz > 500 {
		sz = 50
	}
	fills, err := s.listFills(ctx, req.GetOrderId(), after, int(sz))
	if err != nil {
		return nil, err
	}
	return &orderpb.ListOrderFillsResponse{Fills: fills}, nil
}

// --- internals ---

func (s *OrderService) createOrder(ctx context.Context, r *orderpb.CreateOrderRequest) (string, error) {
	var orderID string
	err := s.pool.QueryRow(ctx, `
		SELECT api.create_order(
			$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22
		)
	`,
		r.GetStrategyId(), int32OrNil(r.GetSourceNetworkId()), int32OrNil(r.GetDestNetworkId()), r.GetAdapterKey(), r.GetIdempotencyKey(), r.GetAssetInRef(), r.GetAssetOutRef(),
		fromPbSide(r.GetSide()), fromPbType(r.GetType()), fromPbTIF(r.GetTif()), r.GetReduceOnly(), r.GetPostOnly(), strOrNil(r.GetLeverage()), fromPbMarginMode(r.GetMarginMode()),
		r.GetAmountIn(), strPtrOrNil(r.GetAmountOutMin()), strPtrOrNil(r.GetLimitPrice()), strPtrOrNil(r.GetStopPrice()), strPtrOrNil(r.GetSlippageTolerance()),
		r.GetTags(), structOrNil(r.GetMetadata()), structOrNil(r.GetExecutionPreferences()),
	).Scan(&orderID)
	if err != nil {
		return "", err
	}
	return orderID, nil
}

func (s *OrderService) addOrderFill(ctx context.Context, r *orderpb.AddOrderFillRequest) (string, error) {
	var fillID string
	err := s.pool.QueryRow(ctx, `
		SELECT api.add_order_fill(
			$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12
		)
	`,
		r.GetOrderId(), r.GetIdempotencyKey(), r.GetAmountIn(), r.GetAmountOut(), r.GetPrice(), strPtrOrNil(r.GetFeeAmount()), strPtrOrNil(r.GetFeeAssetRef()),
		strPtrOrNil(r.GetAdapterKey()), byteaOrNil(r.GetTxHash()), int64OrNil(r.GetBlockNumber()), int32OrNil(r.GetLogIndex()), fromPbTxStatus(r.GetStatus()),
	).Scan(&fillID)
	if err != nil {
		return "", err
	}
	return fillID, nil
}

func (s *OrderService) loadOrderByID(ctx context.Context, id string) (*orderpb.Order, error) {
	row := s.pool.QueryRow(ctx, `
		SELECT 
			id::text,
			strategy_id,
			source_network_id,
			dest_network_id,
			adapter_key,
			idempotency_key,
			asset_in_ref,
			asset_out_ref,
			side::text,
			type::text,
			tif::text,
			reduce_only,
			post_only,
			leverage::text,
			margin_mode::text,
			amount_in::text,
			amount_out_min::text,
			filled_amount::text,
			limit_price::text,
			stop_price::text,
			average_fill_price::text,
			slippage_tolerance::text,
			status::text,
			version,
			event_version,
			created_at, submitted_at, acked_at, updated_at, triggered_at, completed_at, expired_at, canceled_at,
			tags,
			metadata::text,
			execution_preferences::text
		FROM trading.orders WHERE id = $1
	`, id)
	var (
		orderID      string
		strategyID   int32
		srcID        sql.NullInt64
		dstID        sql.NullInt64
		adapterKey   string
		idem         string
		assetIn      string
		assetOut     string
		sideStr      string
		typeStr      string
		tifStr       string
		reduceOnly   bool
		postOnly     bool
		leverage     sql.NullString
		marginMode   sql.NullString
		amountIn     string
		amountOutMin sql.NullString
		filledAmount string
		limitPrice   sql.NullString
		stopPrice    sql.NullString
		avgFillPrice sql.NullString
		slip         sql.NullString
		statusStr    string
		version      int64
		eventVersion int64
		createdAt    time.Time
		submittedAt  sql.NullTime
		ackedAt      sql.NullTime
		updatedAt    time.Time
		triggeredAt  sql.NullTime
		completedAt  sql.NullTime
		expiredAt    sql.NullTime
		canceledAt   sql.NullTime
		tags         []string
		metadata     json.RawMessage
		execPrefs    json.RawMessage
	)
	if err := row.Scan(
		&orderID, &strategyID, &srcID, &dstID, &adapterKey, &idem, &assetIn, &assetOut,
		&sideStr, &typeStr, &tifStr, &reduceOnly, &postOnly, &leverage, &marginMode,
		&amountIn, &amountOutMin, &filledAmount, &limitPrice, &stopPrice, &avgFillPrice, &slip,
		&statusStr, &version, &eventVersion, &createdAt, &submittedAt, &ackedAt, &updatedAt, &triggeredAt, &completedAt, &expiredAt, &canceledAt,
		&tags, &metadata, &execPrefs,
	); err != nil {
		return nil, err
	}
	ord := &orderpb.Order{
		Id:                   orderID,
		StrategyId:           strategyID,
		SourceNetworkId:      int32Wrap(srcID),
		DestNetworkId:        int32Wrap(dstID),
		AdapterKey:           adapterKey,
		IdempotencyKey:       idem,
		AssetInRef:           assetIn,
		AssetOutRef:          assetOut,
		Side:                 toPbSide(sideStr),
		Type:                 toPbType(typeStr),
		Tif:                  toPbTIF(tifStr),
		ReduceOnly:           reduceOnly,
		PostOnly:             postOnly,
		Leverage:             strWrap(leverage),
		MarginMode:           toPbMarginMode(nilIfEmpty(marginMode)),
		AmountIn:             amountIn,
		AmountOutMin:         strWrap(amountOutMin),
		FilledAmount:         filledAmount,
		LimitPrice:           strWrap(limitPrice),
		StopPrice:            strWrap(stopPrice),
		AverageFillPrice:     strWrap(avgFillPrice),
		SlippageTolerance:    strWrap(slip),
		Status:               toPbOrderStatus(statusStr),
		Version:              version,
		EventVersion:         eventVersion,
		CreatedAt:            timestamppb.New(createdAt),
		SubmittedAt:          tsWrap(submittedAt),
		AckedAt:              tsWrap(ackedAt),
		UpdatedAt:            timestamppb.New(updatedAt),
		TriggeredAt:          tsWrap(triggeredAt),
		CompletedAt:          tsWrap(completedAt),
		ExpiredAt:            tsWrap(expiredAt),
		CanceledAt:           tsWrap(canceledAt),
		Tags:                 tags,
		Metadata:             structFromJSON(metadata),
		ExecutionPreferences: structFromJSON(execPrefs),
	}
	return ord, nil
}

func (s *OrderService) loadFillByID(ctx context.Context, id string) (*orderpb.OrderFill, error) {
	row := s.pool.QueryRow(ctx, `
		SELECT 
			id::text,
			order_id::text,
			idempotency_key,
			amount_in::text,
			amount_out::text,
			price::text,
			fee_amount::text,
			fee_asset_ref,
			adapter_key,
			tx_hash,
			block_number,
			log_index::bigint,
			status::text,
			confirmed_at,
			reverted_at,
			executed_at
		FROM trading.order_fills WHERE id = $1
	`, id)
	var (
		fid         string
		orderID     string
		iKey        string
		amountIn    string
		amountOut   string
		price       string
		feeAmount   sql.NullString
		feeAsset    sql.NullString
		adapterKey  sql.NullString
		txHash      []byte
		blockNum    sql.NullInt64
		logIndex    sql.NullInt64
		statusStr   string
		confirmedAt sql.NullTime
		revertedAt  sql.NullTime
		executedAt  time.Time
	)
	if err := row.Scan(&fid, &orderID, &iKey, &amountIn, &amountOut, &price, &feeAmount, &feeAsset, &adapterKey, &txHash, &blockNum, &logIndex, &statusStr, &confirmedAt, &revertedAt, &executedAt); err != nil {
		return nil, err
	}
	fill := &orderpb.OrderFill{
		Id:             fid,
		OrderId:        orderID,
		IdempotencyKey: iKey,
		AmountIn:       amountIn,
		AmountOut:      amountOut,
		Price:          price,
		FeeAmount:      strWrap(feeAmount),
		FeeAssetRef:    strWrap(feeAsset),
		AdapterKey:     stringOrDefault(adapterKey, ""),
		TxHash:         txHash,
		BlockNumber:    int64Wrap(blockNum),
		LogIndex:       int32WrapFrom64(logIndex),
		Status:         toPbTxStatus(statusStr),
		ConfirmedAt:    tsWrap(confirmedAt),
		RevertedAt:     tsWrap(revertedAt),
		ExecutedAt:     timestamppb.New(executedAt),
	}
	return fill, nil
}

func (s *OrderService) listFills(ctx context.Context, orderID string, after *time.Time, limit int) ([]*orderpb.OrderFill, error) {
	var rows pgx.Rows
	var err error
	if after != nil {
		if limit > 0 {
			rows, err = s.pool.Query(ctx, `
				SELECT id::text, order_id::text, idempotency_key, amount_in::text, amount_out::text, price::text,
				       fee_amount::text, fee_asset_ref, adapter_key, tx_hash, block_number, log_index::bigint, status::text,
				       confirmed_at, reverted_at, executed_at
				FROM trading.order_fills
				WHERE order_id = $1 AND executed_at > $2
				ORDER BY executed_at ASC
				LIMIT $3
			`, orderID, *after, limit)
		} else {
			rows, err = s.pool.Query(ctx, `
				SELECT id::text, order_id::text, idempotency_key, amount_in::text, amount_out::text, price::text,
				       fee_amount::text, fee_asset_ref, adapter_key, tx_hash, block_number, log_index::bigint, status::text,
				       confirmed_at, reverted_at, executed_at
				FROM trading.order_fills
				WHERE order_id = $1 AND executed_at > $2
				ORDER BY executed_at ASC
			`, orderID, *after)
		}
	} else {
		if limit > 0 {
			rows, err = s.pool.Query(ctx, `
				SELECT id::text, order_id::text, idempotency_key, amount_in::text, amount_out::text, price::text,
				       fee_amount::text, fee_asset_ref, adapter_key, tx_hash, block_number, log_index::bigint, status::text,
				       confirmed_at, reverted_at, executed_at
				FROM trading.order_fills
				WHERE order_id = $1
				ORDER BY executed_at ASC
				LIMIT $2
			`, orderID, limit)
		} else {
			rows, err = s.pool.Query(ctx, `
				SELECT id::text, order_id::text, idempotency_key, amount_in::text, amount_out::text, price::text,
				       fee_amount::text, fee_asset_ref, adapter_key, tx_hash, block_number, log_index::bigint, status::text,
				       confirmed_at, reverted_at, executed_at
				FROM trading.order_fills
				WHERE order_id = $1
				ORDER BY executed_at ASC
			`, orderID)
		}
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var fills []*orderpb.OrderFill
	for rows.Next() {
		var (
			fid         string
			ordID       string
			iKey        string
			amountIn    string
			amountOut   string
			price       string
			feeAmount   sql.NullString
			feeAsset    sql.NullString
			adapterKey  sql.NullString
			txHash      []byte
			blockNum    sql.NullInt64
			logIndex    sql.NullInt64
			statusStr   string
			confirmedAt sql.NullTime
			revertedAt  sql.NullTime
			executedAt  time.Time
		)
		if err := rows.Scan(&fid, &ordID, &iKey, &amountIn, &amountOut, &price, &feeAmount, &feeAsset, &adapterKey, &txHash, &blockNum, &logIndex, &statusStr, &confirmedAt, &revertedAt, &executedAt); err != nil {
			return nil, err
		}
		fills = append(fills, &orderpb.OrderFill{
			Id:             fid,
			OrderId:        ordID,
			IdempotencyKey: iKey,
			AmountIn:       amountIn,
			AmountOut:      amountOut,
			Price:          price,
			FeeAmount:      strWrap(feeAmount),
			FeeAssetRef:    strWrap(feeAsset),
			AdapterKey:     stringOrDefault(adapterKey, ""),
			TxHash:         txHash,
			BlockNumber:    int64Wrap(blockNum),
			LogIndex:       int32WrapFrom64(logIndex),
			Status:         toPbTxStatus(statusStr),
			ConfirmedAt:    tsWrap(confirmedAt),
			RevertedAt:     tsWrap(revertedAt),
			ExecutedAt:     timestamppb.New(executedAt),
		})
	}
	return fills, rows.Err()
}

// --- helpers ---

func int32OrNil(v *wrapperspb.Int32Value) any {
	if v == nil {
		return nil
	}
	return v.Value
}

func int64OrNil(v *wrapperspb.Int64Value) any {
	if v == nil {
		return nil
	}
	return v.Value
}

func int32Wrap(v sql.NullInt64) *wrapperspb.Int32Value {
	if !v.Valid {
		return nil
	}
	return wrapperspb.Int32(int32(v.Int64))
}

func int32WrapFrom64(v sql.NullInt64) *wrapperspb.Int32Value {
	if !v.Valid {
		return nil
	}
	return wrapperspb.Int32(int32(v.Int64))
}

func strOrNil(v string) any {
	if v == "" {
		return nil
	}
	return v
}

func strPtrOrNil(v *wrapperspb.StringValue) any {
	if v == nil {
		return nil
	}
	return v.Value
}

func strWrap(v sql.NullString) *wrapperspb.StringValue {
	if !v.Valid || v.String == "" {
		return nil
	}
	return wrapperspb.String(v.String)
}

func int64Wrap(v sql.NullInt64) *wrapperspb.Int64Value {
	if !v.Valid {
		return nil
	}
	return wrapperspb.Int64(v.Int64)
}

func tsOrNil(ts *timestamppb.Timestamp) any {
	if ts == nil {
		return nil
	}
	return ts.AsTime()
}

func tsWrap(v sql.NullTime) *timestamppb.Timestamp {
	if !v.Valid {
		return nil
	}
	return timestamppb.New(v.Time)
}

func structOrNil(s *structpb.Struct) any {
	if s == nil {
		return nil
	}
	// store as jsonb via text
	b, _ := json.Marshal(s.AsMap())
	return string(b)
}

func structFromJSON(raw json.RawMessage) *structpb.Struct {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil
	}
	st, _ := structpb.NewStruct(m)
	return st
}

func byteaOrNil(b []byte) any {
	if len(b) == 0 {
		return nil
	}
	return b
}

func fromPbSide(s orderpb.OrderSide) string {
	switch s {
	case orderpb.OrderSide_ORDER_SIDE_BUY:
		return "BUY"
	case orderpb.OrderSide_ORDER_SIDE_SELL:
		return "SELL"
	default:
		return "BUY"
	}
}

func fromPbType(t orderpb.OrderType) string {
	switch t {
	case orderpb.OrderType_ORDER_TYPE_MARKET:
		return "MARKET"
	case orderpb.OrderType_ORDER_TYPE_LIMIT:
		return "LIMIT"
	case orderpb.OrderType_ORDER_TYPE_STOP:
		return "STOP"
	case orderpb.OrderType_ORDER_TYPE_STOP_LIMIT:
		return "STOP_LIMIT"
	case orderpb.OrderType_ORDER_TYPE_TWAP:
		return "TWAP"
	case orderpb.OrderType_ORDER_TYPE_DCA:
		return "DCA"
	case orderpb.OrderType_ORDER_TYPE_SCALE:
		return "SCALE"
	case orderpb.OrderType_ORDER_TYPE_TRAILING_STOP:
		return "TRAILING_STOP"
	default:
		return "MARKET"
	}
}

func fromPbTIF(t orderpb.TimeInForce) string {
	switch t {
	case orderpb.TimeInForce_TIME_IN_FORCE_GTC:
		return "GTC"
	case orderpb.TimeInForce_TIME_IN_FORCE_IOC:
		return "IOC"
	case orderpb.TimeInForce_TIME_IN_FORCE_FOK:
		return "FOK"
	case orderpb.TimeInForce_TIME_IN_FORCE_GTD:
		return "GTD"
	default:
		return "GTC"
	}
}

func fromPbMarginMode(m orderpb.MarginMode) any {
	switch m {
	case orderpb.MarginMode_MARGIN_MODE_CROSS:
		return "CROSS"
	case orderpb.MarginMode_MARGIN_MODE_ISOLATED:
		return "ISOLATED"
	default:
		return nil
	}
}

func fromPbTxStatus(s orderpb.TransactionStatus) string {
	switch s {
	case orderpb.TransactionStatus_TRANSACTION_STATUS_PENDING:
		return "PENDING"
	case orderpb.TransactionStatus_TRANSACTION_STATUS_CONFIRMED:
		return "CONFIRMED"
	case orderpb.TransactionStatus_TRANSACTION_STATUS_FAILED:
		return "FAILED"
	case orderpb.TransactionStatus_TRANSACTION_STATUS_REVERTED:
		return "REVERTED"
	default:
		return "CONFIRMED"
	}
}

func fromPbOrderStatus(s orderpb.OrderStatus) string {
	switch s {
	case orderpb.OrderStatus_ORDER_STATUS_PENDING:
		return "PENDING"
	case orderpb.OrderStatus_ORDER_STATUS_OPEN:
		return "OPEN"
	case orderpb.OrderStatus_ORDER_STATUS_PARTIALLY_FILLED:
		return "PARTIALLY_FILLED"
	case orderpb.OrderStatus_ORDER_STATUS_FILLED:
		return "FILLED"
	case orderpb.OrderStatus_ORDER_STATUS_CANCELLED:
		return "CANCELLED"
	case orderpb.OrderStatus_ORDER_STATUS_REJECTED:
		return "REJECTED"
	case orderpb.OrderStatus_ORDER_STATUS_EXPIRED:
		return "EXPIRED"
	default:
		return "PENDING"
	}
}

func toPbSide(s string) orderpb.OrderSide {
	switch s {
	case "BUY":
		return orderpb.OrderSide_ORDER_SIDE_BUY
	case "SELL":
		return orderpb.OrderSide_ORDER_SIDE_SELL
	default:
		return orderpb.OrderSide_ORDER_SIDE_UNSPECIFIED
	}
}

func toPbType(s string) orderpb.OrderType {
	switch s {
	case "MARKET":
		return orderpb.OrderType_ORDER_TYPE_MARKET
	case "LIMIT":
		return orderpb.OrderType_ORDER_TYPE_LIMIT
	case "STOP":
		return orderpb.OrderType_ORDER_TYPE_STOP
	case "STOP_LIMIT":
		return orderpb.OrderType_ORDER_TYPE_STOP_LIMIT
	case "TWAP":
		return orderpb.OrderType_ORDER_TYPE_TWAP
	case "DCA":
		return orderpb.OrderType_ORDER_TYPE_DCA
	case "SCALE":
		return orderpb.OrderType_ORDER_TYPE_SCALE
	case "TRAILING_STOP":
		return orderpb.OrderType_ORDER_TYPE_TRAILING_STOP
	default:
		return orderpb.OrderType_ORDER_TYPE_UNSPECIFIED
	}
}

func toPbTIF(s string) orderpb.TimeInForce {
	switch s {
	case "GTC":
		return orderpb.TimeInForce_TIME_IN_FORCE_GTC
	case "IOC":
		return orderpb.TimeInForce_TIME_IN_FORCE_IOC
	case "FOK":
		return orderpb.TimeInForce_TIME_IN_FORCE_FOK
	case "GTD":
		return orderpb.TimeInForce_TIME_IN_FORCE_GTD
	default:
		return orderpb.TimeInForce_TIME_IN_FORCE_UNSPECIFIED
	}
}

func toPbMarginMode(s *string) orderpb.MarginMode {
	if s == nil {
		return orderpb.MarginMode_MARGIN_MODE_UNSPECIFIED
	}
	switch *s {
	case "CROSS":
		return orderpb.MarginMode_MARGIN_MODE_CROSS
	case "ISOLATED":
		return orderpb.MarginMode_MARGIN_MODE_ISOLATED
	default:
		return orderpb.MarginMode_MARGIN_MODE_UNSPECIFIED
	}
}

func toPbOrderStatus(s string) orderpb.OrderStatus {
	switch s {
	case "PENDING":
		return orderpb.OrderStatus_ORDER_STATUS_PENDING
	case "OPEN":
		return orderpb.OrderStatus_ORDER_STATUS_OPEN
	case "PARTIALLY_FILLED":
		return orderpb.OrderStatus_ORDER_STATUS_PARTIALLY_FILLED
	case "FILLED":
		return orderpb.OrderStatus_ORDER_STATUS_FILLED
	case "CANCELLED":
		return orderpb.OrderStatus_ORDER_STATUS_CANCELLED
	case "REJECTED":
		return orderpb.OrderStatus_ORDER_STATUS_REJECTED
	case "EXPIRED":
		return orderpb.OrderStatus_ORDER_STATUS_EXPIRED
	default:
		return orderpb.OrderStatus_ORDER_STATUS_UNSPECIFIED
	}
}

func toPbTxStatus(s string) orderpb.TransactionStatus {
	switch s {
	case "PENDING":
		return orderpb.TransactionStatus_TRANSACTION_STATUS_PENDING
	case "CONFIRMED":
		return orderpb.TransactionStatus_TRANSACTION_STATUS_CONFIRMED
	case "FAILED":
		return orderpb.TransactionStatus_TRANSACTION_STATUS_FAILED
	case "REVERTED":
		return orderpb.TransactionStatus_TRANSACTION_STATUS_REVERTED
	default:
		return orderpb.TransactionStatus_TRANSACTION_STATUS_UNSPECIFIED
	}
}

func stringOrDefault(ns sql.NullString, def string) string {
	if ns.Valid {
		return ns.String
	}
	return def
}

func nilIfEmpty(ns sql.NullString) *string {
	if ns.Valid && ns.String != "" {
		return &ns.String
	}
	return nil
}
