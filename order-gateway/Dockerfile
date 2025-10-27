FROM golang:1.25 as builder

WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .
# Ensure go.sum is populated even if the workspace starts empty
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod tidy
RUN --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -mod=mod -trimpath -ldflags "-s -w" -o /out/order-service ./

FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=builder /out/order-service /app/order-service
USER nonroot:nonroot
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/app/order-service"]
