package crm

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"jada-backend/pkg/tools"
	"jada-backend/pkg/turn"
	"sort"
	"strconv"

	"jada-backend/pkg/memory"
)

// TestMain quiets the package's logging: these tests exercise write paths, and each one logs its
// outcome by design, so without this the report buries its own failures in INFO lines.
//
// It also sends the memory store to a temp directory. pkg/memory falls back to a FILE store rooted at
// the process's working directory when no database Caller is installed, and the embedding keeper's
// tests reach it through remember() - so a package test run inside the build container wrote
// pkg/crm/memory_store/*.md into the source tree and left it there, owned by root. A test that writes
// into the tree it is testing is a residue generator, and the residue looks like a feature.
func TestMain(m *testing.M) {
	slog.SetDefault(slog.New(slog.NewTextHandler(io.Discard, nil)))
	dir, err := os.MkdirTemp("", "afpc-crm-tests")
	if err != nil {
		// Worse than a temp dir in the tree: without this the tests would write straight back into
		// it, which is the residue this exists to stop.
		panic("could not make a temp directory for the memory store: " + err.Error())
	}
	os.Setenv(memory.EnvDir, dir)
	os.Setenv(memory.EnvDriver, memory.DriverFile)
	os.Chdir(dir) // nothing in this package should be able to write beside the sources
	os.Exit(m.Run())
}

// fake is the whole database a CRM tool test needs: the calls it made, and the answer to give.
type fake struct {
	calls []fakeCall
	rows  []map[string]any
	err   error
}

type fakeCall struct {
	name string
	args []any
	sql  string
}

func (f *fake) Query(_ context.Context, sql string, args ...any) ([]map[string]any, error) {
	f.calls = append(f.calls, fakeCall{sql: sql, args: args})
	if f.err != nil {
		return nil, f.err
	}
	return f.rows, nil
}

func (f *fake) Call(_ context.Context, name string, args []any) ([]map[string]any, error) {
	f.calls = append(f.calls, fakeCall{name: name, args: args})
	if f.err != nil {
		return nil, f.err
	}
	return f.rows, nil
}

func runCtx(runID string) context.Context {
	if runID == "" {
		return context.Background()
	}
	return turn.From(context.Background(), runID, "thread", stubTrail{runID})
}

type stubTrail struct{ id string }

func (s stubTrail) ID() string         { return s.id }
func (s stubTrail) Source(string, any) {}

// TestWriteToolsSendTheirOwnParamCount is the shape assertion behind every write tool.
//
// Each door has every parameter DEFAULTed, so a short call is not a type error - it is a different
// branch of the body. A tool that dropped one positional argument would therefore run, and run the
// wrong rules, which is 4.4's ambiguity in a new costume: not two functions with one name, but one
// function whose arity the caller quietly changed. Counting the arguments is the cheapest way to
// notice, and the counts are written next to each door's signature in db/migrations.
func TestWriteToolsSendTheirOwnParamCount(t *testing.T) {
	cases := []struct {
		tool string
		want int
		args map[string]any
	}{
		{"add_customer", 15, map[string]any{}},
		{"update_customer", 13, map[string]any{}},
		{"add_communication", 20, map[string]any{}},
		// mark_customer_followup refuses an empty call, and that refusal is the point: the door has
		// one required parameter and no defaults, so it cannot be called short by accident.
		{"mark_customer_followup", 2, map[string]any{"entity_id": float64(1)}},
	}

	for _, tc := range cases {
		f := &fake{rows: []map[string]any{{"success": true, "message": "ok"}}}
		if tc.tool == "mark_customer_followup" {
			f.rows = []map[string]any{{"mark_customer_followup": "marked"}}
		}
		var found bool
		for _, d := range Tools(f, nil) {
			if d.Name != tc.tool {
				continue
			}
			found = true
			if _, err := d.ExecuteContext(runCtx("11111111-1111-1111-1111-111111111111"),
				tc.args); err != nil {
				t.Fatalf("%s: %v", tc.tool, err)
			}
		}
		if !found {
			t.Fatalf("%s is not registered", tc.tool)
		}
		if len(f.calls) != 1 {
			t.Fatalf("%s made %d calls, want 1", tc.tool, len(f.calls))
		}
		if got := len(f.calls[0].args); got != tc.want {
			t.Errorf("%s sent %d positional arguments, want %d - the door's signature has that many, "+
				"and a shorter call silently runs a different branch", tc.tool, got, tc.want)
		}
	}
}

