package orders

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"fmt"
	"jada-backend/pkg/turn"
	"sort"
	"strconv"
)

// fake is the whole database an order tool test needs: the calls it made, and the answers to give
// them, in order - because the interesting assertions here are about WHAT a tool asked the door and
// in which position, not about rows.
type fake struct {
	calls     []fakeCall
	queryRows [][]map[string]any
	qi        int
	callRows  []map[string]any
	err       error
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
	if f.qi < len(f.queryRows) {
		rows := f.queryRows[f.qi]
		f.qi++
		return rows, nil
	}
	return nil, nil
}

func (f *fake) Call(_ context.Context, name string, args []any) ([]map[string]any, error) {
	f.calls = append(f.calls, fakeCall{name: name, args: args})
	if f.err != nil {
		return nil, f.err
	}
	return f.callRows, nil
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

func tool(t *testing.T, f *fake, name string) func(context.Context, map[string]any) (string, error) {
	t.Helper()
	for _, d := range Tools(f) {
		if d.Name == name {
			return d.ExecuteContext
		}
	}
	t.Fatalf("tool %q is not registered", name)
	return nil
}

const (
	orderA  = "01a1a800-0000-7000-8000-00000000000a"
	lineA   = "01a1a800-0000-7000-8000-00000000000b"
	supA    = "01a1a800-0000-7000-8000-00000000000c"
	itemA   = "01a1a800-0000-7000-8000-00000000000d"
	whA     = "01a1a800-0000-7000-8000-00000000000e"
	reservA = "01a1a800-0000-7000-8000-00000000000f"
	runA    = "22222222-2222-2222-2222-222222222222"
)

// okRow is the shape every door answers with: success, its own keys, and a message. The keys differ
// per door, which is the point of asserting the positions rather than the payload.
func okRow() []map[string]any {
	return []map[string]any{{
		"success": true, "order_id": orderA, "order_line_id": lineA, "supplier_id": supA,
		"reservation_id": reservA, "order_number": "SO-000001", "line_number": 1,
		"status": "SUCCESS", "message": "done",
	}}
}

func TestSurfaceAndPolicies(t *testing.T) {
	f := &fake{}
	want := map[string]bool{
		"get_orders":            true,
		"get_order_lines":       true,
		"get_order_commitments": true,
		"get_customers":         true,
		"get_suppliers":         true,
		// The seven doors. A write whose ReadOnly lies is a write that skips the approval gate, so
		// this map is the policy table as well as the tool list: the README's table and this one are
		// the same twelve names, and check_agent_docs.sh fails the build when they stop being.
		"create_order":                 false,
		"add_order_line":               false,
		"transition_order":             false,
		"add_supplier":                 false,
		"ship_sales_order":             false,
		"receive_purchase_order":       false,
		"cancel_inventory_reservation": false,
	}
	got := Tools(f)
	if len(got) != len(want) {
		t.Fatalf("%d tools registered, this test and the README list %d", len(got), len(want))
	}
	for _, d := range got {
		ro, named := want[d.Name]
		if !named {
			t.Errorf("unexpected tool %q", d.Name)
			continue
		}
		if d.Policy.ReadOnly != ro {
			t.Errorf("%s: ReadOnly=%v, want %v", d.Name, d.Policy.ReadOnly, ro)
		}
		if ro && d.Policy.RequiresApproval {
			t.Errorf("%s: a read that requires approval means the gate is keyed on the wrong fact", d.Name)
		}
	}
}

// TestEveryDoorSendsItsFullArityAndTheClaimLast is the position pin this family of tools lives by.
//
// Every parameter on every one of these doors is DEFAULTed, which is 0016's shape, and that is
// precisely why the arity matters: a slot dropped in the middle is not a type error and not a
// missing-parameter error, it is the next argument sliding left, and the value that lands in the
// wrong column is the idempotency key. A reservation whose claim is a warehouse uuid is a write that
// is guarded by nothing and reports success.
//
// The counts are the database's, read out of pg_proc on 2026-11-07, and a migration that appends a
// parameter has to edit this table in the same commit - which is the failure mode worth having: a
// test that fails because a door grew is a test telling the truth about the two halves having drifted.
func TestEveryDoorSendsItsFullArityAndTheClaimLast(t *testing.T) {
	cases := []struct {
		tool string
		door string
		args map[string]any
		argc int
	}{
		{"create_order", "create_order", map[string]any{
			"order_type": "sales", "customer_id": float64(7), "warehouse_id": whA,
		}, 10},
		{"add_order_line", "add_order_line", map[string]any{
			"order_id": orderA, "item_id": itemA, "quantity": float64(2), "unit_price": 9.75,
		}, 12},
		{"transition_order", "transition_order", map[string]any{
			"order_id": orderA, "to_status": "confirmed", "expected_version": float64(3),
		}, 5},
		{"add_supplier", "add_supplier", map[string]any{
			"supplier_code": "SUP-9", "name": "A Vendor", "lead_time_days": float64(14),
		}, 10},
		{"ship_sales_order", "ship_sales_order", map[string]any{"order_id": orderA}, 4},
		{"receive_purchase_order", "receive_purchase_order", map[string]any{"order_id": orderA}, 4},
		{"cancel_inventory_reservation", "cancel_inventory_reservation", map[string]any{
			"reservation_id": reservA, "quantity": float64(1),
		}, 5},
	}
	for _, c := range cases {
		f := &fake{callRows: okRow()}
		if _, err := tool(t, f, c.tool)(runCtx(runA), c.args); err != nil {
			t.Fatalf("%s: %v", c.tool, err)
		}
		if len(f.calls) != 1 || f.calls[0].name != c.door {
			t.Fatalf("%s: made %d calls, want one named %s", c.tool, len(f.calls), c.door)
		}
		got := f.calls[0].args
		if len(got) != c.argc {
			t.Errorf("%s sent %d positional arguments, the door declares %d - one slot dropped "+
				"and every argument after it is in the wrong column", c.tool, len(got), c.argc)
			continue
		}
		// The last slot is the claim, and the second-to-last is a door parameter, for every one of
		// these doors: append(key(...)) rather than key(...), nil is the "no run id" path and still
		// the right shape.
		// The same slot, read as a policy question: this test has just proved the tool SENT a claim,
		// so Policy.Claims must say so, because that field is what /api/tools answers "can this be
		// retried safely" with. It used to be derived from the tool's NAME by a pair of HasPrefix
		// calls, which for this fork meant seven of its eight writers were reported as unguarded
		// retries while the code appended a key to every one of them.
		for _, d := range Tools(f) {
			if d.Name == c.tool && !d.Policy.Claims {
				t.Errorf("%s: sent a claim in position %d and its Policy says it does not, so the "+
					"endpoint contradicts the argument list", c.tool, len(got))
			}
		}
		switch k := got[len(got)-1].(type) {
		case string:
			if len(k) != 36 {
				t.Errorf("%s: the last argument is %q, not a claim key", c.tool, k)
			}
		case nil:
			t.Errorf("%s: sent no claim key from a context that carries a run id", c.tool)
		default:
			t.Errorf("%s: the last argument is %T, not a claim key", c.tool, k)
		}
	}
}

// TestClaimsAreAbsentWithoutARun is the other half of the rule: an unattributed call must not share a
// constant uuid with every other unattributed call, so a run-less call sends NULL and runs unguarded.
func TestClaimsAreAbsentWithoutARun(t *testing.T) {
	f := &fake{callRows: okRow()}
	if _, err := tool(t, f, "create_order")(runCtx(""), map[string]any{"order_type": "SALES"}); err != nil {
		t.Fatalf("create_order: %v", err)
	}
	got := f.calls[0].args
	if got[len(got)-1] != nil {
		t.Errorf("with no run id the claim slot carries %v; it must be NULL, not a value two calls "+
			"could share, because a shared claim makes the second order answer with the first's id",
			got[len(got)-1])
	}
}

func TestWritesRefuseBadArgumentsBeforeCalling(t *testing.T) {
	cases := []struct {
		tool string
		args map[string]any
		want string
	}{
		{"create_order", map[string]any{}, "order_type"},
		{"create_order", map[string]any{"order_type": "quote"}, "SALES, PURCHASE or WORK"},
		{"add_order_line", map[string]any{"quantity": 1, "unit_price": 1}, "order_id"},
		{"add_order_line", map[string]any{"order_id": orderA, "quantity": 1, "unit_price": 1},
			"item_id or description"},
		{"add_order_line", map[string]any{"order_id": "not-a-uuid", "item_id": itemA,
			"quantity": 1, "unit_price": 1}, "not a uuid"},
		{"transition_order", map[string]any{"to_status": "SHIPPED"}, "order_id"},
		{"ship_sales_order", map[string]any{}, "order_id"},
		{"receive_purchase_order", map[string]any{"order_id": "1234"}, "not a uuid"},
		{"cancel_inventory_reservation", map[string]any{"quantity": 2}, "reservation_id"},
	}
	for _, c := range cases {
		f := &fake{callRows: okRow()}
		_, err := tool(t, f, c.tool)(runCtx(runA), c.args)
		if err == nil {
			t.Errorf("%s(%v) was accepted; it should refuse before the door is called", c.tool, c.args)
			continue
		}
		if !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: error %q does not name %q", c.tool, err.Error(), c.want)
		}
		if len(f.calls) != 0 {
			t.Errorf("%s refused and then called %s anyway - the refusal is the point, the call is "+
				"the side effect", c.tool, f.calls[0].name)
		}
	}
}

