package main

import "testing"

func TestParseLsArgs(t *testing.T) {
	tests := []struct {
		name      string
		args      []string
		wantUsage bool
		wantErr   bool
	}{
		{
			name: "no args",
		},
		{
			name:      "usage",
			args:      []string{"--usage"},
			wantUsage: true,
		},
		{
			name:    "unknown arg",
			args:    []string{"--wat"},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			showUsage, err := parseLsArgs(tt.args)
			if tt.wantErr {
				if err == nil {
					t.Fatal("parseLsArgs returned nil error")
				}
				return
			}

			if err != nil {
				t.Fatalf("parseLsArgs returned error: %v", err)
			}
			if showUsage != tt.wantUsage {
				t.Fatalf("showUsage = %t, want %t", showUsage, tt.wantUsage)
			}
		})
	}
}

func TestFormatSavedAuthAccountRow(t *testing.T) {
	accounts := []SavedAuthAccount{
		{Email: "codingmase@gmail.com", IsActive: true},
		{Email: "jhone.doe@gmail.com"},
	}
	width := maxSavedAuthEmailWidth(accounts)

	got := formatSavedAuthAccountRow(1, accounts[0], width, false)
	want := "[*] 1. codingmase@gmail.com"
	if got != want {
		t.Fatalf("row = %q, want %q", got, want)
	}

	got = formatSavedAuthAccountRow(2, accounts[1], width, false)
	want = "[_] 2. jhone.doe@gmail.com"
	if got != want {
		t.Fatalf("row = %q, want %q", got, want)
	}
}

func TestFormatSavedAuthAccountRowWithUsageAlignsSeparator(t *testing.T) {
	usage := &CodexUsageResponse{
		RateLimit: CodexRateLimitDetails{
			PrimaryWindow: &CodexUsageWindow{UsedPercent: 30},
		},
	}
	accounts := []SavedAuthAccount{
		{Email: "a@gmail.com", IsActive: true, Usage: usage},
		{Email: "longer.name@gmail.com", Usage: usage},
	}
	width := maxSavedAuthEmailWidth(accounts)

	got := formatSavedAuthAccountRow(1, accounts[0], width, true)
	want := "[*] 1. a@gmail.com           | session: 70% left"
	if got != want {
		t.Fatalf("row = %q, want %q", got, want)
	}

	got = formatSavedAuthAccountRow(2, accounts[1], width, true)
	want = "[_] 2. longer.name@gmail.com | session: 70% left"
	if got != want {
		t.Fatalf("row = %q, want %q", got, want)
	}
}

func TestParseLoadArgs(t *testing.T) {
	tests := []struct {
		name          string
		args          []string
		wantIndex     int
		wantNoRestart bool
		wantErr       bool
	}{
		{
			name:      "index only",
			args:      []string{"1"},
			wantIndex: 1,
		},
		{
			name:          "no restart after index",
			args:          []string{"1", "--no-restart"},
			wantIndex:     1,
			wantNoRestart: true,
		},
		{
			name:          "no restart before index",
			args:          []string{"--no-restart", "1"},
			wantIndex:     1,
			wantNoRestart: true,
		},
		{
			name:    "missing index",
			args:    []string{"--no-restart"},
			wantErr: true,
		},
		{
			name:    "duplicate index",
			args:    []string{"1", "2"},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			index, noRestart, err := parseLoadArgs(tt.args)
			if tt.wantErr {
				if err == nil {
					t.Fatal("parseLoadArgs returned nil error")
				}
				return
			}

			if err != nil {
				t.Fatalf("parseLoadArgs returned error: %v", err)
			}
			if index != tt.wantIndex || noRestart != tt.wantNoRestart {
				t.Fatalf("parseLoadArgs = (%d, %t), want (%d, %t)", index, noRestart, tt.wantIndex, tt.wantNoRestart)
			}
		})
	}
}

func TestParseNextArgs(t *testing.T) {
	tests := []struct {
		name          string
		args          []string
		wantNoRestart bool
		wantErr       bool
	}{
		{
			name: "no args",
		},
		{
			name:          "no restart",
			args:          []string{"--no-restart"},
			wantNoRestart: true,
		},
		{
			name:    "unknown arg",
			args:    []string{"1"},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			noRestart, err := parseNextArgs(tt.args)
			if tt.wantErr {
				if err == nil {
					t.Fatal("parseNextArgs returned nil error")
				}
				return
			}

			if err != nil {
				t.Fatalf("parseNextArgs returned error: %v", err)
			}
			if noRestart != tt.wantNoRestart {
				t.Fatalf("noRestart = %t, want %t", noRestart, tt.wantNoRestart)
			}
		})
	}
}
