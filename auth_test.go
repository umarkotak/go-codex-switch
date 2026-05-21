package main

import (
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestEmailFromIDToken(t *testing.T) {
	token := testJWT(`{"alg":"none"}`, `{"email":"codingmase@gmail.com"}`)

	email, err := EmailFromIDToken(token)
	if err != nil {
		t.Fatalf("EmailFromIDToken returned error: %v", err)
	}

	if email != "codingmase@gmail.com" {
		t.Fatalf("email = %q, want %q", email, "codingmase@gmail.com")
	}
}

func TestSaveAuthCreatesSwitchDirAndCopiesAuthByEmail(t *testing.T) {
	homeDir := t.TempDir()
	codexDir := filepath.Join(homeDir, codexDirName)
	if err := os.MkdirAll(codexDir, 0o700); err != nil {
		t.Fatalf("create codex dir: %v", err)
	}

	authJSON := `{
  "auth_mode": "chatgpt",
  "OPENAI_API_KEY": null,
  "tokens": {
    "id_token": "` + testJWT(`{"alg":"none"}`, `{"email":"codingmase@gmail.com"}`) + `",
    "access_token": "access",
    "refresh_token": "refresh",
    "account_id": "account"
  },
  "last_refresh": "2026-05-21T05:41:59.325633Z"
}`

	sourcePath := filepath.Join(codexDir, authFileName)
	if err := os.WriteFile(sourcePath, []byte(authJSON), 0o600); err != nil {
		t.Fatalf("write auth file: %v", err)
	}

	result, err := SaveAuth(homeDir)
	if err != nil {
		t.Fatalf("SaveAuth returned error: %v", err)
	}

	wantPath := filepath.Join(homeDir, switchDirName, "codingmase@gmail.com.auth.json")
	if result.DestinationPath != wantPath {
		t.Fatalf("destination path = %q, want %q", result.DestinationPath, wantPath)
	}

	copied, err := os.ReadFile(wantPath)
	if err != nil {
		t.Fatalf("read copied auth: %v", err)
	}

	if string(copied) != authJSON {
		t.Fatal("copied auth content does not match source")
	}
}

func TestSaveAuthReturnsLoginMessageWhenAuthFileDoesNotExist(t *testing.T) {
	_, err := SaveAuth(t.TempDir())
	if err == nil {
		t.Fatal("SaveAuth returned nil error")
	}

	if err.Error() != loginRequiredError {
		t.Fatalf("error = %q, want %q", err.Error(), loginRequiredError)
	}

	if errors.Is(err, os.ErrNotExist) {
		t.Fatal("error should be the user-facing login message, not the raw missing file error")
	}
}

func TestListSavedAuthEmails(t *testing.T) {
	homeDir := t.TempDir()
	switchDir := filepath.Join(homeDir, switchDirName)
	if err := os.MkdirAll(switchDir, 0o700); err != nil {
		t.Fatalf("create switch dir: %v", err)
	}

	files := []string{
		"jhone@gmail.com.auth.json",
		"ignore.txt",
		"codingmase@gmail.com.auth.json",
		".auth.json",
	}
	for _, file := range files {
		if err := os.WriteFile(filepath.Join(switchDir, file), []byte("{}"), 0o600); err != nil {
			t.Fatalf("write %s: %v", file, err)
		}
	}

	emails, err := ListSavedAuthEmails(homeDir)
	if err != nil {
		t.Fatalf("ListSavedAuthEmails returned error: %v", err)
	}

	want := []string{"codingmase@gmail.com", "jhone@gmail.com"}
	if !reflect.DeepEqual(emails, want) {
		t.Fatalf("emails = %#v, want %#v", emails, want)
	}
}

func TestListSavedAuthAccountsMarksActiveAccount(t *testing.T) {
	homeDir := t.TempDir()
	mustWriteAuthFile(t, homeDir, "jhone@gmail.com")

	switchDir := filepath.Join(homeDir, switchDirName)
	if err := os.MkdirAll(switchDir, 0o700); err != nil {
		t.Fatalf("create switch dir: %v", err)
	}

	files := []string{
		"jhone@gmail.com.auth.json",
		"codingmase@gmail.com.auth.json",
	}
	for _, file := range files {
		if err := os.WriteFile(filepath.Join(switchDir, file), []byte("{}"), 0o600); err != nil {
			t.Fatalf("write %s: %v", file, err)
		}
	}

	accounts, err := ListSavedAuthAccounts(homeDir)
	if err != nil {
		t.Fatalf("ListSavedAuthAccounts returned error: %v", err)
	}

	want := []SavedAuthAccount{
		{Email: "codingmase@gmail.com", IsActive: false},
		{Email: "jhone@gmail.com", IsActive: true},
	}
	if !reflect.DeepEqual(accounts, want) {
		t.Fatalf("accounts = %#v, want %#v", accounts, want)
	}
}

func TestListSavedAuthAccountsDoesNotMarkActiveWhenAuthFileDoesNotExist(t *testing.T) {
	homeDir := t.TempDir()
	switchDir := filepath.Join(homeDir, switchDirName)
	if err := os.MkdirAll(switchDir, 0o700); err != nil {
		t.Fatalf("create switch dir: %v", err)
	}

	files := []string{
		"jhone@gmail.com.auth.json",
		"codingmase@gmail.com.auth.json",
	}
	for _, file := range files {
		if err := os.WriteFile(filepath.Join(switchDir, file), []byte("{}"), 0o600); err != nil {
			t.Fatalf("write %s: %v", file, err)
		}
	}

	accounts, err := ListSavedAuthAccounts(homeDir)
	if err != nil {
		t.Fatalf("ListSavedAuthAccounts returned error: %v", err)
	}

	want := []SavedAuthAccount{
		{Email: "codingmase@gmail.com", IsActive: false},
		{Email: "jhone@gmail.com", IsActive: false},
	}
	if !reflect.DeepEqual(accounts, want) {
		t.Fatalf("accounts = %#v, want %#v", accounts, want)
	}
}

func TestListSavedAuthEmailsReturnsEmptyWhenSwitchDirDoesNotExist(t *testing.T) {
	emails, err := ListSavedAuthEmails(t.TempDir())
	if err != nil {
		t.Fatalf("ListSavedAuthEmails returned error: %v", err)
	}

	if len(emails) != 0 {
		t.Fatalf("emails = %#v, want empty list", emails)
	}
}

func TestLoadSavedAuthCopiesSelectedAccountAndSavesCurrentSession(t *testing.T) {
	homeDir := t.TempDir()
	currentAuth := mustWriteAuthFile(t, homeDir, "current@gmail.com")
	targetAuth := testAuthJSON("target@gmail.com")
	otherAuth := testAuthJSON("other@gmail.com")

	mustWriteSavedAuthFile(t, homeDir, "target@gmail.com", targetAuth)
	mustWriteSavedAuthFile(t, homeDir, "other@gmail.com", otherAuth)

	result, err := LoadSavedAuth(homeDir, 2)
	if err != nil {
		t.Fatalf("LoadSavedAuth returned error: %v", err)
	}

	if !result.Loaded || result.Email != "target@gmail.com" {
		t.Fatalf("result = %#v, want loaded target@gmail.com", result)
	}

	activeAuth, err := os.ReadFile(filepath.Join(homeDir, codexDirName, authFileName))
	if err != nil {
		t.Fatalf("read active auth: %v", err)
	}
	if string(activeAuth) != targetAuth {
		t.Fatal("active auth was not replaced with selected saved auth")
	}

	savedCurrent, err := os.ReadFile(savedAuthPath(homeDir, "current@gmail.com"))
	if err != nil {
		t.Fatalf("read saved current auth: %v", err)
	}
	if string(savedCurrent) != currentAuth {
		t.Fatal("current auth was not saved before loading target")
	}
}

func TestLoadSavedAuthDoesNothingWhenSelectedAccountIsAlreadyActive(t *testing.T) {
	homeDir := t.TempDir()
	currentAuth := mustWriteAuthFile(t, homeDir, "current@gmail.com")
	mustWriteSavedAuthFile(t, homeDir, "current@gmail.com", testAuthJSON("current@gmail.com"))

	result, err := LoadSavedAuth(homeDir, 1)
	if err != nil {
		t.Fatalf("LoadSavedAuth returned error: %v", err)
	}

	if !result.AlreadyActive || result.Loaded {
		t.Fatalf("result = %#v, want already active without load", result)
	}

	activeAuth, err := os.ReadFile(filepath.Join(homeDir, codexDirName, authFileName))
	if err != nil {
		t.Fatalf("read active auth: %v", err)
	}
	if string(activeAuth) != currentAuth {
		t.Fatal("active auth should not change when selected account is already active")
	}
}

func TestLoadSavedAuthWorksWhenCurrentAuthFileDoesNotExist(t *testing.T) {
	homeDir := t.TempDir()
	targetAuth := testAuthJSON("target@gmail.com")
	mustWriteSavedAuthFile(t, homeDir, "target@gmail.com", targetAuth)

	result, err := LoadSavedAuth(homeDir, 1)
	if err != nil {
		t.Fatalf("LoadSavedAuth returned error: %v", err)
	}

	if !result.Loaded || result.Email != "target@gmail.com" {
		t.Fatalf("result = %#v, want loaded target@gmail.com", result)
	}

	activeAuth, err := os.ReadFile(filepath.Join(homeDir, codexDirName, authFileName))
	if err != nil {
		t.Fatalf("read active auth: %v", err)
	}
	if string(activeAuth) != targetAuth {
		t.Fatal("active auth was not created from selected saved auth")
	}
}

func TestLoadSavedAuthReturnsErrorForMissingAccountNumber(t *testing.T) {
	homeDir := t.TempDir()
	mustWriteSavedAuthFile(t, homeDir, "target@gmail.com", testAuthJSON("target@gmail.com"))

	_, err := LoadSavedAuth(homeDir, 2)
	if err == nil {
		t.Fatal("LoadSavedAuth returned nil error")
	}
}

func mustWriteAuthFile(t *testing.T, homeDir, email string) string {
	t.Helper()

	codexDir := filepath.Join(homeDir, codexDirName)
	if err := os.MkdirAll(codexDir, 0o700); err != nil {
		t.Fatalf("create codex dir: %v", err)
	}

	authJSON := testAuthJSON(email)
	if err := os.WriteFile(filepath.Join(codexDir, authFileName), []byte(authJSON), 0o600); err != nil {
		t.Fatalf("write auth file: %v", err)
	}

	return authJSON
}

func mustWriteSavedAuthFile(t *testing.T, homeDir, email, authJSON string) {
	t.Helper()

	switchDir := filepath.Join(homeDir, switchDirName)
	if err := os.MkdirAll(switchDir, 0o700); err != nil {
		t.Fatalf("create switch dir: %v", err)
	}

	if err := os.WriteFile(savedAuthPath(homeDir, email), []byte(authJSON), 0o600); err != nil {
		t.Fatalf("write saved auth file: %v", err)
	}
}

func testAuthJSON(email string) string {
	return `{
  "auth_mode": "chatgpt",
  "OPENAI_API_KEY": null,
  "tokens": {
    "id_token": "` + testJWT(`{"alg":"none"}`, `{"email":"`+email+`"}`) + `",
    "access_token": "access",
    "refresh_token": "refresh",
    "account_id": "account"
  },
  "last_refresh": "2026-05-21T05:41:59.325633Z"
}`
}

func testJWT(header, payload string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(header)) + "." +
		base64.RawURLEncoding.EncodeToString([]byte(payload)) + ".signature"
}