// TestDoorRefusalsComeBackAsData pins the rule the requirements page states: a door that says no
// answers with a row, and the row is what the model reads. An error here would be a retry, and the
// retry would be answered from the claim, which is a refusal loop with a green health endpoint.
func TestDoorRefusalsComeBackAsData(t *testing.T) {
	f := &fake{callRows: []map[string]any{{
		"success": false, "order_id": nil, "message": "order 01a1 is DRAFT; CONFIRMED requires SUBMITTED",
	}}}
	out, err := tool(t, f, "transition_order")(runCtx(runA), map[string]any{
		"order_id": orderA, "to_status": "CONFIRMED",
	})
	if err != nil {
		t.Fatalf("a refusal is an answer, not an error: %v", err)
	}
	var row map[string]any
	if err := json.Unmarshal([]byte(out), &row); err != nil {
		t.Fatalf("the refusal did not come back as the door's row: %v / %s", err, out)
	}
	if ok, _ := row["success"].(bool); ok {
		t.Error("success=true on a row the door raised false on")
	}
	if !strings.Contains(row["message"].(string), "SUBMITTED") {
		t.Error("the door's own words were rewritten; they are written for whoever reads them next")
	}
}

func TestAnEmptyListSaysWhichSilenceItIs(t *testing.T) {
	for _, name := range []string{"get_orders", "get_order_lines", "get_order_commitments"} {
		f := &fake{queryRows: [][]map[string]any{{}}}
		out, err := tool(t, f, name)(runCtx(runA), map[string]any{})
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if !strings.Contains(out, "note") {
			t.Errorf("%s returned a bare empty list: %s", name, out)
		}
	}
}

