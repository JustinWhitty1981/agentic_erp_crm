// Package memory is what this agent has been told to remember.
//
// There are two implementations, and which one is live is a startup fact rather than a runtime
// one. The database one (pkg/ids keys, 0023's agent_memories table) is the deployment; the file one
// is what runs when MEMORY_DRIVER=file was asked for or when no database is configured at all, and
// it says so in the log the moment it is used. A store that quietly fell back to files mid-run
// would split one agent's memory across two places and report no difference, which is a worse
// outcome than the error it would have replaced.
//
// The database form is 0023's, and the reason it exists is stated there: the file version's key
// identity was a sanitised filename, so "a/b" and "a_b" were the same memory and nothing reported
// the collision, and the files lived in the container's filesystem, so a rebuild made the agent
// forget every preference it had ever been told. Those two properties - a key that means one thing
// and a record that outlives the process - are the whole of ADR-002 as it applies here.
package memory

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"jada-backend/pkg/ids"
	"jada-backend/pkg/turn"
)

// Caller is the slice of the database the memory store uses: stored functions, by name, with
// positional arguments. Nothing else, which is the point - a memory package that could run a SELECT
// against an arbitrary table would be one import away of becoming a second, undocumented data path.
type Caller interface {
	Call(ctx context.Context, name string, args []any) ([]map[string]any, error)
}

// Driver names the store in force, for /api/health and for the startup log line.
const (
	DriverDB   = "db"
	DriverFile = "file"

	EnvDriver = "MEMORY_DRIVER"
	EnvDir    = "MEMORY_DIR"
)

// DefaultDir is the file store's home when MEMORY_DIR is unset. It is the path the original
// implementation used, kept so that a deployment running in file mode still finds what it wrote
// before this package changed - a compatibility detail, and the only one.
const DefaultDir = "memory_store"

var (
	mu      sync.RWMutex
	store   Caller
	driver  string
	dir     = envOr(EnvDir, DefaultDir)
	warned  sync.Once
	invalid = regexp.MustCompile(`[^\w\-_.]`)
)

