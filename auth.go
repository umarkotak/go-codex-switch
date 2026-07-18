package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	codexDirName       = ".codex"
	switchDirName      = ".go-codex-switch"
	authFileName       = "auth.json"
	savedAuthExtension = ".auth.json"
	loginRequiredError = "please login to codex first"
)

type AuthFile struct {
	AuthMode     string     `json:"auth_mode"`
	OpenAIAPIKey *string    `json:"OPENAI_API_KEY"`
	Tokens       AuthTokens `json:"tokens"`
	LastRefresh  string     `json:"last_refresh"`
}

type AuthTokens struct {
	IDToken      string `json:"id_token"`
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	AccountID    string `json:"account_id"`
}

type IDTokenClaims struct {
	Email string `json:"email"`
}

type SaveResult struct {
	Email           string
	SourcePath      string
	DestinationPath string
}

type LoadResult struct {
	Email         string
	Loaded        bool
	AlreadyActive bool
}

type LogoutResult struct {
	Email       string
	SavedPath   string
	DeletedPath string
}

type SavedAuthAccount struct {
	Email        string
	IsActive     bool
	Usage        *CodexUsageResponse
	UsageError   string
	ResetCredits *CodexResetCreditsResponse
}

func SaveAuthFromHome() (SaveResult, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return SaveResult{}, fmt.Errorf("find home directory: %w", err)
	}

	return SaveAuth(homeDir)
}

func SaveAuth(homeDir string) (SaveResult, error) {
	sourcePath := filepath.Join(homeDir, codexDirName, authFileName)
	destinationDir := filepath.Join(homeDir, switchDirName)

	authFile, rawAuth, err := ReadAuthFile(sourcePath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return SaveResult{}, errors.New(loginRequiredError)
		}

		return SaveResult{}, err
	}

	email, err := EmailFromIDToken(authFile.Tokens.IDToken)
	if err != nil {
		return SaveResult{}, err
	}

	if err := os.MkdirAll(destinationDir, 0o700); err != nil {
		return SaveResult{}, fmt.Errorf("create %s: %w", destinationDir, err)
	}

	destinationPath := filepath.Join(destinationDir, email+savedAuthExtension)
	if err := os.WriteFile(destinationPath, rawAuth, 0o600); err != nil {
		return SaveResult{}, fmt.Errorf("write saved auth file: %w", err)
	}

	return SaveResult{
		Email:           email,
		SourcePath:      sourcePath,
		DestinationPath: destinationPath,
	}, nil
}

func LogoutFromHome() (LogoutResult, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return LogoutResult{}, fmt.Errorf("find home directory: %w", err)
	}

	return Logout(homeDir)
}

func Logout(homeDir string) (LogoutResult, error) {
	saveResult, err := SaveAuth(homeDir)
	if err != nil {
		return LogoutResult{}, err
	}

	authPath := filepath.Join(homeDir, codexDirName, authFileName)
	if err := os.Remove(authPath); err != nil {
		return LogoutResult{}, fmt.Errorf("delete codex auth file: %w", err)
	}

	return LogoutResult{
		Email:       saveResult.Email,
		SavedPath:   saveResult.DestinationPath,
		DeletedPath: authPath,
	}, nil
}

func LoadSavedAuthFromHome(index int) (LoadResult, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return LoadResult{}, fmt.Errorf("find home directory: %w", err)
	}

	return LoadSavedAuth(homeDir, index)
}

func NextSavedAuthFromHome() (LoadResult, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return LoadResult{}, fmt.Errorf("find home directory: %w", err)
	}

	return NextSavedAuth(homeDir)
}

func NextSavedAuth(homeDir string) (LoadResult, error) {
	emails, err := ListSavedAuthEmails(homeDir)
	if err != nil {
		return LoadResult{}, err
	}

	if len(emails) == 0 {
		return LoadResult{}, errors.New("no saved auth accounts")
	}

	if len(emails) == 1 {
		return LoadResult{
			Email:         emails[0],
			AlreadyActive: true,
		}, nil
	}

	currentEmail, err := CurrentAuthEmail(homeDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return LoadSavedAuth(homeDir, 1)
		}

		return LoadResult{}, err
	}

	for i, email := range emails {
		if email == currentEmail {
			nextIndex := i + 2
			if nextIndex > len(emails) {
				nextIndex = 1
			}

			return LoadSavedAuth(homeDir, nextIndex)
		}
	}

	return LoadSavedAuth(homeDir, 1)
}