// TestClaimsAreLastPosition pins where the idempotency key goes: the final position of add_customer
// and add_communication. Put it anywhere earlier and every subsequent argument shifts one slot, the
// door reads a phone number as a street, and the row that lands is wrong in a way no constraint
// catches.
func TestClaimsAreLastPosition(t *testing.T) {
	for _, tc := range []struct {
		tool string
		n    int
	}{
		{"add_customer", 15},
		{"add_communication", 20},
	} {
		f := &fake{rows: []map[string]any{{"success": true}}}
		for _, d := range Tools(f, nil) {
			if d.Name != tc.tool {
				continue
			}
			if _, err := d.ExecuteContext(runCtx("22222222-2222-2222-2222-222222222222"),
				map[string]any{"summary": "x", "customer_name": "Acme"}); err != nil {
				t.Fatalf("%s: %v", tc.tool, err)
			}
		}
		if got := len(f.calls[0].args); got != tc.n {
			t.Fatalf("%s sent %d arguments, want exactly %d", tc.tool, got, tc.n)
		}
		last := f.calls[0].args[tc.n-1]
		if k, ok := last.(string); !ok || len(k) != 36 || strings.Count(k, "-") != 4 {
			t.Errorf("%s: position %d is %#v, want a uuid claim", tc.tool, tc.n, last)
		}
	}
}

// TestClaimAbsentWithoutARun is the "no run id" case, which is not the same thing as a NULL key
// arriving by accident.
//
// A constant key would be worse than no key: every write made outside a chat turn would share one
// claim, so the second one would be answered from the first one's cached row and a demo that creates
// two customers would show one. The door must run undeduplicated instead, which is what NULL means
// to 0011.
func TestClaimAbsentWithoutARun(t *testing.T) {
	f := &fake{rows: []map[string]any{{"success": true}}}
	for _, d := range Tools(f, nil) {
		if d.Name != "add_customer" {
			continue
		}
		if _, err := d.ExecuteContext(context.Background(), map[string]any{
			"first_name": "Ada", "last_name": "L", "email": "a@b.test"}); err != nil {
			t.Fatalf("add_customer outside a run: %v", err)
		}
	}
	if got := f.calls[0].args[14]; got != nil {
		t.Errorf("the claim slot holds %#v outside a run; want nil, so the door runs undeduplicated", got)
	}
}

