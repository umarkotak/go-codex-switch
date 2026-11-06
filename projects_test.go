package main

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestProjectSwitchDeleteAndRestore(t *testing.T) {
	home := t.TempDir()
	for _, name := range []string{codexDirName, switchDirName} {
		if err := os.Mkdir(filepath.Join(home, name), 0700); err != nil {
			t.Fatal(err)
		}
	}
	write := func(path string, data []byte) {
		t.Helper()
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	token := "header." + base64.RawURLEncoding.EncodeToString([]byte(`{"email":"target@example.com","https://api.openai.com/auth":{"user_id":"u"}}`)) + ".signature"
	auth := AuthFile{Tokens: AuthTokens{IDToken: token, AccountID: "workspace"}}
	owner, err := projectOwner(auth)
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(auth)
	write(filepath.Join(home, codexDirName, authFileName), raw)
	write(savedAuthPath(home, "target@example.com"), raw)
	path := filepath.Join(home, codexDirName, ".codex-global-state.json")
	write(path, []byte(`{
		"local-projects":{"source":{"id":"source","name":"Shared","rootPaths":["/shared"],"chatGptBacking":{"private":true}}},
		"pinned-project-ids":["source"],
		"project-appearances":{"source":{"color":"red"}},
		"electron-persisted-atom-state":{"sidebar-project-expanded-v1-codex:source":false},
		"electron-account-renderer-state-v1":{"owner":"source-owner","inactive":{
			"`+owner+`":{"globals":{
				"local-projects":{"existing":{"id":"existing","name":"Old","rootPaths":["/shared"]},"removed":{"id":"removed","name":"Removed","rootPaths":["/removed"]}},
				"project-order":["removed","existing"],"thread-project-assignments":{"keep":"removed"}
			},"atoms":{"unified-sidebar-project-order-v1":["chatgpt:project:private","codex:project:removed"]}}
		}}
	}`))
	read := func() rendererAccount {
		t.Helper()
		var state stateFields
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(raw, &state); err != nil {
			t.Fatal(err)
		}
		var scope struct{ Inactive map[string]rendererAccount }
		if err := decodeState(state, rendererStateKey, &scope); err != nil {
			t.Fatal(err)
		}
		return scope.Inactive[owner]
	}
	backups := func(want int) []string {
		t.Helper()
		files, err := filepath.Glob(filepath.Join(home, switchDirName, projectBackupsDirectory, "*.json"))
		if err != nil || len(files) != want {
			t.Fatalf("want %d backups, got %d: %v", want, len(files), err)
		}
		return files
	}
	if n, err := syncLocalProjects(home); err != nil || n != 1 {
		t.Fatalf("sync: %d, %v", n, err)
	}
	first := backups(1)[0]
	got := read()
	var projects map[string]stateFields
	if err := decodeState(got.Globals, "local-projects", &projects); err != nil {
		t.Fatal(err)
	}
	if len(projects) != 1 || string(projects["existing"]["name"]) != `"Shared"` || projects["existing"]["chatGptBacking"] != nil {
		t.Fatal("project list was not replaced with remapped IDs")
	}
	if string(got.Globals["project-order"]) != `["existing"]` ||
		string(got.Globals["pinned-project-ids"]) != `["existing"]` ||
		string(got.Globals["project-appearances"]) != `{"existing":{"color":"red"}}` ||
		string(got.Atoms[expandedProjectPrefix+"existing"]) != "false" ||
		string(got.Atoms[projectAtomKeys[0]]) != `["chatgpt:project:private","codex:project:existing"]` {
		t.Fatal("project sidebar state did not follow the source")
	}
	if _, err := syncLocalProjects(home); err != nil {
		t.Fatal(err)
	}
	backups(1)
	if _, err := changeLocalProjects(home, "delete", "target@example.com", ""); err != nil {
		t.Fatal(err)
	}
	backups(2)
	if got := read(); got.Globals["local-projects"] != nil || string(got.Globals["thread-project-assignments"]) != `{"keep":"removed"}` {
		t.Fatal("deletion did not clear only the projects")
	}
	if _, err := changeLocalProjects(home, "restore", "target@example.com", first); err != nil {
		t.Fatal(err)
	}
	backups(3)
	if string(read().Globals["project-order"]) != `["removed","existing"]` {
		t.Fatal("original order not restored")
	}
	// An outgoing account with no projects must also replace the destination.
	var state stateFields
	current, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(current, &state); err != nil {
		t.Fatal(err)
	}
	delete(state, "local-projects")
	current, err = json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	write(path, current)
	if n, err := syncLocalProjects(home); err != nil || n != 0 {
		t.Fatalf("empty sync: %d, %v", n, err)
	}
	backups(4)
	if string(read().Globals["local-projects"]) != "{}" {
		t.Fatal("empty source did not remove destination projects")
	}

}
