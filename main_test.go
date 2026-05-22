package main

import "testing"

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
