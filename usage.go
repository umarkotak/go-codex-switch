package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

const defaultCodexUsageEndpoint = "https://chatgpt.com/backend-api/wham/usage"
const defaultCodexResetCreditsEndpoint = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"

type CodexUsageClient struct {
	Endpoint             string
	ResetCreditsEndpoint string
	HTTPClient           *http.Client
}

type CodexUsageResponse struct {
	PlanType  string                `json:"plan_type"`
	RateLimit CodexRateLimitDetails `json:"rate_limit"`
	Credits   *CodexCreditDetails   `json:"credits"`
}

type CodexRateLimitDetails struct {
	PrimaryWindow   *CodexUsageWindow `json:"primary_window"`
	SecondaryWindow *CodexUsageWindow `json:"secondary_window"`
}

type CodexUsageWindow struct {
	UsedPercent        float64 `json:"used_percent"`
	ResetAt            int64   `json:"reset_at"`
	LimitWindowSeconds int     `json:"limit_window_seconds"`
}

type CodexCreditDetails struct {
	HasCredits bool     `json:"has_credits"`
	Unlimited  bool     `json:"unlimited"`
	Balance    *float64 `json:"balance"`
}

type CodexResetCreditsResponse struct {
	AvailableCount int                `json:"available_count"`
	Credits        []CodexResetCredit `json:"credits"`
}

type CodexResetCredit struct {
	ID        string     `json:"id"`
	ResetType string     `json:"reset_type"`
	Status    string     `json:"status"`
	GrantedAt time.Time  `json:"granted_at"`
	ExpiresAt *time.Time `json:"expires_at"`
}

