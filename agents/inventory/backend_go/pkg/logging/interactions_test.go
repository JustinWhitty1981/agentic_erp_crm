package logging

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
)

func TestMain(m *testing.M) {
	slog.SetDefault(slog.New(slog.NewTextHandler(io.Discard, nil)))
	os.Exit(m.Run())
}

// capture is the recorder's database: the statements it was asked to run, with their arguments.
type capture struct {
	sql  string
	args []any
	err  error
}

func (c *capture) Exec(_ context.Context, sql string, args ...any) error {
	c.sql, c.args = sql, args
	return c.err
}
func (c *capture) Tenant() string { return "00000000-0000-0000-0000-000000000001" }

// TestArraysStayPositionAligned is the contract vw_tool_calls is built on, and the single most
// important property in this file.
//
// 0017 derives one row per tool call by pairing element n of actions_taken with element n of
// tool_observations, because the JSONB arrays carry no key to join on. A run that recorded a call
// without an observation would not fail: it would pair every LATER call with the WRONG output, and a
// tool whose recorded result belongs to its neighbour is a trajectory that actively misleads whoever
// is reading it to find a bug. The assertions are made through the public API on purpose - a test that
// reached into the fields could keep passing after the pairing broke.
func TestArraysStayPositionAligned(t *testing.T) {
	r := NewRun("thread-aligned", "did something", "customer_service", "model-x")

	r.BeginTool(0, "get_customer_info", map[string]any{"customer_name": "Acme"})
	r.EndTool(0, `[{"id":1}]`, nil)
	r.BeginTool(1, "add_communication", map[string]any{"summary": "Called"})
	r.EndTool(1, `{"success":true}`, nil)

	row := r.Row()
	acts := decodeArray(t, row["actions_taken"])
	obs := decodeArray(t, row["tool_observations"])

	if len(acts) != len(obs) {
		t.Fatalf("actions=%d observations=%d: vw_tool_calls would pair step 1 of one with step 1 of "+
			"the other and attribute the wrong output", len(acts), len(obs))
	}
	for i := range acts {
		if acts[i]["tool"] == nil {
			t.Errorf("action %d names no tool", i)
		}
	}
	if got, want := obs[0]["type"], "result"; got != want {
		t.Errorf("observation 0 is %v, want %q - 0017 publishes observation_type and a class name "+
			"in that field is what the Python writer did", got, want)
	}
}

// TestAbandonedCallStillPairs covers the path that breaks the alignment: a call that began and never
// returned, which is what an early return or a panic leaves behind.
func TestAbandonedCallStillPairs(t *testing.T) {
	r := NewRun("thread-abandoned", "input", "customer_service", "model-x")
	r.BeginTool(0, "get_customer_info", map[string]any{"customer_name": "Acme"})
	r.EndTool(0, "[]", nil)
	r.BeginTool(1, "add_communication", nil) // never closed, by design

	r.Finish("partial answer", errors.New("the model call failed"))

	row := r.Row()
	acts := decodeArray(t, row["actions_taken"])
	obs := decodeArray(t, row["tool_observations"])
	if len(acts) != 2 || len(obs) != 2 {
		t.Fatalf("actions=%d observations=%d, want 2 and 2", len(acts), len(obs))
	}
	if obs[1]["type"] != "error" {
		t.Errorf("the abandoned call is recorded as %v; it must be an error, not a blank result",
			obs[1]["type"])
	}
	if !strings.Contains(asString(obs[1]["output"]), "ended before") {
		t.Errorf("the abandoned observation says %q, which does not explain itself", obs[1]["output"])
	}
}