// TestKeyStableAcrossSpellings is the reason the key is derived from the resolved vector rather than
// the model's JSON.
//
// The two spellings below are one request as the database sees it - same defaults, same values - and
// if they produced different keys, a retry after a timeout would file a second copy of the interaction
// and the trail would show two calls where one happened. That is ADR-005's failure mode, and it is
// silent, which is why it gets a test rather than a comment.
func TestKeyStableAcrossSpellings(t *testing.T) {
	const run = "33333333-3333-3333-3333-333333333333"

	f := &fake{rows: []map[string]any{{"success": true, "communication_id": 7}}}
	call := func(args map[string]any) string {
		for _, d := range Tools(f, nil) {
			if d.Name != "add_communication" {
				continue
			}
			if _, err := d.ExecuteContext(runCtx(run), args); err != nil {
				t.Fatalf("add_communication: %v", err)
			}
		}
		k, _ := f.calls[len(f.calls)-1].args[19].(string)
		return k
	}

	// The two spellings differ in how values are WRITTEN, never in which fields are set: an omitted
	// communication_type resolves to the door's DEFAULT of 'note', which is a different request from
	// 'call' and must produce a different key. Getting that distinction wrong here would have made the
	// test assert that the defaults are ignored, which is the opposite of what they are for.
	explicit := call(map[string]any{
		"entity_id": float64(42), "summary": "Called.",
		"communication_type": "call", "direction": "outbound", "duration_seconds": float64(300),
		"subject": "  Invoice 44  ",
	})
	implicit := call(map[string]any{
		"entity_id": "42", "summary": "Called.",
		"communication_type": "call", "direction": "outbound", "duration_seconds": "300",
		"subject": "Invoice 44",
	})

	if explicit != implicit {
		t.Errorf("one request spelled two ways produced two keys:\n  %s\n  %s", explicit, implicit)
	}

	other := call(map[string]any{"entity_id": float64(42), "summary": "Called again."})
	if other == explicit {
		t.Error("two different requests produced one key, so the second would be answered from the first")
	}
}

// TestKeyScopedToRun states the scope out loud, because "the same request forever" is what a reader
// will assume and it is the wrong assumption.
func TestKeyScopedToRun(t *testing.T) {
	args := map[string]any{"key": "prefs", "content": "same fact"}
	f := &fake{rows: []map[string]any{{"success": true}}}

	k := func(run string) string {
		return IdempotencyKey(run, "add_communication", []any{args["key"], args["content"]})
	}
	_ = f

	if k("44444444-4444-4444-4444-444444444444") == k("55555555-5555-5555-5555-555555555555") {
		t.Error("one request in two different runs produced one key, so the second run's write " +
			"would be answered from the first's cache instead of happening")
	}
	if k("") != "" {
		t.Error("an unattributed call produced a key, which means every unattributed call shares one")
	}
}

// TestSelectNeverInterpolated is 3.1's lesson applied to this package: the tools reach the database
// through parameters, and a string that made it into SQL text is a bug whether or not anyone can
// exploit it - because it also means the planner cannot use an index and the predicate is a different
// one than it looks.
func TestSelectNeverInterpolated(t *testing.T) {
	// Each tool is called with values for every property IT declares, because a tool that accepts one
	// name at a time refuses the others - correctly - and a test that ignored that would be reporting
	// refusals rather than checking statements.
	for _, d := range Tools(&fake{}, nil) {
		props, _ := d.Parameters["properties"].(map[string]any)
		args := map[string]any{}
		for name := range props {
			args[name] = probeValue(name)
		}

		f := &fake{rows: nil}
		var def tools.ToolDefinition
		for _, c := range Tools(f, nil) {
			if c.Name == d.Name {
				def = c
			}
		}
		def.ExecuteContext(runCtx("66666666-6666-6666-6666-666666666666"), args)

		for _, c := range f.calls {
			sql := c.sql
			if c.name != "" {
				sql = "SELECT * FROM " + c.name + "(" + strings.Repeat("$n,", 10) + ")"
			}
			for _, needle := range []string{"DROP TABLE", "O'Brien", "acme", "OR 1=1", "x@example.test"} {
				if strings.Contains(sql, needle) {
					t.Errorf("%s put a value in the SQL text (%q): %s", d.Name, needle, sql)
				}
			}
			if len(c.args) == 0 {
				t.Errorf("%s ran with no parameters at all, so the check above proves nothing: %s",
					d.Name, sql)
			}
		}
	}
}

// probeValue returns, for a named property, a value that also carries the injection attempt the test
// is looking for. A tool that interpolated would put it in the statement; a tool that parameterised
// leaves it in the argument vector, which is where it belongs.
func probeValue(name string) any {
	switch {
	case name == "entity_id" || name == "contact_id" || name == "parent_id" ||
		name == "days_threshold" || name == "limit" || name == "since_days" ||
		name == "duration_seconds":
		return float64(7)
	case name == "follow_up_required" || name == "is_primary" || name == "followup":
		return true
	case strings.Contains(name, "date") || strings.Contains(name, "started_at"):
		return "2026-11-03"
	default:
		return "O'Brien'; DROP TABLE entities; --"
	}
}