func TestReadsBindTheirFiltersAndCapRows(t *testing.T) {
	f := &fake{queryRows: [][]map[string]any{{}}}
	if _, err := tool(t, f, "get_orders")(runCtx(runA), map[string]any{
		"order_type": "purchase", "status": "confirmed", "due_before": "2026-12-01",
		"vendor_id": supA, "open_only": true, "limit": float64(50),
	}); err != nil {
		t.Fatalf("get_orders: %v", err)
	}
	c := f.calls[0]
	if strings.Contains(c.sql, ";") || !strings.Contains(c.sql, "$1") {
		t.Errorf("the read is not a parameterised statement: %s", c.sql)
	}
	// Every filter value is a bind parameter and none of it is text in the statement: this is the one
	// place in the package where a value reaches SQL at all, and it is how a name with a quote in it
	// stays a name.
	for _, a := range c.args {
		if s, ok := a.(string); ok && (strings.Contains(s, "'") || strings.Contains(s, "%purchase%")) {
			t.Errorf("a filter value reached the statement as text: %q", s)
		}
	}
	if last, _ := c.args[len(c.args)-1].(int); last != 50 {
		t.Errorf("the limit reached the statement as %v, want 50 - the cap belongs in the SQL, not in "+
			"whatever the view decides to answer", last)
	}

	// A limit outside the cap is refused rather than silently clamped, which is the rule the inherited
	// helper states and 0015 argues for: the caller asked for something this tool will not do, and
	// answering a different question than the one asked is how a report starts disagreeing with the
	// person who read it.
	f2 := &fake{queryRows: [][]map[string]any{{}}}
	_, err := tool(t, f2, "get_orders")(runCtx(runA), map[string]any{"limit": float64(5000)})
	if err == nil {
		t.Fatal("limit=5000 was accepted; the cap is a stated limit and not a suggestion")
	}
	if !strings.Contains(err.Error(), "between 1 and 200") {
		t.Fatalf("the refusal does not name the range the tool told the model about: %v", err)
	}
	if len(f2.calls) != 0 {
		t.Error("a refused limit still reached the database")
	}
}

