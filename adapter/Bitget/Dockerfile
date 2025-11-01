FROM golang:1.25-alpine AS builder

WORKDIR /app

# Install git for fetching dependencies
RUN apk add --no-cache git

# Pin the Bitget Golang SDK to a specific revision for reproducibility
ARG BITGET_SDK_COMMIT=9bdab50a014598875f9fd07faa09f22001fb5877
RUN git clone https://github.com/BitgetLimited/v3-bitget-api-sdk.git \
    && cd v3-bitget-api-sdk \
    && git checkout --detach "${BITGET_SDK_COMMIT}"

WORKDIR /app/v3-bitget-api-sdk/bitget-golang-sdk-api
COPY main.go .

# Build the application
RUN go mod tidy && go build -o /app/bitget-adapter main.go

FROM alpine:3.22

# Install runtime dependencies and create non-root user
RUN apk add --no-cache ca-certificates \
    && addgroup -S bitget \
    && adduser -S -G bitget bitget

WORKDIR /app

# Copy the built binary from the builder stage
COPY --from=builder /app/bitget-adapter ./bitget-adapter
COPY healthcheck.sh .
RUN chmod +x healthcheck.sh && chown bitget:bitget bitget-adapter healthcheck.sh

# Provide sane defaults that can be overridden at runtime
ENV BITGET_API_KEY="" \
    BITGET_API_SECRET="" \
    BITGET_PASSPHRASE="" \
    BITGET_BASE_URL="https://api.bitget.com" \
    BITGET_WS_PUB="wss://ws.bitget.com/v2/ws/public" \
    BITGET_WS_PRIV="wss://ws.bitget.com/v2/ws/private" \
    BITGET_HEALTHCHECK_URL="https://api.bitget.com/api/v2/spot/market/tickers?symbol=BTCUSDT" \
    BITGET_LOCALE="en-US"

USER bitget

ENTRYPOINT ["./bitget-adapter"]