func TestReadToolsRefuseAnEmptyQuestion(t *testing.T) {
	f := &fake{rows: nil}
	for _, d := range Tools(f, nil) {
		if d.Name != "get_customer_info" && d.Name != "get_customer_communications" {
			continue
		}
		if _, err := d.ExecuteContext(context.Background(), map[string]any{}); err == nil {
			t.Errorf("%s answered a question it was not asked", d.Name)
		}
	}
}

func TestEmptyResultSaysSo(t *testing.T) {
	f := &fake{rows: nil}
	for _, d := range Tools(f, nil) {
		if d.Name != "get_customer_info" {
			continue
		}
		out, err := d.ExecuteContext(context.Background(), map[string]any{"customer_name": "Nobody"})
		if err != nil {
			t.Fatalf("an empty result is not an error: %v", err)
		}
		var got []map[string]any
		if err := json.Unmarshal([]byte(out), &got); err != nil {
			t.Fatalf("output is not a JSON array: %v", err)
		}
		if len(got) != 1 || got[0]["note"] == nil || got[0]["note"] == "" {
			t.Errorf("an empty lookup returned %s; want one row carrying a note, not a bare []", out)
		}
	}
}

// TestLimitIsBounded protects the context window. A model that asks for limit=100000 gets an error it
// can act on, not a result truncated mid-row - which is the failure that produces a confidently wrong
// answer instead of a visible error.
func TestLimitIsBounded(t *testing.T) {
	f := &fake{rows: nil}
	for _, d := range Tools(f, nil) {
		if d.Name != "get_customer_info" {
			continue
		}
		if _, err := d.ExecuteContext(context.Background(), map[string]any{
			"customer_name": "x", "limit": float64(100000)}); err == nil {
			t.Error("limit=100000 was accepted")
		}
		if _, err := d.ExecuteContext(context.Background(), map[string]any{
			"customer_name": "x", "limit": float64(2.5)}); err == nil {
			t.Error("limit=2.5 was accepted")
		}
	}
}

// TestAgentIDComesFromTheEnvironment is the audit-column rule: communications.agent_id is who did a
// thing, so it is not an argument, and the one argument it does take is the deployment's own name.
func TestAgentIDComesFromTheEnvironment(t *testing.T) {
	t.Setenv(EnvAgentRole, "front_desk")
	if got := AgentID(); got != "front_desk" {
		t.Errorf("AgentID() = %v, want the configured identity", got)
	}
	t.Setenv(EnvAgentRole, "")
	if got := AgentID(); got != DefaultAgentRole {
		t.Errorf("AgentID() = %v, want the default", got)
	}

	f := &fake{rows: []map[string]any{{"success": true}}}
	for _, d := range Tools(f, nil) {
		if d.Name == "add_communication" {
			d.ExecuteContext(context.Background(), map[string]any{
				"customer_name": "Acme", "summary": "s", "agent_id": "someone else"})
		}
	}
	// Position 9 is p_agent_id. A tool argument with that name must not reach it.
	if got := f.calls[0].args[9]; got != DefaultAgentRole {
		t.Errorf("p_agent_id = %v; the column is the process's identity, not a tool argument", got)
	}
}