func TestDatesThatWouldBeGuessedAreRefused(t *testing.T) {
	f := &fake{callRows: okRow()}
	for _, bad := range []string{"next friday", "2026-13-01", "12/01/2026"} {
		_, err := tool(t, f, "create_order")(runCtx(runA), map[string]any{
			"order_type": "SALES", "customer_id": float64(7), "required_date": bad,
		})
		if err == nil || !strings.Contains(err.Error(), "ISO date") {
			t.Errorf("required_date %q was accepted with %v; a date PostgreSQL has to guess the field "+
				"order of is a delivery promise made on a coin flip", bad, err)
		}
	}
	if len(f.calls) != 0 {
		t.Errorf("three refused dates still reached the door %d time(s)", len(f.calls))
	}
}

// TestNumbersReachTheDoorAsDecimals guards the one conversion in this package that can change what a
// line says: a float that arrives as 12.500000000000001 is a unit price the caller did not type, and
// the door's numeric(18,4) will hold it happily.
func TestNumbersReachTheDoorAsDecimals(t *testing.T) {
	f := &fake{callRows: okRow()}
	if _, err := tool(t, f, "add_order_line")(runCtx(runA), map[string]any{
		"order_id": orderA, "item_id": itemA, "quantity": 0.1, "unit_price": 1234.5678,
	}); err != nil {
		t.Fatalf("add_order_line: %v", err)
	}
	args := f.calls[0].args
	for _, i := range []int{3, 4} {
		s, ok := args[i].(string)
		if !ok {
			t.Fatalf("argument %d reached the door as %T, want decimal text", i, args[i])
		}
		if strings.Contains(s, "0000000") {
			t.Errorf("argument %d is %q: the decoder's error, forwarded as a price", i, s)
		}
	}
}

func TestAgentNameResolvesOnceFromTheEnvironment(t *testing.T) {
	t.Setenv(EnvAgentRole, "")
	if got := AgentName(); got != DefaultAgentRole {
		t.Errorf("unset AGENT_ROLE gives %q, the documented default is %q", got, DefaultAgentRole)
	}
	t.Setenv(EnvAgentRole, "sales_desk")
	if got := AgentName(); got != "sales_desk" {
		t.Errorf("AGENT_ROLE=sales_desk gives %q", got)
	}
	if DefaultAgentRole != "sales" {
		t.Errorf("DefaultAgentRole is %q, and agents/sales/docker-compose.yml sets AGENT_ROLE=sales - "+
			"the two must agree or a deployment without the variable writes a different identity",
			DefaultAgentRole)
	}
}

