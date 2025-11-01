package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	defaultBaseURL        = "https://api.bitget.com"
	defaultHealthcheckURL = "https://api.bitget.com/api/v2/spot/market/tickers?symbol=BTCUSDT"
	defaultWSPublic       = "wss://ws.bitget.com/v2/ws/public"
	defaultWSPrivate      = "wss://ws.bitget.com/v2/ws/private"
)

type config struct {
	APIKey         string
	APISecret      string
	Passphrase     string
	BaseURL        string
	WSPublic       string
	WSPrivate      string
	HealthcheckURL string
	Locale         string
}

type accountAssetsResponse struct {
	Code        string                   `json:"code"`
	Msg         string                   `json:"msg"`
	RequestTime int64                    `json:"requestTime"`
	Data        []map[string]interface{} `json:"data"`
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("configuration error: %v", err)
	}

	if len(os.Args) > 1 && os.Args[1] == "--healthcheck" {
		if err := runHealthcheck(cfg); err != nil {
			log.Printf("healthcheck failed: %v", err)
			os.Exit(1)
		}
		fmt.Println("Bitget SDK health check successful.")
		return
	}

    log.Printf("Bitget Golang SDK adapter running… base_url=%s ws_public=%s ws_private=%s", cfg.BaseURL, cfg.WSPublic, cfg.WSPrivate)
	if os.Getenv("DEBUG") == "1" {
	}
	log.Printf("Healthcheck endpoint: %s", cfg.HealthcheckURL)
	if cfg.Locale != "" {
		log.Printf("Using locale header: %s", cfg.Locale)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Run once immediately before starting the ticker
	if err := pollMainAccountAssets(cfg); err != nil {
		log.Printf("account poll error (initial): %v", err)
	} else {
		log.Print("account assets polled successfully (initial)")
	}

	// Then poll every minute for main account assets
	ticker := time.NewTicker(1 * time.Minute)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Print("Shutdown signal received; exiting")
			return
		case <-ticker.C:
			// Main account assets poll
			if err := pollMainAccountAssets(cfg); err != nil {
				log.Printf("account poll error: %v", err)
			} else {
				log.Print("account assets polled successfully")
			}
		}
	}
}

func loadConfig() (config, error) {
	trim := func(val string) string {
		return strings.TrimSpace(val)
	}

	cfg := config{
		APIKey:         trim(os.Getenv("BITGET_API_KEY")),
		APISecret:      trim(os.Getenv("BITGET_API_SECRET")),
		Passphrase:     trim(os.Getenv("BITGET_PASSPHRASE")),
		BaseURL:        trimOrDefault(os.Getenv("BITGET_BASE_URL"), defaultBaseURL),
		WSPublic:       trimOrDefault(os.Getenv("BITGET_WS_PUB"), defaultWSPublic),
		WSPrivate:      trimOrDefault(os.Getenv("BITGET_WS_PRIV"), defaultWSPrivate),
		HealthcheckURL: trimOrDefault(os.Getenv("BITGET_HEALTHCHECK_URL"), defaultHealthcheckURL),
		Locale:         trimOrDefault(os.Getenv("BITGET_LOCALE"), "en-US"),
	}

	var missing []string
	if cfg.APIKey == "" {
		missing = append(missing, "BITGET_API_KEY")
	}
	if cfg.APISecret == "" {
		missing = append(missing, "BITGET_API_SECRET")
	}
	if cfg.Passphrase == "" {
		missing = append(missing, "BITGET_PASSPHRASE")
	}

	if len(missing) > 0 {
		return cfg, fmt.Errorf("missing required environment variables: %s", strings.Join(missing, ", "))
	}

	return cfg, nil
}

func runHealthcheck(cfg config) error {
	if cfg.HealthcheckURL == "" {
		return fmt.Errorf("BITGET_HEALTHCHECK_URL is not configured")
	}

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(cfg.HealthcheckURL)
	if err != nil {
		return fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("unexpected status code: %s", resp.Status)
	}

	return nil
}

// pollMainAccountAssets calls the Bitget Spot Account Assets endpoint and logs the body length.
// Docs: GET /api/v2/spot/account/assets (no params)
func pollMainAccountAssets(cfg config) error {
	const path = "/api/v2/spot/account/assets"
	ts := fmt.Sprintf("%d", time.Now().UnixMilli())
	sign := signPayload(ts, http.MethodGet, path, "", cfg.APISecret)

	req, err := http.NewRequest(http.MethodGet, cfg.BaseURL+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("ACCESS-KEY", cfg.APIKey)
	req.Header.Set("ACCESS-SIGN", sign)
	req.Header.Set("ACCESS-PASSPHRASE", cfg.Passphrase)
	req.Header.Set("ACCESS-TIMESTAMP", ts)
	req.Header.Set("locale", cfg.Locale)
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	payload := string(body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("status=%s body=%s", resp.Status, truncate(payload, 512))
	}
	log.Printf("account-assets ok: %d bytes", len(body))

	var parsed accountAssetsResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		log.Printf("account-assets parse error: %v", err)
		log.Printf("account-assets raw payload: %s", truncate(payload, 2048))
		return nil
	}

	log.Printf("account-assets summary: code=%s msg=%s entries=%d requestTime=%d", parsed.Code, parsed.Msg, len(parsed.Data), parsed.RequestTime)
	if len(parsed.Data) == 0 {
		log.Print("account-assets summary: data array is empty")
	}

	for _, entry := range parsed.Data {
		coin := valueAsString(entry["coin"])
		available := valueAsString(entry["available"])
		frozen := valueAsString(entry["frozen"])
		locked := valueAsString(entry["locked"])
		total := valueAsString(entry["total"])
		if total == "" {
			total = valueAsString(entry["usdtValue"])
		}
		log.Printf("asset coin=%s available=%s frozen=%s locked=%s total=%s raw=%v", coin, available, frozen, locked, total, entry)
	}

	// Pretty print JSON payload for easier debugging
	if pretty, err := prettyJSON(payload); err == nil {
		log.Print("account-assets payload:")
		for _, line := range strings.Split(pretty, "\n") {
			log.Print(line)
		}
	}
	return nil
}

// prettyJSON attempts to format JSON strings for readable logging.
func prettyJSON(raw string) (string, error) {
	if strings.TrimSpace(raw) == "" {
		return raw, nil
	}

	var buf bytes.Buffer
	if err := json.Indent(&buf, []byte(raw), "", "  "); err != nil {
		return "", err
	}
	return buf.String(), nil
}

func valueAsString(v interface{}) string {
	switch t := v.(type) {
	case string:
		return t
	case float64:
		return strconv.FormatFloat(t, 'f', -1, 64)
	case int:
		return strconv.Itoa(t)
	case int64:
		return strconv.FormatInt(t, 10)
	case uint64:
		return strconv.FormatUint(t, 10)
	case json.Number:
		return t.String()
	case nil:
		return ""
	default:
		return fmt.Sprintf("%v", t)
	}
}

func signPayload(timestamp, method, requestPath, body, secret string) string {
	var b strings.Builder
	b.WriteString(timestamp)
	b.WriteString(method)
	b.WriteString(requestPath)
	if body != "" && body != "?" {
		b.WriteString(body)
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(b.String()))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func maskSecret(secret string) string {
	if secret == "" {
		return "<empty>"
	}

	if len(secret) <= 6 {
		return "***"
	}

	return fmt.Sprintf("%s***%s", secret[:3], secret[len(secret)-2:])
}

func trimOrDefault(value, fallback string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return fallback
	}
	return value
}