func MaxingSavedAuthFromHome() (LoadResult, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return LoadResult{}, fmt.Errorf("find home directory: %w", err)
	}

	return MaxingSavedAuth(homeDir, DefaultCodexUsageClient(), time.Now())
}

func MaxingSavedAuth(homeDir string, usageClient CodexUsageClient, now time.Time) (LoadResult, error) {
	accounts, err := ListSavedAuthAccounts(homeDir)
	if err != nil {
		return LoadResult{}, err
	}
	if len(accounts) == 0 {
		return LoadResult{}, errors.New("no saved auth accounts")
	}

	for i := range accounts {
		authFile, _, err := ReadAuthFile(savedAuthPath(homeDir, accounts[i].Email))
		if err != nil {
			accounts[i].UsageError = err.Error()
			continue
		}

		usage, err := usageClient.FetchUsage(authFile)
		if err != nil {
			accounts[i].UsageError = err.Error()
			continue
		}
		accounts[i].Usage = &usage
	}

	index, err := selectMaxingAccountIndex(accounts, now)
	if err != nil {
		return LoadResult{}, err
	}
	return LoadSavedAuth(homeDir, index+1)
}

func selectMaxingAccountIndex(accounts []SavedAuthAccount, now time.Time) (int, error) {
	type candidate struct {
		index     int
		remaining float64
		resetsAt  time.Time
	}

	candidates := make([]candidate, 0, len(accounts))
	for i, account := range accounts {
		if account.UsageError != "" || account.Usage == nil || account.Usage.RateLimit.PrimaryWindow == nil {
			continue
		}
		window := account.Usage.RateLimit.PrimaryWindow
		resetsAt := time.Unix(window.ResetAt, 0)
		if window.ResetAt <= 0 || !resetsAt.After(now) {
			continue
		}
		candidates = append(candidates, candidate{
			index:     i,
			remaining: max(0, 100-window.UsedPercent),
			resetsAt:  resetsAt,
		})
	}
	if len(candidates) == 0 {
		return 0, errors.New("no saved auth accounts have usable usage data")
	}

	preferred := make([]candidate, 0, len(candidates))
	for _, candidate := range candidates {
		if candidate.remaining > 95 {
			preferred = append(preferred, candidate)
		}
	}
	if len(preferred) == 0 {
		preferred = candidates
	}

	best := preferred[0]
	for _, candidate := range preferred[1:] {
		if candidate.resetsAt.Before(best.resetsAt) {
			best = candidate
		}
	}
	return best.index, nil
}

func LoadSavedAuth(homeDir string, index int) (LoadResult, error) {
	if index < 1 {
		return LoadResult{}, fmt.Errorf("account number must be 1 or greater")
	}

	emails, err := ListSavedAuthEmails(homeDir)
	if err != nil {
		return LoadResult{}, err
	}

	if index > len(emails) {
		return LoadResult{}, fmt.Errorf("account number %d does not exist", index)
	}

	targetEmail := emails[index-1]
	currentEmail, err := CurrentAuthEmail(homeDir)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return LoadResult{}, err
	}

	if currentEmail == targetEmail {
		return LoadResult{
			Email:         targetEmail,
			AlreadyActive: true,
		}, nil
	}

	if currentEmail != "" {
		if _, err := SaveAuth(homeDir); err != nil {
			return LoadResult{}, err
		}
	}

	sourcePath := savedAuthPath(homeDir, targetEmail)
	rawAuth, err := os.ReadFile(sourcePath)
	if err != nil {
		return LoadResult{}, fmt.Errorf("read saved auth file: %w", err)
	}

	codexDir := filepath.Join(homeDir, codexDirName)
	if err := os.MkdirAll(codexDir, 0o700); err != nil {
		return LoadResult{}, fmt.Errorf("create %s: %w", codexDir, err)
	}

	destinationPath := filepath.Join(codexDir, authFileName)
	if err := os.WriteFile(destinationPath, rawAuth, 0o600); err != nil {
		return LoadResult{}, fmt.Errorf("write codex auth file: %w", err)
	}

	return LoadResult{
		Email:  targetEmail,
		Loaded: true,
	}, nil
}