func envOr(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

// Use installs the database store. Calling it with nil selects file mode explicitly, which main does
// when MEMORY_DRIVER=file, rather than relying on "we never got as far as wiring a database".
func Use(c Caller) {
	mu.Lock()
	defer mu.Unlock()
	store = c
	if c == nil {
		driver = DriverFile
	} else {
		driver = DriverDB
	}
	slog.Info("memory store selected", "driver", driver, "dir", dir)
}

// Driver reports which store is live.
func Driver() string {
	mu.RLock()
	defer mu.RUnlock()
	if driver == "" {
		return DriverFile
	}
	return driver
}

// SetDir changes the file store's location. Exported for the same reason the directory is: a
// deployment that mounts a volume elsewhere needs one line of configuration, not a code change.
func SetDir(d string) {
	mu.Lock()
	defer mu.Unlock()
	dir = d
}

// Dir is the file store's location, which /api/health reports when that is the store in force.
func Dir() string {
	mu.RLock()
	defer mu.RUnlock()
	return dir
}

// Save records one fact under one key.
//
// The database path appends: the same key written twice is a memory with two entries, newest first,
// because "what we learned about this customer" is a history and the file version's overwrite was
// the behaviour 0023 replaced. The key shape and the normalisation of case and whitespace belong to
// the table's constraints, not to this function - stating them here would be a second copy of a rule
// that can rot while still looking green.
//
// It returns a sentence for the model rather than an error for normal refusals, matching the file
// version's contract that the tool registry was written against; an error is reserved for the store
// being unreachable, which is not a fact about the memory.
func Save(ctx context.Context, key, content string) string {
	if c := current(); c != nil {
		row, err := c.Call(ctx, "save_memory", []any{
			key, content, claimKey(ctx, "save_memory", key, content),
		})
		if err != nil {
			return fail("save_memory", err)
		}
		return oneRow(row, key)
	}

	noteFileStore("save")
	return saveFile(key, content)
}

// Read returns the stored entries under one key, newest first.
func Read(ctx context.Context, key string, limit int) string {
	if limit <= 0 {
		limit = 10
	}
	if limit > 200 {
		// The same bound get_memory's p_limit enforces. Checked here so the caller sees a sentence
		// about the number rather than a 22023 from the server, and the cap itself stays in the
		// database: this line is a courtesy, not the rule.
		limit = 200
	}

	if c := current(); c != nil {
		rows, err := c.Call(ctx, "get_memory", []any{key, limit})
		if err != nil {
			return fail("get_memory", err)
		}
		if len(rows) == 0 {
			return fmt.Sprintf("No entries stored under %q.", key)
		}
		out, err := json.Marshal(rows)
		if err != nil {
			return fail("render entries", err)
		}
		return string(out)
	}

	noteFileStore("read")
	return readFile(key)
}

// List shows every key and how much has been learned under each.
//
// The count is the interesting column, and it is only meaningful in the database: a file's presence
// says a key was written, six rows under a key says it was written six times.
func List(ctx context.Context) string {
	if c := current(); c != nil {
		rows, err := c.Call(ctx, "list_memories", []any{})
		if err != nil {
			return fail("list_memories", err)
		}
		if len(rows) == 0 {
			return "No memories have been saved yet."
		}
		out, err := json.Marshal(rows)
		if err != nil {
			return fail("render keys", err)
		}
		return string(out)
	}

	noteFileStore("list")
	return listFile()
}

// ---------------------------------------------------------------------------
// dispatch
// ---------------------------------------------------------------------------

func current() Caller {
	mu.RLock()
	defer mu.RUnlock()
	return store
}

// claimKey scopes a retried save to one memory rather than two entries about the same fact. Same
// derivation as the CRM writes, same scope: within a run, because "remember X" said twice in one
// turn is one thing learned, and across turns it is either a restatement or a change and the agent
// means it either way.
func claimKey(ctx context.Context, tool, key, content string) any {
	k := ids.CallKey(turn.RunID(ctx), tool, []any{key, content})
	if k == "" {
		return nil
	}
	return k
}

// fail renders a store failure as text. The tool contract returns strings, and an error here would
// reach the model as "Error executing tool", which hides the one thing worth knowing: whether the
// database refused the write or was never reachable. So the sentence says which, and the log line
// carries the error.
func fail(what string, err error) string {
	slog.Error("memory operation failed", "operation", what, "err", err)
	if isUnreachable(err) {
		return fmt.Sprintf("The memory store could not be reached, so nothing was changed (%v). "+
			"Retry, or say that the fact could not be recorded.", err)
	}
	return fmt.Sprintf("The memory store refused the operation: %v", err)
}

func isUnreachable(err error) bool {
	s := strings.ToLower(err.Error())
	for _, m := range []string{"connection refused", "no route to host", "context deadline",
		"driver: bad connection", "server closed", "i/o timeout", "not configured", "pool error"} {
		if strings.Contains(s, m) {
			return true
		}
	}
	return false
}

// oneRow renders save_memory's answer row. The door's contract carries a success boolean, so a
// refusal is data rather than an exception and this reports it as such.
func oneRow(rows []map[string]any, key string) string {
	if len(rows) == 0 {
		// "no row" is a different failure from success=false, and the distinction is worth a
		// sentence: 0023's door answers a refusal WITH a row, so an empty result means the call did
		// not run at all.
		return fmt.Sprintf("save_memory returned no row: nothing was recorded under %q.", key)
	}
	out, err := json.Marshal(rows[0])
	if err != nil {
		return fail("render result", err)
	}

	if ok, _ := rows[0]["success"].(bool); ok {
		// The key logged is the argument as sent, not as stored: the table normalises case and
		// whitespace and the stored form is whatever the constraint decided, so logging the input
		// and letting the row's own message describe the outcome is the honest pair.
		slog.Info("memory saved", "key", key, "memory_id", rows[0]["memory_id"],
			"message", rows[0]["message"])
	} else {
		slog.Info("memory refused", "key", key, "message", rows[0]["message"])
	}
	return string(out)
}

func noteFileStore(op string) {
	warned.Do(func() {
		slog.Warn("memory is file-backed: entries will not survive a container rebuild, are not "+
			"separated by tenant, leave no audit trail, and share keys through filename sanitising "+
			"(0023). Set AFPC_PG_HOST to use the database store.", "dir", Dir(), "operation", op)
	})
}

// ---------------------------------------------------------------------------
// The file store
// ---------------------------------------------------------------------------
// Retained, not repaired. Everything below is the behaviour the agent had before 0023, and it is
// kept because MEMORY_DRIVER=file is a real configuration and because deleting the only working
// implementation of an interface to replace it with a database that may not be reachable would mean
// the deployment has no memory at all on the day the database is down for maintenance.
//
// Its two defects are 0023's header and are NOT fixed here, because fixing them would produce a
// second, worse copy of the database semantics: keys fold on filename sanitising, and an entry is
// appended to one markdown file rather than becoming a row.

func filePath(key string) string {
	safe := invalid.ReplaceAllString(key, "_")
	if safe == "" {
		safe = "unnamed"
	}
	return filepath.Join(Dir(), safe+".md")
}

func saveFile(key, content string) string {
	if err := os.MkdirAll(Dir(), 0o755); err != nil {
		return fmt.Sprintf("Error creating memory directory: %v", err)
	}
	entry := fmt.Sprintf("\n---\n**Timestamp:** %s\n**Content:**\n%s\n",
		time.Now().Format("2006-01-02 15:04:05"), content)

	f, err := os.OpenFile(filePath(key), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Sprintf("Error saving memory: %v", err)
	}
	defer f.Close()
	if _, err := f.WriteString(entry); err != nil {
		return fmt.Sprintf("Error writing memory: %v", err)
	}
	return fmt.Sprintf("Memory saved under key: %s", key)
}

func readFile(key string) string {
	b, err := os.ReadFile(filePath(key))
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Sprintf("No memory found for key: %s", key)
		}
		return fmt.Sprintf("Error reading memory: %v", err)
	}
	if len(b) == 0 {
		return fmt.Sprintf("Memory exists for key: %s but content is empty", key)
	}
	return fmt.Sprintf("Memory for key '%s':\n%s", key, string(b))
}

func listFile() string {
	entries, err := os.ReadDir(Dir())
	if err != nil {
		return fmt.Sprintf("Error accessing memory storage: %v", err)
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".md") {
			names = append(names, strings.TrimSuffix(e.Name(), ".md"))
		}
	}
	if len(names) == 0 {
		return "No memories have been saved yet."
	}
	sort.Strings(names)
	return fmt.Sprintf("Found %d memories:\n%s", len(names), strings.Join(names, "\n"))
}