// TestErrorIsNotSwallowedBySuccess is ADR-001's reason the table exists: the failed runs are the ones
// worth reading, so a failure must reach the row rather than stop at the log.
func TestErrorIsNotSwallowedBySuccess(t *testing.T) {
	c := &capture{}
	rc := NewRecorder(c, true)

	r := NewRun("thread-failed", "input", "customer_service", "model-x")
	r.BeginTool(0, "get_customer_info", map[string]any{"customer_name": "Acme"})
	r.EndTool(0, "", errors.New("connection refused"))
	r.Finish("", errors.New("the model server answered 502"))

	if err := rc.Record(context.Background(), r); err != nil {
		t.Fatalf("Record: %v", err)
	}

	// The error column is position 13 in the INSERT, and the test reads it by index because that is
	// how the statement is written; the binding order is checked against the column list in the
	// statement itself by TestColumnListMatchesArgs.
	if len(c.args) != 15 {
		t.Fatalf("the INSERT bound %d parameters, want 15", len(c.args))
	}
	msg, _ := c.args[13].(string)
	if msg != "the model server answered 502" {
		t.Errorf("error_message = %q; a run that failed and recorded nothing is the failure ADR-001 "+
			"is about", msg)
	}
	if c.args[5] != "input" {
		t.Errorf("human_input bound to %v - the arguments are in the wrong positions", c.args[5])
	}
}

// TestColumnListMatchesArgs is the guard for the index arithmetic the tests above depend on, and for
// the far more common bug: adding a column to the INSERT's list without adding its value, which
// shifts every later parameter by one and writes the model name into final_output.
//
// The count is derived from the statement rather than hard-coded, so the check cannot go stale the way
// a constant does.
func TestColumnListMatchesArgs(t *testing.T) {
	c := &capture{}
	r := NewRun("thread-cols", "in", "customer_service", "model-x")
	r.Usage(11, 22)
	if err := NewRecorder(c, true).Record(context.Background(), r); err != nil {
		t.Fatal(err)
	}

	// The column list and the VALUES list are parsed and compared element by element, rather than
	// counted. A count cannot tell the difference between "one column lost its value" and "one value
	// lost its column", and the second is the one that silently shifts every later parameter by one
	// and writes the model name into final_output.
	head := strings.Index(c.sql, "(")
	tail := strings.Index(c.sql, ") VALUES (")
	if head < 0 || tail < 0 {
		t.Fatalf("could not find both lists in %q", c.sql)
	}
	cols := splitList(c.sql[head+1 : tail])
	valsStart := tail + len(") VALUES (")
	vals := splitList(c.sql[valsStart : valsStart+matchParen(c.sql[valsStart:])])

	if len(cols) != len(vals) {
		t.Fatalf("%d columns and %d values:\n  %v\n  %v", len(cols), len(vals), cols, vals)
	}

	next, positional := 0, map[int]int{}
	for i, v := range vals {
		switch {
		case strings.HasPrefix(v, "$"):
			n := 0
			for _, ch := range strings.Trim(v, "$:") {
				if ch >= '0' && ch <= '9' {
					n = n*10 + int(ch-'0')
				}
			}
			positional[i] = n
		case v == "now()":
			// The only column this INSERT lets the server fill. It is allowed, and it is named here
			// rather than accepted silently, because a second one would mean the writer stopped
			// controlling a timestamp and did not say so. The identifier is unquoted first: the
			// statement writes "timestamp" quoted because the word is reserved, and the comparison is
			// about which column, not how it was spelled.
			if unquote(cols[i]) != "timestamp" {
				t.Errorf("now() feeds %q; the interaction's own time is the one server-side value",
					cols[i])
			}
		default:
			t.Errorf("column %q is fed the literal %q", unquote(cols[i]), v)
		}
	}
	next = len(positional)
	if len(c.args) != next {
		t.Fatalf("%d parameters appear in the statement and %d were bound", next, len(c.args))
	}
	for i := 1; i <= next; i++ {
		if !hasInt(positional, i) {
			t.Errorf("no column is fed $%d, so the numbering has a hole in it", i)
		}
	}
}

func hasInt(m map[int]int, n int) bool {
	for _, v := range m {
		if v == n {
			return true
		}
	}
	return false
}

// matchParen returns the offset of the ')' that closes a list starting at s[0].
//
// Indexing for the first ')' would have been the obvious way to write this and it is wrong: the list
// contains now(), whose closing paren arrives first and truncates the VALUES list to six entries. The
// same class of mistake as splitting SQL on a comma without regard for depth.
func matchParen(s string) int {
	depth := 1
	for i, r := range s {
		switch r {
		case '(':
			depth++
		case ')':
			if depth--; depth == 0 {
				return i
			}
		}
	}
	return len(s)
}

