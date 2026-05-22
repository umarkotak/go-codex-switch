package main

import (
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestCodexUsageClientFetchUsage(t *testing.T) {
	var sawRequest bool
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		sawRequest = true

		if r.Method != http.MethodGet {
			t.Fatalf("method = %s, want GET", r.Method)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer access" {
			t.Fatalf("Authorization = %q, want %q", got, "Bearer access")
		}
		if got := r.Header.Get("ChatGPT-Account-Id"); got != "account" {
			t.Fatalf("ChatGPT-Account-Id = %q, want %q", got, "account")
		}
		if got := r.Header.Get("Accept"); got != "application/json" {
			t.Fatalf("Accept = %q, want %q", got, "application/json")
		}

		return jsonResponse(http.StatusOK, `{
		  "plan_type": "plus",
		  "rate_limit": {
		    "primary_window": {
		      "used_percent": 42,
		      "reset_at": 1779345718,
		      "limit_window_seconds": 18000
		    },
		    "secondary_window": {
		      "used_percent": 12.5,
		      "reset_at": 1779945718,
		      "limit_window_seconds": 604800
		    }
		  },
		  "credits": {
		    "has_credits": true,
		    "unlimited": false,
		    "balance": "10.5"
		  }
		}`), nil
	})}

	usage, err := CodexUsageClient{
		Endpoint:   "https://chatgpt.com/backend-api/wham/usage",
		HTTPClient: client,
	}.FetchUsage(testAuthFile("codingmase@gmail.com"))
	if err != nil {
		t.Fatalf("FetchUsage returned error: %v", err)
	}
	if !sawRequest {
		t.Fatal("server did not receive request")
	}
	if usage.PlanType != "plus" {
		t.Fatalf("plan = %q, want plus", usage.PlanType)
	}
	if usage.RateLimit.PrimaryWindow == nil || usage.RateLimit.PrimaryWindow.UsedPercent != 42 {
		t.Fatalf("primary window = %#v, want 42%% used", usage.RateLimit.PrimaryWindow)
	}
	if usage.RateLimit.SecondaryWindow == nil || usage.RateLimit.SecondaryWindow.UsedPercent != 12.5 {
		t.Fatalf("secondary window = %#v, want 12.5%% used", usage.RateLimit.SecondaryWindow)
	}
	if usage.Credits == nil || usage.Credits.Balance == nil || *usage.Credits.Balance != 10.5 {
		t.Fatalf("credits = %#v, want balance 10.5", usage.Credits)
	}
}

func TestListSavedAuthAccountsWithUsageKeepsPerAccountFailuresNonFatal(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.Header.Get("Authorization") {
		case "Bearer access":
			return jsonResponse(http.StatusOK, `{
			  "plan_type": "plus",
			  "rate_limit": {
			    "primary_window": {
			      "used_percent": 42,
			      "reset_at": 1779345718,
			      "limit_window_seconds": 18000
			    }
			  }
			}`), nil
		default:
			return jsonResponse(http.StatusUnauthorized, `{"error":"nope"}`), nil
		}
	})}

	homeDir := t.TempDir()
	mustWriteAuthFile(t, homeDir, "a@gmail.com")
	mustWriteSavedAuthFile(t, homeDir, "a@gmail.com", testAuthJSON("a@gmail.com"))
	mustWriteSavedAuthFile(t, homeDir, "b@gmail.com", strings.ReplaceAll(testAuthJSON("b@gmail.com"), `"access_token": "access"`, `"access_token": "bad"`))

	accounts, err := ListSavedAuthAccountsWithUsage(homeDir, CodexUsageClient{
		Endpoint:   "https://chatgpt.com/backend-api/wham/usage",
		HTTPClient: client,
	})
	if err != nil {
		t.Fatalf("ListSavedAuthAccountsWithUsage returned error: %v", err)
	}

	if len(accounts) != 2 {
		t.Fatalf("len(accounts) = %d, want 2", len(accounts))
	}
	if accounts[0].Usage == nil || accounts[0].UsageError != "" {
		t.Fatalf("first account usage/error = %#v/%q, want usage success", accounts[0].Usage, accounts[0].UsageError)
	}
	if accounts[1].Usage != nil || accounts[1].UsageError == "" {
		t.Fatalf("second account usage/error = %#v/%q, want usage failure", accounts[1].Usage, accounts[1].UsageError)
	}
}

func TestFormatCodexUsage(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	usage := &CodexUsageResponse{
		PlanType: "plus",
		RateLimit: CodexRateLimitDetails{
			PrimaryWindow:   &CodexUsageWindow{UsedPercent: 42, ResetAt: now.Add(5 * time.Hour).Unix()},
			SecondaryWindow: &CodexUsageWindow{UsedPercent: 12.5, ResetAt: now.Add(5*24*time.Hour + 15*time.Hour).Unix()},
		},
	}

	got := FormatCodexUsageAt(usage, "", now)
	want := "session: 58% left, weekly: 87.5% left, reset in: 5d 15h"
	if got != want {
		t.Fatalf("FormatCodexUsage = %q, want %q", got, want)
	}

	if got := FormatCodexUsage(nil, "boom"); got != "usage unavailable" {
		t.Fatalf("FormatCodexUsage error = %q, want usage unavailable", got)
	}
}

func TestFormatCodexUsageWithoutResetDate(t *testing.T) {
	usage := &CodexUsageResponse{
		RateLimit: CodexRateLimitDetails{
			PrimaryWindow:   &CodexUsageWindow{UsedPercent: 30},
			SecondaryWindow: &CodexUsageWindow{UsedPercent: 18},
		},
	}

	got := FormatCodexUsageAt(usage, "", time.Unix(1_700_000_000, 0))
	want := "session: 70% left, weekly: 82% left"
	if got != want {
		t.Fatalf("FormatCodexUsage = %q, want %q", got, want)
	}
}

func testAuthFile(email string) AuthFile {
	return AuthFile{
		AuthMode: "chatgpt",
		Tokens: AuthTokens{
			IDToken:      testJWT(`{"alg":"none"}`, `{"email":"`+email+`"}`),
			AccessToken:  "access",
			RefreshToken: "refresh",
			AccountID:    "account",
		},
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func jsonResponse(statusCode int, body string) *http.Response {
	return &http.Response{
		StatusCode: statusCode,
		Header:     http.Header{"Content-Type": []string{"application/json"}},
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}