// TestDomainToolNamesMatchTheRegistry is the assertion behind /api/health's order_tools count.
//
// The count is reported because a duplicate name silently displacing a tool at startup is otherwise
// invisible, and it is computed from a list of names in this package rather than from the registration
// itself. That list is therefore a second statement of the surface, and the forks this file came from
// show what that costs: a prefix list that read plausibly counted eleven of twelve and never once
// noticed a tool go missing. Both directions are checked, so a tool added to Tools() without its name
// added here fails here rather than in a health endpoint that looks healthy.
func TestDomainToolNamesMatchTheRegistry(t *testing.T) {
	f := &fake{}
	got := map[string]bool{}
	for _, d := range Tools(f) {
		got[d.Name] = true
		if !IsDomainTool(d.Name) {
			t.Errorf("%s is registered and IsDomainTool does not know it: /api/health would undercount "+
				"the surface it is reporting on", d.Name)
		}
	}
	for _, n := range domainToolNames {
		if !got[n] {
			t.Errorf("IsDomainTool names %q and Tools() does not register it - the health endpoint's "+
				"number would include a tool that is not there", n)
		}
	}
	if len(domainToolNames) != len(got) {
		t.Errorf("%d names in domainToolNames, %d tools registered", len(domainToolNames), len(got))
	}
}

// TestNoToolComposesBusinessSQL is the cheap form of the ADR-002 rule the coverage script also
// watches: reads are SELECTs over vw_* views, writes are Call to a named function. A hand-written
// INSERT here would put a rule the database cannot enforce in a process that can be redeployed away.
func TestNoToolComposesBusinessSQL(t *testing.T) {
	f := &fake{}
	for _, d := range Tools(f) {
		for _, banned := range []string{"INSERT ", "UPDATE ", "DELETE ", "MERGE "} {
			if strings.Contains(strings.ToUpper(d.Description), banned) &&
				strings.Contains(banned, "INSERT") {
				t.Errorf("%s: its own description tells the model to %q, which is not this package's "+
					"job to arrange", d.Name, banned)
			}
		}
	}
	q := &fake{queryRows: [][]map[string]any{{}}, callRows: okRow()}
	ctx := runCtx(runA)
	for _, d := range Tools(q) {
		if _, err := d.ExecuteContext(ctx, map[string]any{
			"order_id": orderA, "order_type": "SALES", "reservation_id": reservA,
			"supplier_code": "S1", "item_id": itemA, "quantity": float64(1), "unit_price": float64(1),
			"to_status": "CONFIRMED", "customer_id": float64(1),
		}); err != nil && !errors.Is(err, q.err) {
			continue
		}
		for _, c := range q.calls {
			up := strings.ToUpper(strings.Join(strings.Fields(c.sql), " "))
			if c.name == "" && !strings.Contains(up, " FROM VW_") {
				t.Errorf("%s ran a read that names no view: %s", d.Name, c.sql)
			}
		}
		q.calls = nil
	}
}