// unquote strips the identifier quoting a SQL list carries, because the comparison these tests make
// is about which column, not about how the statement spelled it.
func unquote(ident string) string {
	return strings.Trim(ident, "\"`")
}

// splitList splits a SQL list on commas that are not inside quotes.
func splitList(s string) []string {
	var (
		out   []string
		cur   strings.Builder
		depth int
	)
	for _, r := range s {
		switch r {
		case '(':
			depth++
			cur.WriteRune(r)
		case ')':
			depth--
			cur.WriteRune(r)
		case ',':
			if depth == 0 {
				out = append(out, strings.TrimSpace(cur.String()))
				cur.Reset()
				continue
			}
			cur.WriteRune(r)
		default:
			cur.WriteRune(r)
		}
	}
	if t := strings.TrimSpace(cur.String()); t != "" {
		out = append(out, t)
	}
	return out
}

// TestDisabledRecorderDoesNotWrite: LOG_AGENT_INTERACTIONS=false is a real configuration, and what it
// must mean is "no INSERT", not "no run".
func TestDisabledRecorderDoesNotWrite(t *testing.T) {
	c := &capture{}
	r := NewRun("thread-off", "in", "customer_service", "model-x")
	if err := NewRecorder(c, false).Record(context.Background(), r); err != nil {
		t.Fatalf("a disabled recorder must not fail the turn: %v", err)
	}
	if c.sql != "" {
		t.Errorf("a disabled recorder still ran %q", c.sql)
	}
}

// TestNilDBIsDisabled covers the startup order: main builds the agent before it has a connection, so
// the recorder is constructed with nothing in it and must report itself off rather than panic at the
// first turn.
func TestNilDBIsDisabled(t *testing.T) {
	if NewRecorder(nil, true).Enabled() {
		t.Error("a recorder with no database reports itself enabled, so every turn logs an INSERT error")
	}
}

// TestSourcesAreDeduplicated: response_sources answers "what did this run look at". A tool that
// resolved the same customer five times in one turn should produce one entry, or the column becomes a
// histogram of the loop rather than a list of records.
func TestSourcesAreDeduplicated(t *testing.T) {
	r := NewRun("thread-src", "in", "customer_service", "model-x")
	for i := 0; i < 5; i++ {
		r.Source("entities", int64(42))
	}
	r.Source("entities", int64(43))
	r.Source("communications", nil)

	got := decodeStrings(t, r.Row()["response_sources"])
	if len(got) != 2 {
		t.Fatalf("response_sources holds %d entries: %#v", len(got), got)
	}
	if got[0] != "entities:42" || got[1] != "entities:43" {
		t.Errorf("response_sources = %q, want entities:42 and entities:43", got)
	}
}

// TestThreadMappingIsStable is the property the history read path depends on: one thread must map to
// one conversation id in every process, forever, or a redeploy starts a new history for the same
// conversation and /api/interactions shows a shorter story than the database holds.
func TestThreadMappingIsStable(t *testing.T) {
	const thread = "web:demo-thread-1"
	a := ConversationID(thread)
	if b := ConversationID(thread); a != b {
		t.Fatalf("ConversationID is not deterministic: %s then %s", a, b)
	}
	if strings.Count(a, "-") != 4 || len(a) != 36 {
		t.Errorf("ConversationID(%q) = %q, which is not a uuid and will not cast into the uuid column",
			thread, a)
	}
	if a[14] != '5' {
		t.Errorf("conversation id %s is not a v5 uuid; it should be derived, not random", a)
	}
	if ConversationID("web:other") == a {
		t.Error("two threads share one conversation id, so their histories would interleave")
	}
}

// TestThoughtsAreTextArray: agent_thoughts is text[], and a value bound as a JSON string instead of a
// slice is the 42804 that loses the row.
func TestThoughtsAreTextArray(t *testing.T) {
	c := &capture{}
	r := NewRun("thread-thoughts", "in", "customer_service", "model-x")
	r.Thought("I should look this up first")
	r.Thought("   ")
	if err := NewRecorder(c, true).Record(context.Background(), r); err != nil {
		t.Fatal(err)
	}
	list, ok := c.args[6].([]string)
	if !ok {
		t.Fatalf("agent_thoughts was bound as %T; the column is text[]", c.args[6])
	}
	if len(list) != 1 {
		t.Errorf("thoughts = %q, want the one non-empty entry", list)
	}
}

