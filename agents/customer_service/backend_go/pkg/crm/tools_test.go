package crm

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"

	"jada-backend/pkg/tools"
	"jada-backend/pkg/turn"
)

// TestMain quiets the package's logging: these tests exercise write paths, and each one logs its
// outcome by design, so without this the report buries its own failures in INFO lines.
func TestMain(m *testing.M) {
	slog.SetDefault(slog.New(slog.NewTextHandler(io.Discard, nil)))
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
		for _, d := range Tools(f) {
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
		for _, d := range Tools(f) {
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
	for _, d := range Tools(f) {
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
		for _, d := range Tools(f) {
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
	for _, d := range Tools(&fake{}) {
		props, _ := d.Parameters["properties"].(map[string]any)
		args := map[string]any{}
		for name := range props {
			args[name] = probeValue(name)
		}

		f := &fake{rows: nil}
		var def tools.ToolDefinition
		for _, c := range Tools(f) {
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
	for _, d := range Tools(f) {
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
	for _, d := range Tools(f) {
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
	for _, d := range Tools(f) {
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
	for _, d := range Tools(f) {
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
	for _, d := range Tools(f) {
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

func TestTimestampForms(t *testing.T) {
	f := &fake{rows: []map[string]any{{"success": true}}}
	call := func(v string) error {
		for _, d := range Tools(f) {
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
	for _, d := range Tools(&fake{}) {
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