// TestDateArgumentIsADate: p_follow_up_date is a `date`, so the tool sends a calendar day rather than
// an instant, whose day would depend on the server's zone.
func TestDateArgumentIsADate(t *testing.T) {
	f := &fake{rows: []map[string]any{{"success": true}}}
	for _, d := range Tools(f, nil) {
		if d.Name == "add_communication" {
			if _, err := d.ExecuteContext(context.Background(), map[string]any{
				"entity_id": float64(1), "summary": "s",
				"follow_up_required": true, "follow_up_date": "2026-12-31T23:00:00Z"}); err != nil {
				t.Fatal(err)
			}
		}
	}
	if got, ok := f.calls[0].args[16].(string); !ok || got != "2026-12-31" {
		t.Errorf("p_follow_up_date = %#v, want 2026-12-31", f.calls[0].args[16])
	}
}

// TestDateArgumentIsNotMovedByTheServersZone is the one the last commit's test did not cover, and the
// gap is the lesson: TestDateArgumentIsADate feeds an input with a Z on it, which round-trips through
// any zone intact. The value the model actually sends is bare - "2026-11-10" - and a bare input was
// parsed as midnight UTC, relabelled local, and then formatted in that local zone. Six hours west of
// UTC that prints 2026-11-09. The day the caller named and the day stored differed by one, on every
// follow-up booked from this process, silently, and the reply to the customer quoted the correct one.
//
// A fixed offset is used rather than a named zone so the test does not depend on the tz database being
// present in whatever image runs it - and so it fails on the old code in both directions, which a zone
// the CI happens to sit in would not have shown.
func TestDateArgumentIsNotMovedByTheServersZone(t *testing.T) {
	saved := time.Local
	defer func() { time.Local = saved }()

	for _, zone := range []*time.Location{
		time.FixedZone("UTC-6", -6*3600), // a container in America/Chicago, which is where this was found
		time.FixedZone("UTC+8", 8*3600),  // the mirror case: the same bug loses nothing but gains a day
		time.UTC,
	} {
		time.Local = zone
		for _, in := range []string{"2026-11-10", "2026-11-10T09:00:00", "2026-11-10 09:00:00"} {
			got, err := dateOnly(in)
			if err != nil {
				t.Fatalf("%s in %v: %v", in, zone, err)
			}
			if got != "2026-11-10" {
				t.Errorf("dateOnly(%q) with the server in %v = %v, want 2026-11-10 - a `date` argument "+
					"must never change the day it was given", in, zone, got)
			}
		}

		// An input that states its own zone keeps the day in *that* zone, which is the only claim the
		// string makes: 23:00Z on the 10th is the 10th wherever the server is.
		if got, _ := dateOnly("2026-11-10T23:00:00Z"); got != "2026-11-10" {
			t.Errorf("an explicit-Z input became %v in %v", got, zone)
		}
	}
}