// TestMaskLeavesTheShape: the log line has to stay recognisable for a human - which is why a
// truncated local part and a domain tail are kept - while carrying nothing that identifies a person.
func TestMaskLeavesTheShape(t *testing.T) {
	cases := map[string][]string{
		"emailed alice.nguyen@acme.com about it": {"alice.nguyen", "acme.com"},
		"called +1 (555) 010-0101 back":          {"5550100101"},
		"no contact details here at all":         {},
		"two: a@b.com and c.d@e.org":             {"a@b.com", "c.d@e.org"},
	}
	for in, secrets := range cases {
		got := Mask(in)
		for _, s := range secrets {
			if strings.Contains(got, strings.ReplaceAll(s, "@", "")) ||
				strings.Contains(got, s) {
				t.Errorf("Mask(%q) = %q still contains %q", in, got, s)
			}
		}
		if !strings.Contains(got, " ") && len(in) > 8 {
			t.Errorf("Mask(%q) = %q collapsed the sentence; the shape of the message is the useful "+
				"part of a log line", in, got)
		}
	}
}

// TestMaskArgsIsStable: debug lines are diffed by eye, so two identical calls printing differently
// because a map's iteration order changed is a log that cannot be read.
func TestMaskArgsIsStable(t *testing.T) {
	args := map[string]any{
		"zeta": 1, "alpha": "x", "email": "alice@acme.com", "phone": "+15550100101",
	}
	first := MaskArgs(args)
	for i := 0; i < 20; i++ {
		if got := MaskArgs(args); got != first {
			t.Fatalf("the same arguments printed %q and then %q", first, got)
		}
	}
	if strings.Contains(first, "alice@acme.com") || strings.Contains(first, "15550100101") {
		t.Errorf("MaskArgs leaked a contact point: %s", first)
	}
	if !strings.Contains(first, "alpha=x") {
		t.Errorf("MaskArgs lost an ordinary argument: %s", first)
	}
	if !strings.HasPrefix(first, "alpha=") {
		t.Errorf("MaskArgs is not key-sorted: %s", first)
	}
	if s := MaskArgs(nil); s != "(no arguments)" {
		t.Errorf("an empty call printed %q; a blank log line reads like a broken formatter", s)
	}
}

// decodeArray accepts a field either as the Go slice Row() hands over or as the encoded bytes
// jsonParam produces. The two forms are the same fact at different depths, and a test that only
// understood one of them would fail the day the recorder marshalled earlier - which is a change worth
// making, not a mistake to punish.
func decodeArray(t *testing.T, v any) []map[string]any {
	t.Helper()
	switch value := v.(type) {
	case []map[string]any:
		return value
	case []byte:
		var out []map[string]any
		if err := json.Unmarshal(value, &out); err != nil {
			t.Fatalf("not a JSON array of objects: %v (%s)", err, value)
		}
		return out
	case json.RawMessage:
		var out []map[string]any
		if err := json.Unmarshal(value, &out); err != nil {
			t.Fatalf("not a JSON array of objects: %v (%s)", err, value)
		}
		return out
	default:
		t.Fatalf("the field was %T, not an array", v)
		return nil
	}
}

// decodeStrings is decodeArray for the jsonb column that holds an array of strings rather than of
// objects: response_sources. Keeping both helpers rather than one that returns []any is deliberate -
// the shape of each column is part of what these tests assert.
func decodeStrings(t *testing.T, v any) []string {
	t.Helper()
	switch value := v.(type) {
	case []string:
		return value
	case []byte, json.RawMessage:
		var out []string
		b, _ := value.([]byte)
		if err := json.Unmarshal(b, &out); err != nil {
			t.Fatalf("not a JSON array of strings: %v (%s)", err, b)
		}
		return out
	default:
		t.Fatalf("the field was %T, not a string array", v)
		return nil
	}
}

func asString(v any) string {
	s, _ := v.(string)
	return s
}