// TestNoQuerySendsAParameterItsSQLNeverNames is the property the first day of this agent needed and
// did not have. Its reads build a WHERE clause per argument the model passed, and the builder pushed
// a value for every clause - including the five that carry no placeholder at all (`is_active`,
// `quantity_open > 0`, `ledger_agreement = 'DISAGREES'`, `is_terminal IS NOT TRUE`,
// `quantity_unresolved > 0`). The SQL never mentions the position that orphan lands in, Postgres
// cannot infer a type for a parameter it cannot see, and refuses the whole query. So asking for a
// filter was not asking for fewer rows: it was a 42P18, and the tool that failed most was the one
// whose clause is added on the DEFAULT path - get_suppliers refused 20 of its 28 calls on this
// server on 2026-11-07, which is how a create_order case died several steps short of its own write,
// having been told that the supplier the previous case registered does not exist.
//
// A property rather than five cases, because the defect was in the shared builder and not in the
// call sites; the mirror (a `$n` with no argument) is asserted with it, which is the half that the
// LIMIT's position math gets wrong when a clause stops contributing an argument.
func TestNoQuerySendsAParameterItsSQLNeverNames(t *testing.T) {
	cases := []struct {
		tool string
		args []map[string]any
	}{
		// Every optional filter one at a time, then together: the combinations are where a clause's
		// position shifts out of step with the vector, and a builder that is only correct with its
		// filters empty is precisely the bug this test was written for.
		{"get_orders", []map[string]any{
			{},
			{"open_only": true}, {"open_only": false},
			{"order_type": "SALES"}, {"order_type": "PURCHASE", "open_only": true},
			{"order_number": "SO-000001"}, {"order_number": "SO-000001", "open_only": true},
			{"status": "DRAFT", "open_only": true},
			{"customer_id": float64(3), "vendor_id": supA, "warehouse_id": whA},
			{"due_before": "2026-12-31", "open_only": true},
			{"limit": 3}, {"open_only": true, "limit": 3},
		}},
		{"get_order_lines", []map[string]any{
			{}, {"unfulfilled_only": true}, {"unfulfilled_only": false},
			{"order_id": orderA}, {"order_id": orderA, "unfulfilled_only": true},
			{"order_number": "SO-000001", "unfulfilled_only": true},
			{"line_type": "STANDARD", "unfulfilled_only": true}, {"limit": 5},
		}},
		{"get_order_commitments", []map[string]any{
			{}, {"only_disagreements": true}, {"only_held": true},
			{"only_disagreements": true, "only_held": true},
			{"order_id": orderA, "only_held": true, "limit": 7},
			{"order_number": "SO-000001", "only_disagreements": true}, {"limit": 5},
		}},
		{"get_suppliers", []map[string]any{
			{}, {"include_inactive": true}, {"include_inactive": false},
			{"name": "Steel"}, {"supplier_code": "S1"},
			{"supplier_code": "S1", "include_inactive": true},
			{"name": "Steel", "include_inactive": false, "limit": 5},
		}},
		{"get_customers", []map[string]any{
			{}, {"name": "Jane"}, {"customer_id": float64(3)}, {"name": "Jane", "limit": 5},
		}},
	}

	for _, tc := range cases {
		for _, args := range tc.args {
			q := &fake{queryRows: [][]map[string]any{{}}}
			if _, err := tool(t, q, tc.tool)(runCtx(runA), args); err != nil {
				continue // refused on its own arguments: there is no query to inspect
			}
			for _, c := range q.calls {
				if c.name != "" {
					continue // a door call is positional, and every door's arity is pinned above
				}
				used := map[int]bool{}
				highest := 0
				for _, m := range dollarRefs(c.sql) {
					used[m] = true
					if m > highest {
						highest = m
					}
				}
				if highest > len(c.args) {
					t.Errorf("%s%v names $%d and sends %d argument(s): %s",
						tc.tool, showArgs(args), highest, len(c.args), c.sql)
					continue
				}
				for n := 1; n <= highest; n++ {
					if !used[n] {
						t.Errorf("%s%v sends %d arguments and never names $%d in its SQL - a parameter "+
							"Postgres cannot type, so the whole query fails with 42P18:\\n  %s",
							tc.tool, showArgs(args), len(c.args), n, c.sql)
					}
				}
			}
		}
	}
}

// dollarRefs returns the parameter positions a query names. Scanned rather than matched: these
// queries are built in this package, so a `$` is always a parameter and never a literal.
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

// showArgs prints the arguments in a fixed order, so a failing line names the combination to re-run
// rather than a Go map whose iteration order changes between two runs of the same test.
func showArgs(m map[string]any) string {
	if len(m) == 0 {
		return " with no arguments"
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%v", k, m[k]))
	}
	return " with " + strings.Join(parts, " ")
}

// TestClauseForIsTheRuleTheBuilderNeeded keeps the helper's contract in one place, including the two
// shapes a future filter is likely to add: a placeholder at the end of an expression, and a
// condition with nothing to bind at all.
func TestClauseForIsTheRuleTheBuilderNeeded(t *testing.T) {
	for _, tc := range []struct {
		frag string
		n    int
		sql  string
		took bool
	}{
		{"supplier_code = ?", 2, "supplier_code = $2", true},
		{"name ILIKE ?", 10, "name ILIKE $10", true},
		{"is_active", 3, "is_active", false},
		{"quantity_open > 0", 1, "quantity_open > 0", false},
		{"ledger_agreement = 'DISAGREES'", 4, "ledger_agreement = 'DISAGREES'", false},
	} {
		sql, took := clauseFor(tc.frag, tc.n)
		if sql != tc.sql || took != tc.took {
			t.Errorf("clauseFor(%q, %d) = (%q, %v), want (%q, %v)",
				tc.frag, tc.n, sql, took, tc.sql, tc.took)
		}
	}
}

