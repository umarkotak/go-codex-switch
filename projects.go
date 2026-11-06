package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"syscall"
	"time"
)

const rendererStateKey = "electron-account-renderer-state-v1"

type stateFields map[string]json.RawMessage

type rendererAccount struct {
	Globals stateFields `json:"globals"`
	Atoms   stateFields `json:"atoms"`
}

type localProject struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	RootPaths []string `json:"rootPaths"`
	CreatedAt int64    `json:"createdAt"`
	UpdatedAt int64    `json:"updatedAt"`
}

// Codex derives the renderer owner from the user and workspace, not the email.
func projectOwner(auth AuthFile) (string, error) {
	parts := strings.Split(auth.Tokens.IDToken, ".")
	if len(parts) < 2 {
		return "", errors.New("invalid Codex ID token")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", errors.New("invalid Codex ID token")
	}
	var claims struct {
		Auth struct {
			UserID string `json:"user_id"`
		} `json:"https://api.openai.com/auth"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil || claims.Auth.UserID == "" || auth.Tokens.AccountID == "" {
		return "", errors.New("Codex login is missing a user or workspace ID")
	}
	identity, err := json.Marshal([2]string{claims.Auth.UserID, auth.Tokens.AccountID})
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", sha256.Sum256(identity)), nil
}

func projectRootsKey(roots []string) string {
	if len(roots) == 0 {
		return ""
	}
	canonical := make([]string, len(roots))
	for i, root := range roots {
		if !filepath.IsAbs(root) {
			return ""
		}
		canonical[i] = filepath.Clean(root)
		if resolved, err := filepath.EvalSymlinks(root); err == nil {
			canonical[i] = resolved
		}
	}
	sort.Strings(canonical)
	return strings.Join(canonical, "\x00")
}

// Respect the unified order first and use the legacy order for missing entries.
func orderedProjectIDs(source rendererAccount, entries map[string]json.RawMessage) ([]string, error) {
	var unified, legacy []string
	if err := decodeState(source.Atoms, "unified-sidebar-project-order-v1", &unified); err != nil {
		return nil, err
	}
	if err := decodeState(source.Globals, "project-order", &legacy); err != nil {
		return nil, err
	}
	var ids []string
	seen := make(map[string]bool)
	add := func(id string) {
		if entries[id] != nil && !seen[id] {
			ids = append(ids, id)
			seen[id] = true
		}
	}
	for _, key := range unified {
		if strings.HasPrefix(key, "codex:project:") {
			add(strings.TrimPrefix(key, "codex:project:"))
		}
	}
	for _, id := range legacy {
		add(id)
	}
	var rest []string
	for id := range entries {
		if !seen[id] {
			rest = append(rest, id)
		}
	}
	sort.Strings(rest)
	for _, id := range rest {
		add(id)
	}
	return ids, nil
}

func decodeState(fields stateFields, key string, value any) error {
	if raw := fields[key]; len(raw) != 0 {
		if err := json.Unmarshal(raw, value); err != nil {
			return fmt.Errorf("invalid sidebar state %s: %w", key, err)
		}
	}
	return nil
}

const projectBackupsDirectory = "project-backups"

var projectGlobalKeys = []string{"local-projects", "project-order", "pinned-project-ids", "project-appearances"}
var projectAtomKeys = []string{"unified-sidebar-project-order-v1", "flat-project-sidebar-preferences-v1", "codex-sidebar-sort-mode-v1", "sidebar-project-list-expanded-v1"}

const expandedProjectPrefix = "sidebar-project-expanded-v1-codex:"

type projectBackup struct {
	Owner string `json:"owner"`
	rendererAccount
}

func syncLocalProjects(home string) (int, error) {
	return changeLocalProjects(home, "sync", "", "")
}

// All operations run after desktop exit. Each write has its own immutable backup file.
func changeLocalProjects(home, operation, email, backupPath string) (int, error) {
	dir := filepath.Join(home, codexDirName)
	path := filepath.Join(dir, ".codex-global-state.json")
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) && operation == "sync" {
		return 0, nil
	}
	lock, err := os.OpenFile(filepath.Join(dir, ".go-codex-switch-projects.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return 0, err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return 0, fmt.Errorf("lock project state: %w", err)
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) && operation == "sync" {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	var state stateFields
	if err := json.Unmarshal(data, &state); err != nil || state == nil {
		return 0, errors.New("invalid Codex desktop state")
	}
	var scope struct {
		Owner    *string                    `json:"owner"`
		Inactive map[string]rendererAccount `json:"inactive"`
	}
	if state[rendererStateKey] == nil {
		if operation == "sync" {
			return 0, nil
		}
		return 0, errors.New("Codex has no account-scoped project state yet")
	}
	if err := decodeState(state, rendererStateKey, &scope); err != nil {
		return 0, err
	}
	authPath := filepath.Join(dir, authFileName)
	if operation != "sync" {
		if email == "" || filepath.Base(email) != email {
			return 0, errors.New("invalid saved account")
		}
		authPath = savedAuthPath(home, email)
		// Prefer the live auth for the active card, whose workspace may have changed.
		if current, err := CurrentAuthEmail(home); err == nil && current == email {
			authPath = filepath.Join(dir, authFileName)
		}
	}
	auth, _, err := ReadAuthFile(authPath)
	if err != nil {
		return 0, err
	}
	owner, err := projectOwner(auth)
	if err != nil {
		return 0, err
	}
	var activeAtoms stateFields
	if err := decodeState(state, "electron-persisted-atom-state", &activeAtoms); err != nil {
		return 0, err
	}
	if activeAtoms == nil {
		activeAtoms = make(stateFields)
	}
	active := rendererAccount{Globals: state, Atoms: activeAtoms}
	target := active
	isActive := scope.Owner != nil && *scope.Owner == owner
	if !isActive {
		target = scope.Inactive[owner]
		if target.Globals == nil {
			target.Globals = make(stateFields)
		}
		if target.Atoms == nil {
			target.Atoms = make(stateFields)
		}
	}
	before := snapshotProjects(target)
	var count int
	switch operation {
	case "sync":
		if scope.Owner == nil || isActive {
			return 0, nil
		}
		count, err = replaceProjects(active, target)
	case "delete":
		cleared := snapshotProjects(target)
		clear(cleared.Globals)
		for key := range cleared.Atoms {
			if key == projectAtomKeys[0] || strings.HasPrefix(key, expandedProjectPrefix) {
				delete(cleared.Atoms, key)
			}
		}
		err = restoreProjectState(target, cleared)
	case "restore":
		var backup projectBackup
		root := filepath.Join(home, switchDirName, projectBackupsDirectory)
		if filepath.Dir(filepath.Clean(backupPath)) != root {
			return 0, errors.New("select a project backup from the project-backups folder")
		}
		info, readErr := os.Lstat(backupPath)
		if readErr != nil {
			return 0, readErr
		}
		if !info.Mode().IsRegular() {
			return 0, errors.New("invalid project backup file")
		}
		raw, readErr := os.ReadFile(backupPath)
		if readErr != nil {
			return 0, readErr
		}
		if err := json.Unmarshal(raw, &backup); err != nil {
			return 0, err
		}
		if backup.Owner != owner || backup.Globals == nil || backup.Atoms == nil {
			return 0, errors.New("this backup does not belong to the selected account")
		}
		err = restoreProjectState(target, backup.rendererAccount)
	default:
		return 0, errors.New("unknown project operation")
	}
	if err != nil {
		return 0, err
	}
	after := snapshotProjects(target)
	if reflect.DeepEqual(before, after) {
		return count, nil
	}
	if isActive {
		state["electron-persisted-atom-state"], err = json.Marshal(target.Atoms)
	} else {
		if scope.Inactive == nil {
			scope.Inactive = make(map[string]rendererAccount)
		}
		scope.Inactive[owner] = target
		state[rendererStateKey], err = json.Marshal(scope)
	}
	if err != nil {
		return 0, err
	}
	updated, err := json.Marshal(state)
	if err != nil {
		return 0, err
	}

	backup, err := json.Marshal(projectBackup{owner, before})
	if err != nil {
		return 0, err
	}
	backups := filepath.Join(home, switchDirName, projectBackupsDirectory)
	if err := os.MkdirAll(backups, 0700); err != nil {
		return 0, err
	}
	file, err := os.CreateTemp(backups, emailForBackup(auth)+"-"+time.Now().Format("20060102-150405")+"-*.json")
	if err != nil {
		return 0, err
	}
	if err := writeAndClose(file, backup); err != nil {
		os.Remove(file.Name())
		return 0, err
	}
	tmp, err := os.CreateTemp(dir, ".project-sync-*")
	if err != nil {
		return 0, err
	}
	defer os.Remove(tmp.Name())
	if err := writeAndClose(tmp, updated); err != nil {
		return 0, err
	}
	current, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	if !bytes.Equal(current, data) {
		return 0, errors.New("Codex state changed during project operation; retry")
	}
	return count, os.Rename(tmp.Name(), path)
}

func emailForBackup(auth AuthFile) string {
	email, _ := EmailFromIDToken(auth.Tokens.IDToken)
	if email == "" || filepath.Base(email) != email {
		return "account"
	}
	return email
}

func writeAndClose(file *os.File, data []byte) error {
	_, err := file.Write(data)
	if err == nil {
		err = file.Sync()
	}
	return errors.Join(err, file.Close())
}

func snapshotProjects(account rendererAccount) rendererAccount {
	snapshot := rendererAccount{Globals: make(stateFields), Atoms: make(stateFields)}
	for _, key := range projectGlobalKeys {
		if value := account.Globals[key]; value != nil {
			snapshot.Globals[key] = value
		}
	}
	for _, key := range projectAtomKeys {
		if value := account.Atoms[key]; value != nil {
			snapshot.Atoms[key] = value
		}
	}
	for key, value := range account.Atoms {
		if strings.HasPrefix(key, expandedProjectPrefix) {
			snapshot.Atoms[key] = value
		}
	}
	return snapshot
}

func restoreProjectState(target, snapshot rendererAccount) error {
	// Keep the destination's ChatGPT/remote entries in the unified sidebar.
	var oldOrder, savedOrder []string
	if err := decodeState(target.Atoms, projectAtomKeys[0], &oldOrder); err != nil {
		return err
	}
	if err := decodeState(snapshot.Atoms, projectAtomKeys[0], &savedOrder); err != nil {
		return err
	}
	var oldEntries, savedEntries stateFields
	if err := decodeState(target.Globals, "local-projects", &oldEntries); err != nil {
		return err
	}
	if err := decodeState(snapshot.Globals, "local-projects", &savedEntries); err != nil {
		return err
	}
	const prefix = "codex:project:"
	var locals []string
	for _, key := range savedOrder {
		if strings.HasPrefix(key, prefix) && savedEntries[strings.TrimPrefix(key, prefix)] != nil {
			locals = append(locals, key)
		}
	}
	order := make([]string, 0, len(oldOrder)+len(locals))
	for _, key := range oldOrder {
		if strings.HasPrefix(key, prefix) && oldEntries[strings.TrimPrefix(key, prefix)] != nil {
			if len(locals) > 0 {
				order = append(order, locals[0])
				locals = locals[1:]
			}
		} else {
			order = append(order, key)
		}
	}
	order = append(order, locals...)
	for _, key := range projectGlobalKeys {
		delete(target.Globals, key)
		if value := snapshot.Globals[key]; value != nil {
			target.Globals[key] = value
		}
	}
	for _, key := range projectAtomKeys[1:] {
		delete(target.Atoms, key)
		if value := snapshot.Atoms[key]; value != nil {
			target.Atoms[key] = value
		}
	}
	for key := range target.Atoms {
		if strings.HasPrefix(key, expandedProjectPrefix) {
			delete(target.Atoms, key)
		}
	}
	for key, value := range snapshot.Atoms {
		if strings.HasPrefix(key, expandedProjectPrefix) {
			target.Atoms[key] = value
		}
	}
	target.Atoms[projectAtomKeys[0]], _ = json.Marshal(order)
	return nil
}

func replaceProjects(source, target rendererAccount) (int, error) {
	var sourceEntries, targetEntries stateFields
	if err := decodeState(source.Globals, "local-projects", &sourceEntries); err != nil {
		return 0, err
	}
	if err := decodeState(target.Globals, "local-projects", &targetEntries); err != nil {
		return 0, err
	}
	byRoots := make(map[string]string)
	for id, raw := range targetEntries {
		var project localProject
		if err := json.Unmarshal(raw, &project); err != nil {
			return 0, err
		}
		byRoots[projectRootsKey(project.RootPaths)] = id
	}
	ids, err := orderedProjectIDs(source, sourceEntries)
	if err != nil {
		return 0, err
	}
	mapping := make(map[string]string)
	entries := make(stateFields)
	order := make([]string, 0, len(ids))
	unified := make([]string, 0, len(ids))
	next := snapshotProjects(source)
	for key := range next.Atoms {
		if strings.HasPrefix(key, expandedProjectPrefix) {
			delete(next.Atoms, key)
		}
	}
	for _, oldID := range ids {
		var project localProject
		if err := json.Unmarshal(sourceEntries[oldID], &project); err != nil {
			return 0, err
		}
		roots := projectRootsKey(project.RootPaths)
		if roots == "" || project.Name == "" {
			return 0, errors.New("source contains an invalid local project")
		}
		id := byRoots[roots]
		if entries[id] != nil {
			id = ""
		}
		var fields stateFields
		if id != "" {
			if err := json.Unmarshal(targetEntries[id], &fields); err != nil {
				return 0, err
			}
		} else {
			var b [16]byte
			if _, err := rand.Read(b[:]); err != nil {
				return 0, err
			}
			b[6] = b[6]&15 | 64
			b[8] = b[8]&63 | 128
			id = fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
			fields = make(stateFields)
		}
		project.ID = id
		raw, _ := json.Marshal(project)
		if err := json.Unmarshal(raw, &fields); err != nil {
			return 0, err
		}
		entries[id], err = json.Marshal(fields)
		if err != nil {
			return 0, err
		}
		mapping[oldID] = id
		order = append(order, id)
		unified = append(unified, "codex:project:"+id)
		if value := source.Atoms[expandedProjectPrefix+oldID]; value != nil {
			next.Atoms[expandedProjectPrefix+id] = value
		}
	}
	var pins []string
	if err := decodeState(source.Globals, "pinned-project-ids", &pins); err != nil {
		return 0, err
	}
	newPins := make([]string, 0, len(pins))
	for _, id := range pins {
		if mapped := mapping[id]; mapped != "" {
			newPins = append(newPins, mapped)
		}
	}
	var appearances stateFields
	if err := decodeState(source.Globals, "project-appearances", &appearances); err != nil {
		return 0, err
	}
	newAppearances := make(stateFields)
	for id, value := range appearances {
		if mapped := mapping[id]; mapped != "" {
			newAppearances[mapped] = value
		}
	}
	next.Globals["local-projects"], _ = json.Marshal(entries)
	next.Globals["project-order"], _ = json.Marshal(order)
	next.Globals["pinned-project-ids"], _ = json.Marshal(newPins)
	next.Globals["project-appearances"], _ = json.Marshal(newAppearances)
	next.Atoms[projectAtomKeys[0]], _ = json.Marshal(unified)
	return len(entries), restoreProjectState(target, next)
}