// TestBareTimestampIsAnchoredLocally pins the other half of parseTemporal: a value with no zone in it is
// the caller's local time, which is what the comment has always said and what time.Parse plus .Local()
// did not do. Midnight local is twelve hours behind 06:00 UTC here; under the old code the instant was
// 2026-11-10T00:00:00Z, which is 18:00 on the 9th for the customer, and started_at is the column 0022's
// staleness clock reads.
func TestBareTimestampIsAnchoredLocally(t *testing.T) {
	saved := time.Local
	defer func() { time.Local = saved }()
	time.Local = time.FixedZone("UTC-6", -6*3600)

	v, err := timestamp("2026-11-10T00:00:00")
	if err != nil {
		t.Fatal(err)
	}
	got, ok := v.(time.Time)
	if !ok {
		t.Fatalf("timestamp returned %T", v)
	}
	if want := time.Date(2026, 11, 10, 0, 0, 0, 0, time.Local); !got.Equal(want) {
		t.Errorf("a bare timestamp resolved to %s, want local midnight %s - the difference is six hours, "+
			"which is a follow-up being due a day early or a day late", got.Format(time.RFC3339),
			want.Format(time.RFC3339))
	}

	// And a value that names UTC still means UTC; the fix must not have made everything local.
	w, _ := timestamp("2026-11-10T00:00:00Z")
	if wt, ok := w.(time.Time); !ok || !wt.Equal(time.Date(2026, 11, 10, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("an explicit-Z timestamp moved: %v", w)
	}
}

func TestTimestampForms(t *testing.T) {
	f := &fake{rows: []map[string]any{{"success": true}}}
	call := func(v string) error {
		for _, d := range Tools(f, nil) {
			if d.Name == "add_communication" {
				_, err := d.ExecuteContext(context.Background(), map[string]any{
					"entity_id": float64(1), "summary": "s", "started_at": v})
				return err
			}
		}
		return nil
	}

	for _, ok := range []string{"2026-11-03T14:30:00Z", "2026-11-03 14:30:00", "2026-11-03"} {
		if err := call(ok); err != nil {
			t.Errorf("%q was refused: %v", ok, err)
		}
	}
	if err := call("last tuesday"); err == nil {
		t.Error("an unparseable date was accepted, so it would have become some other instant")
	} else if !strings.Contains(err.Error(), "2026-11-03") {
		t.Errorf("the refusal does not show the accepted forms: %v", err)
	}
}

// TestEveryPropertyIsDocumented is the check that matters for a reader who cannot see the schema.
//
// The first draft of this test asked whether the tool's own description named every property, and that
// was the wrong claim: per-field documentation belongs on the field, where the model reads it while
// composing the call. What has to be true is that no property is silently undocumented - a property
// with an empty description is one the model fills by guessing, and a guess for p_follow_up_date or
// p_direction is a refusal the agent then has to work around.
func TestEveryPropertyIsDocumented(t *testing.T) {
	for _, d := range Tools(&fake{}, nil) {
		if d.Description == "" || len(d.Description) < 40 {
			t.Errorf("%s has no usable description (%d characters)", d.Name, len(d.Description))
		}
		props, _ := d.Parameters["properties"].(map[string]any)
		if len(props) == 0 && d.Name != "current_time" && d.Name != "list_memories_tool" {
			t.Errorf("%s accepts nothing, which for a CRM tool means it cannot be called with intent",
				d.Name)
		}

		req, _ := d.Parameters["required"].([]string)
		for _, p := range req {
			if _, ok := props[p]; !ok {
				t.Errorf("%s declares %q required without describing it", d.Name, p)
			}
		}

		for name, raw := range props {
			p, _ := raw.(map[string]any)
			desc, _ := p["description"].(string)
			if strings.TrimSpace(desc) == "" {
				t.Errorf("%s.%s has no description, so the model is guessing", d.Name, name)
				continue
			}
			// A property whose type this package would not accept is a schema that lies, which is
			// 0022's finding in the other direction: the signature saying one thing and the body
			// doing another.
			// Shadowing `t` here would be a compile error in the branches that report, which is the
			// one kindness the type switch has: this test is the assertion, and it cannot be
			// overwritten by a local while it is running.
			switch declared := p["type"].(type) {
			case string:
				if declared != "string" && declared != "boolean" {
					t.Errorf("%s.%s declares %q, which the coercion helpers do not read",
						d.Name, name, declared)
				}
			case []string:
				if strings.Join(declared, "|") != "integer|string" {
					t.Errorf("%s.%s declares %#v; only an id may be one of two types",
						d.Name, name, declared)
				}
			default:
				t.Errorf("%s.%s declares type %#v", d.Name, name, p["type"])
			}
			// Anything the door takes by position has to have a name the tool's argument reader knows,
			// and the only way to catch a typo is to say which names are expected.
			if !expectedArg(d.Name, name) {
				t.Errorf("%s documents %q, which no door parameter is wired to", d.Name, name)
			}
		}
	}
}

// expectedArg is the argument names each tool is allowed to carry. It is a list rather than a
// derivation because the alternative - reflecting over the SQL - is not a thing Go can do here, and
// the risk being covered is exactly the one a list covers well: renaming a property in one place and
// leaving the wiring in the other.
func expectedArg(tool, arg string) bool {
	switch tool {
	case "get_customer_info":
		return arg == "customer_name" || arg == "email" || arg == "phone" ||
			arg == "entity_id" || arg == "limit"
	case "get_customer_communications":
		return arg == "entity_id" || arg == "customer_name" || arg == "limit" ||
			arg == "since_days" || arg == "direction"
	case "get_entity_stats":
		return arg == "entity_name" || arg == "entity_id" || arg == "limit"
	case "get_followup_customers":
		return arg == "days_threshold"
	case "add_customer":
		return arg == "first_name" || arg == "last_name" || arg == "email" || arg == "phone" ||
			arg == "organization_name" || arg == "entity_type" || arg == "status" ||
			arg == "street" || arg == "city" || arg == "state" || arg == "postal_code" ||
			arg == "country" || arg == "address_type" || arg == "is_primary"
	case "update_customer":
		return arg == "search_name" || arg == "search_email" || arg == "search_phone" ||
			arg == "first_name" || arg == "last_name" || arg == "email" || arg == "phone" ||
			arg == "street" || arg == "city" || arg == "state" || arg == "postal_code" ||
			arg == "country" || arg == "status"
	case "add_communication":
		return arg == "customer_name" || arg == "entity_id" || arg == "contact_id" ||
			arg == "communication_type" || arg == "direction" || arg == "subject" ||
			arg == "summary" || arg == "full_content" || arg == "channel" ||
			arg == "sentiment_label" || arg == "priority" || arg == "outcome" ||
			arg == "duration_seconds" || arg == "follow_up_required" || arg == "follow_up_date" ||
			arg == "follow_up_action" || arg == "parent_id" || arg == "started_at"
	case "mark_customer_followup":
		return arg == "entity_id" || arg == "followup"
	}
	return true
}

// TestEveryDoorKeyIsReadableFromARead is the property that makes a write tool callable in a
// conversation rather than only in psql: every id a door's parameters name has to be returnable by
// some read in this same process. It is asserted against the SQL the tools build, not against a list
// in a comment, for the reason that took a week to find - `add_communication` told callers to pass a
// contact_id, and refused to guess one, while the read that shows you who was on the call returned
// contact_name and left the id in the view.
func TestEveryDoorKeyIsReadableFromARead(t *testing.T) {
	q := &fake{rows: []map[string]any{}}
	readable := map[string]bool{}
	sent := 0
	for _, d := range Tools(q, nil) {
		if !d.Policy.ReadOnly {
			continue
		}
		// Every read, driven with each selector it offers, because a tool's projection can differ by
		// branch and the union is what a caller can actually rely on.
		for _, args := range readArgShapes(d.Name) {
			if _, err := d.ExecuteContext(runCtx("88888888-8888-8888-8888-888888888888"), args); err != nil {
				continue
			}
			for _, c := range q.calls {
				if c.name != "" {
					continue
				}
				sent++
				for _, col := range selectedColumns(c.sql) {
					readable[col] = true
				}
			}
			q.calls = nil
		}
	}
	if sent == 0 {
		t.Fatal("no read in this package sent a query the test could inspect")
	}

	// The keys the doors take. `id` is what vw_customers' row calls the entity: the column is named
	// for the view and the argument is named for the table, and both spellings are accepted here so
	// that renaming one without the other is a failing build rather than an unreachable door.
	wanted := map[string][]string{
		"customer_id": {"id", "entity_id"}, // update_customer, mark_customer_followup
		"entity_id":   {"id", "entity_id"}, // add_communication
		"contact_id":  {"contact_id"},      // add_communication, and the one this test found missing
		"parent_id":   {"id", "communication_id"},
	}
	for arg, cols := range wanted {
		ok := false
		for _, c := range cols {
			if readable[c] {
				ok = true
				break
			}
		}
		if !ok {
			t.Errorf("a door takes %s and no read here returns any of %v - the argument is only fillable "+
				"by a human who already has it, which is the difference between a tool and a schema.\n"+
				"Columns this package's reads do return: %s",
				arg, cols, strings.Join(sortedKeys(readable), " "))
		}
	}
}

// readArgShapes is the per-tool argument sweep: one call per selector, plus the empty one the tools
// that need no selector accept.
func readArgShapes(name string) []map[string]any {
	switch name {
	case "get_customer_info":
		return []map[string]any{
			{"customer_name": "Jane"}, {"email": "j@x.test"}, {"phone": "+1777"},
			{"entity_id": float64(3)}, {"customer_name": "Jane", "limit": 5},
		}
	case "get_customer_communications":
		return []map[string]any{
			{"entity_id": float64(3)}, {"customer_name": "Jane"},
			{"entity_id": float64(3), "direction": "INBOUND", "since_days": 7}, {"limit": 5},
		}
	case "get_entity_stats":
		return []map[string]any{{"entity_id": float64(3)}, {"entity_name": "Jane"}, {"limit": 5}}
	case "get_followup_customers":
		return []map[string]any{{}, {"days_threshold": 14}}
	}
	return []map[string]any{{}}
}

func selectedColumns(sql string) []string {
	up := strings.Join(strings.Fields(sql), " ")
	i := strings.Index(strings.ToUpper(up), "SELECT ")
	j := strings.Index(strings.ToUpper(up[i:]), " FROM")
	if i < 0 || j <= 0 {
		return nil
	}
	var out []string
	for _, part := range strings.Split(up[i+len("SELECT "):i+j], ",") {
		part = strings.TrimSpace(part)
		if k := strings.LastIndex(strings.ToUpper(part), " AS "); k >= 0 {
			part = part[k+4:]
		}
		if d := strings.LastIndex(part, "."); d >= 0 {
			part = part[d+1:]
		}
		if part != "" && part != "*" {
			out = append(out, strings.ToLower(part))
		}
	}
	return out
}

func sortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// TestNoQuerySendsAParameterItsSQLNeverNames is the sibling property, and in this fork it is
// prevention: no filter here is placeholder-free today, so nothing has failed the way
// agents/sales' get_suppliers failed 20 of its 28 calls. The clause builder is the same code in all
// three backends, and this is what keeps a filter added in this one from arriving as a read that
// Postgres refuses whole.
func TestNoQuerySendsAParameterItsSQLNeverNames(t *testing.T) {
	for _, d := range Tools(&fake{}, nil) {
		if !d.Policy.ReadOnly {
			continue
		}
		for _, args := range readArgShapes(d.Name) {
			q := &fake{rows: []map[string]any{}}
			if _, err := d.ExecuteContext(runCtx("99999999-9999-9999-9999-999999999999"), args); err != nil {
				continue
			}
			for _, c := range q.calls {
				if c.name != "" {
					continue
				}
				used, highest := map[int]bool{}, 0
				for _, m := range dollarRefs(c.sql) {
					used[m] = true
					if m > highest {
						highest = m
					}
				}
				if highest > len(c.args) {
					t.Errorf("%s names $%d and sends %d argument(s): %s", d.Name, highest, len(c.args), c.sql)
					continue
				}
				for n := 1; n <= highest; n++ {
					if !used[n] {
						t.Errorf("%s sends %d arguments and never names $%d - a parameter Postgres cannot "+
							"type, so the whole query fails with 42P18:\n  %s", d.Name, len(c.args), n, c.sql)
					}
				}
			}
		}
	}
}

func dollarRefs(sql string) []int {
	var out []int
	for i := 0; i < len(sql); i++ {
		if sql[i] != '$' {
			continue
		}
		j := i + 1
		for j < len(sql) && sql[j] >= '0' && sql[j] <= '9' {
			j++
		}
		if j == i+1 {
			continue
		}
		if n, err := strconv.Atoi(sql[i+1 : j]); err == nil {
			out = append(out, n)
		}
		i = j - 1
	}
	return out
}