// TestEveryDoorKeyIsReadableFromARead is the property whose absence this server measured, in two
// shapes at once. A door takes a uuid, and a uuid is only usable if some read can return it: otherwise
// the capability is real in SQL and unreachable in conversation, which is the exact difference between
// an agent and a schema. The first run of acceptance case 25 died here - the agent looked up its
// warehouse in get_orders, found a name and no id, said so in its own sentence, and raised nothing.
//
// So: every `*_id` a door's parameters name has to appear in the SELECT list of at least one read in
// this package. The check is on the SQL the tools build, not on a list in a comment, and the one column
// that does not satisfy it is named here with its open item rather than left out - a documented gap
// that stays visible is worth more than an assertion that quietly drops the case.
func TestEveryDoorKeyIsReadableFromARead(t *testing.T) {
	q := &fake{queryRows: [][]map[string]any{{}}}
	writable := map[string]bool{}
	for _, d := range Tools(q) {
		ctx := runCtx("77777777-7777-7777-7777-777777777777")
		// The reads need no arguments to reveal their columns; the writes are inspected for what they
		// ask for, and are not executed here.
		if !d.Policy.ReadOnly {
			continue
		}
		if _, err := d.ExecuteContext(ctx, map[string]any{"limit": 1}); err != nil {
			continue
		}
		for _, c := range q.calls {
			for _, col := range selectedColumns(c.sql) {
				writable[col] = true
			}
		}
		q.calls = nil
	}
	if len(writable) == 0 {
		t.Fatal("no read in this package sent a query the test could inspect")
	}

	// Each key a door takes, and where the value is meant to come from.
	wanted := map[string]string{
		"order_id":      "get_orders / get_order_lines",
		"order_line_id": "get_order_lines",
		"customer_id":   "get_customers",
		"supplier_id":   "get_suppliers",
		"warehouse_id":  "get_orders / get_order_lines",
		"item_id":       "get_order_lines (this agent registers no item master by design)",
	}
	for col, source := range wanted {
		if !writable[col] {
			t.Errorf("%s is a key some door takes and no read here returns, so the door is reachable by "+
				"SQL and not by conversation. It should come from: %s", col, source)
		}
	}

	// And the gap, pinned by asserting its absence: `vw_order_commitments` has no reservation_id, and
	// no view in the schema has one, so cancel_inventory_reservation's required argument cannot be
	// discovered by any agent - the acceptance case that exercises it takes the id from a fixture for
	// that reason. The day a migration puts the column in a view, this fails, and the right response is
	// to move reservation_id into the map above and close the PLAN item, not to delete this check.
	if writable["reservation_id"] {
		t.Error("a read now returns reservation_id: cancel_inventory_reservation has stopped being a door " +
			"whose key nobody can find, so move it to the wanted map above and retire this assertion")
	}
}

// selectedColumns pulls the projection out of a SELECT this package built. Only the top-level list
// matters, and none of these queries has a subselect: the shape is "SELECT a, b FROM x WHERE ...".
func selectedColumns(sql string) []string {
	up := strings.Join(strings.Fields(sql), " ")
	i := strings.Index(up, "SELECT ")
	j := strings.Index(up[i:], " FROM ")
	if i < 0 || j <= 0 {
		return nil
	}
	list := up[i+len("SELECT ") : i+j]
	var out []string
	for _, part := range strings.Split(list, ",") {
		part = strings.TrimSpace(part)
		if k := strings.LastIndex(part, " AS "); k >= 0 {
			part = part[k+4:]
		}
		if dot := strings.LastIndex(part, "."); dot >= 0 {
			part = part[dot+1:]
		}
		if part != "" && part != "*" {
			out = append(out, strings.ToLower(part))
		}
	}
	return out
}