func (details *CodexCreditDetails) UnmarshalJSON(data []byte) error {
	var raw struct {
		HasCredits bool            `json:"has_credits"`
		Unlimited  bool            `json:"unlimited"`
		Balance    json.RawMessage `json:"balance"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}

	*details = CodexCreditDetails{
		HasCredits: raw.HasCredits,
		Unlimited:  raw.Unlimited,
	}
	if len(raw.Balance) == 0 || bytes.Equal(raw.Balance, []byte("null")) {
		return nil
	}

	var number float64
	if err := json.Unmarshal(raw.Balance, &number); err == nil {
		details.Balance = &number
		return nil
	}

	var text string
	if err := json.Unmarshal(raw.Balance, &text); err != nil {
		return nil
	}
	parsed, err := strconv.ParseFloat(text, 64)
	if err != nil {
		return nil
	}

	details.Balance = &parsed
	return nil
}

func DefaultCodexUsageClient() CodexUsageClient {
	return CodexUsageClient{
		Endpoint:             defaultCodexUsageEndpoint,
		ResetCreditsEndpoint: defaultCodexResetCreditsEndpoint,
		HTTPClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

func (client CodexUsageClient) FetchResetCredits(authFile AuthFile) (CodexResetCreditsResponse, error) {
	endpoint := strings.TrimSpace(client.ResetCreditsEndpoint)
	if endpoint == "" {
		endpoint = defaultCodexResetCreditsEndpoint
	}

	request, err := client.newAuthenticatedRequest(endpoint, authFile)
	if err != nil {
		return CodexResetCreditsResponse{}, fmt.Errorf("create reset credits request: %w", err)
	}
	request.Header.Set("OpenAI-Beta", "codex-1")
	request.Header.Set("originator", "Codex Desktop")

	response, err := client.httpClient().Do(request)
	if err != nil {
		return CodexResetCreditsResponse{}, fmt.Errorf("fetch reset credits: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden {
		return CodexResetCreditsResponse{}, errors.New("reset credits auth failed")
	}
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return CodexResetCreditsResponse{}, fmt.Errorf("reset credits api returned %d", response.StatusCode)
	}

	var resetCredits CodexResetCreditsResponse
	if err := json.NewDecoder(response.Body).Decode(&resetCredits); err != nil {
		return CodexResetCreditsResponse{}, fmt.Errorf("parse reset credits response: %w", err)
	}
	if resetCredits.AvailableCount < 0 {
		return CodexResetCreditsResponse{}, errors.New("reset credits api returned a negative available count")
	}

	return resetCredits, nil
}

func (client CodexUsageClient) FetchUsage(authFile AuthFile) (CodexUsageResponse, error) {
	endpoint := strings.TrimSpace(client.Endpoint)
	if endpoint == "" {
		endpoint = defaultCodexUsageEndpoint
	}

	request, err := client.newAuthenticatedRequest(endpoint, authFile)
	if err != nil {
		return CodexUsageResponse{}, fmt.Errorf("create usage request: %w", err)
	}

	response, err := client.httpClient().Do(request)
	if err != nil {
		return CodexUsageResponse{}, fmt.Errorf("fetch usage: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode == http.StatusUnauthorized || response.StatusCode == http.StatusForbidden {
		return CodexUsageResponse{}, errors.New("usage auth failed")
	}
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return CodexUsageResponse{}, fmt.Errorf("usage api returned %d", response.StatusCode)
	}

	var usage CodexUsageResponse
	if err := json.NewDecoder(response.Body).Decode(&usage); err != nil {
		return CodexUsageResponse{}, fmt.Errorf("parse usage response: %w", err)
	}

	return usage, nil
}

func (client CodexUsageClient) newAuthenticatedRequest(endpoint string, authFile AuthFile) (*http.Request, error) {
	accessToken := strings.TrimSpace(authFile.Tokens.AccessToken)
	if accessToken == "" {
		return nil, errors.New("missing access token")
	}

	request, err := http.NewRequest(http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+accessToken)
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", "go-codex-switch")
	if accountID := strings.TrimSpace(authFile.Tokens.AccountID); accountID != "" {
		request.Header.Set("ChatGPT-Account-ID", accountID)
	}

	return request, nil
}

func (client CodexUsageClient) httpClient() *http.Client {
	if client.HTTPClient != nil {
		return client.HTTPClient
	}
	return http.DefaultClient
}

func FormatCodexUsage(usage *CodexUsageResponse, usageError string) string {
	return FormatCodexUsageAt(usage, usageError, time.Now())
}

func FormatCodexUsageAt(usage *CodexUsageResponse, usageError string, now time.Time) string {
	return strings.Join(FormatCodexUsagePartsAt(usage, usageError, now), " | ")
}

func FormatCodexUsagePartsAt(usage *CodexUsageResponse, usageError string, now time.Time) []string {
	if usageError != "" {
		return []string{"usage unavailable"}
	}
	if usage == nil {
		return nil
	}

	parts := make([]string, 0, 2)
	if usage.RateLimit.PrimaryWindow != nil {
		parts = append(parts, "session: "+formatWindowRemaining(usage.RateLimit.PrimaryWindow, now))
	}
	if usage.RateLimit.SecondaryWindow != nil {
		parts = append(parts, "weekly: "+formatWindowRemaining(usage.RateLimit.SecondaryWindow, now))
	}

	if len(parts) == 0 {
		return []string{"usage unavailable"}
	}

	return parts
}

func FormatCodexResetCreditsAt(resetCredits *CodexResetCreditsResponse, now time.Time) string {
	if resetCredits == nil {
		return ""
	}

	available := make([]CodexResetCredit, 0, len(resetCredits.Credits))
	for _, credit := range resetCredits.Credits {
		if credit.Status != "available" {
			continue
		}
		if credit.ExpiresAt != nil && !credit.ExpiresAt.After(now) {
			continue
		}
		available = append(available, credit)
	}
	sort.Slice(available, func(i, j int) bool {
		left, right := available[i].ExpiresAt, available[j].ExpiresAt
		switch {
		case left == nil && right == nil:
			return available[i].ID < available[j].ID
		case left == nil:
			return false
		case right == nil:
			return true
		case !left.Equal(*right):
			return left.Before(*right)
		default:
			return available[i].ID < available[j].ID
		}
	})

	label := fmt.Sprintf("%d reset credits", len(available))
	if len(available) == 1 {
		label = "1 reset credit"
	}
	if len(available) == 0 {
		return label
	}

	expiries := make([]string, 0, len(available))
	for _, credit := range available {
		if credit.ExpiresAt == nil {
			expiries = append(expiries, "no expiry")
			continue
		}
		expiries = append(expiries, credit.ExpiresAt.UTC().Format("2006-01-02"))
	}

	return label + " (" + strings.Join(expiries, ", ") + ")"
}

func formatWindowRemaining(window *CodexUsageWindow, now time.Time) string {
	value := formatRemainingPercent(window.UsedPercent) + " left"
	if resetIn := formatResetIn(window.ResetAt, now); resetIn != "" {
		value += " (" + resetIn + ")"
	}

	return value
}

func formatRemainingPercent(usedPercent float64) string {
	remainingPercent := max(0, 100-usedPercent)
	return formatFloat(remainingPercent) + "%"
}

func formatResetIn(resetAt int64, now time.Time) string {
	if resetAt <= 0 {
		return ""
	}

	resetTime := time.Unix(resetAt, 0)
	if !resetTime.After(now) {
		return ""
	}

	duration := resetTime.Sub(now)
	days := int(duration.Hours()) / 24
	hours := int(duration.Hours()) % 24
	minutes := int(duration.Minutes()) % 60

	switch {
	case days > 0:
		if hours == 0 {
			return fmt.Sprintf("%dd", days)
		}
		return fmt.Sprintf("%dd %dh", days, hours)
	case hours > 0:
		if minutes == 0 {
			return fmt.Sprintf("%dh", hours)
		}
		return fmt.Sprintf("%dh %dm", hours, minutes)
	default:
		if minutes < 1 {
			return "<1m"
		}
		return fmt.Sprintf("%dm", minutes)
	}
}

func formatFloat(value float64) string {
	if value == float64(int64(value)) {
		return fmt.Sprintf("%.0f", value)
	}

	return fmt.Sprintf("%.1f", value)
}