func ListSavedAuthAccountsFromHome() ([]SavedAuthAccount, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("find home directory: %w", err)
	}

	return ListSavedAuthAccounts(homeDir)
}

func ListSavedAuthAccountsWithUsageFromHome() ([]SavedAuthAccount, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("find home directory: %w", err)
	}

	return ListSavedAuthAccountsWithUsage(homeDir, DefaultCodexUsageClient())
}

func ListSavedAuthAccountsWithUsage(homeDir string, usageClient CodexUsageClient) ([]SavedAuthAccount, error) {
	accounts, err := ListSavedAuthAccounts(homeDir)
	if err != nil {
		return nil, err
	}

	for i := range accounts {
		authFile, _, err := ReadAuthFile(savedAuthPath(homeDir, accounts[i].Email))
		if err != nil {
			accounts[i].UsageError = err.Error()
			continue
		}

		usage, err := usageClient.FetchUsage(authFile)
		if err != nil {
			accounts[i].UsageError = err.Error()
			continue
		}

		accounts[i].Usage = &usage

		resetCredits, err := usageClient.FetchResetCredits(authFile)
		if err != nil {
			continue
		}
		accounts[i].ResetCredits = &resetCredits
	}

	return accounts, nil
}

func ListSavedAuthAccounts(homeDir string) ([]SavedAuthAccount, error) {
	activeEmail, err := CurrentAuthEmail(homeDir)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
	}

	emails, err := ListSavedAuthEmails(homeDir)
	if err != nil {
		return nil, err
	}

	accounts := make([]SavedAuthAccount, 0, len(emails))
	for _, email := range emails {
		accounts = append(accounts, SavedAuthAccount{
			Email:    email,
			IsActive: email == activeEmail,
		})
	}

	return accounts, nil
}

func CurrentAuthEmail(homeDir string) (string, error) {
	authPath := filepath.Join(homeDir, codexDirName, authFileName)
	authFile, _, err := ReadAuthFile(authPath)
	if err != nil {
		return "", err
	}

	return EmailFromIDToken(authFile.Tokens.IDToken)
}

func ListSavedAuthEmailsFromHome() ([]string, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("find home directory: %w", err)
	}

	return ListSavedAuthEmails(homeDir)
}

func ListSavedAuthEmails(homeDir string) ([]string, error) {
	destinationDir := filepath.Join(homeDir, switchDirName)

	entries, err := os.ReadDir(destinationDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return []string{}, nil
		}

		return nil, fmt.Errorf("read %s: %w", destinationDir, err)
	}

	emails := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}

		email, ok := emailFromSavedAuthFileName(entry.Name())
		if !ok {
			continue
		}

		emails = append(emails, email)
	}

	sort.Strings(emails)
	return emails, nil
}

func emailFromSavedAuthFileName(fileName string) (string, bool) {
	email, ok := strings.CutSuffix(fileName, savedAuthExtension)
	if !ok || strings.TrimSpace(email) == "" {
		return "", false
	}

	return email, true
}

func savedAuthPath(homeDir, email string) string {
	return filepath.Join(homeDir, switchDirName, email+savedAuthExtension)
}

func ReadAuthFile(path string) (AuthFile, []byte, error) {
	rawAuth, err := os.ReadFile(path)
	if err != nil {
		return AuthFile{}, nil, fmt.Errorf("read %s: %w", path, err)
	}

	var authFile AuthFile
	if err := json.Unmarshal(rawAuth, &authFile); err != nil {
		return AuthFile{}, nil, fmt.Errorf("parse %s: %w", path, err)
	}

	if strings.TrimSpace(authFile.Tokens.IDToken) == "" {
		return AuthFile{}, nil, errors.New("auth file does not contain tokens.id_token")
	}

	return authFile, rawAuth, nil
}

func EmailFromIDToken(idToken string) (string, error) {
	parts := strings.Split(idToken, ".")
	if len(parts) < 2 {
		return "", errors.New("id_token is not a JWT")
	}

	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", fmt.Errorf("decode id_token payload: %w", err)
	}

	var claims IDTokenClaims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return "", fmt.Errorf("parse id_token payload: %w", err)
	}

	email := strings.TrimSpace(claims.Email)
	if email == "" {
		return "", errors.New("id_token payload does not contain email")
	}

	return email, nil
}
