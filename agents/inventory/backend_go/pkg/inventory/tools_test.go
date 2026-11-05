package inventory

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"jada-backend/pkg/turn"
)

// fake is the whole database an inventory tool test needs: the calls it made, and the answers to
// give them, query by query, in order - because the interesting assertions here are about WHAT a
// tool asked and in which position, not about rows.
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
	itemA = "01a1a800-0000-7000-8000-00000000000a"
	whA   = "01a1a800-0000-7000-8000-00000000000b"
	ordA  = "01a1a800-0000-7000-8000-00000000000c"
)

func TestSurfaceAndPolicies(t *testing.T) {
	f := &fake{}
	want := map[string]bool{
		"get_low_stock_items":       true,
		"get_item_availability":     true,
		"get_item_movement_summary": true,
		"get_inventory_valuation":   true,
		"reserve_inventory":         false, // the one write, and the one the policy must say so on
	}
	got := Tools(f)
	if len(got) != len(want) {
		t.Fatalf("%d tools registered, README lists %d", len(got), len(want))
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
	}
}

// TestReserveSendsTheDoorsFullArityAndTheClaimLast is the position pin this family of tools lives
// by: the door's every-parameter DEFAULTed would turn a dropped slot into a different branch, not
// a type error - 4.4's ambiguity wearing an arity. Eight positions, the key in the eighth.
func TestReserveSendsTheDoorsFullArityAndTheClaimLast(t *testing.T) {
	f := &fake{callRows: []map[string]any{
		{"reservation_id": "x", "status": "SUCCESS", "message": "ok"},
	}}
	_, err := tool(t, f, "reserve_inventory")(runCtx("22222222-2222-2222-2222-222222222222"),
		map[string]any{
			"item_id": itemA, "warehouse_id": whA, "quantity": float64(4),
			"order_type": "sales", "order_id": ordA,
		})
	if err != nil {
		t.Fatalf("reserve: %v", err)
	}
	if len(f.calls) != 1 {
		t.Fatalf("%d calls, want the door called once", len(f.calls))
	}
	args := f.calls[0].args
	if len(args) != 8 {
		t.Fatalf("sent %d arguments, want exactly 8: the door's own signature length", len(args))
	}
	if args[3] != "SALES" {
		t.Errorf("order_type arrived as %v; the case fold belongs to the tool, the vocabulary to the door", args[3])
	}
	if args[6] != nil {
		t.Errorf("position 7 (location) should be NULL when unnamed, got %v", args[6])
	}
	k, ok := args[7].(string)
	if !ok || len(k) != 36 || k == strings.ToLower(itemA) {
		t.Errorf("the final argument should be a derived claim uuid, got %v", args[7])
	}

	// And the same call outside any run: no key, and no constant pretending to be one.
	f2 := &fake{callRows: f.callRows}
	if _, err := tool(t, f2, "reserve_inventory")(context.Background(), map[string]any{
		"item_id": itemA, "warehouse_id": whA, "quantity": float64(4),
		"order_type": "SALES", "order_id": ordA,
	}); err != nil {
		t.Fatalf("keyless reserve: %v", err)
	}
	if f2.calls[0].args[7] != nil {
		t.Errorf("a call with no run id sent a key anyway: %v", f2.calls[0].args[7])
	}
}

// TestReserveRefusalsAreArgumentsNotCalls: everything this tool can settle in Go - a malformed
// uuid, a zero quantity, a missing type - must settle WITHOUT reaching the door, so the error
// names the argument rather than a SQLSTATE from a function the model cannot see.
func TestReserveRefusalsAreArgumentsNotCalls(t *testing.T) {
	cases := []struct {
		name string
		args map[string]any
	}{
		{"malformed uuid", map[string]any{"item_id": "not-a-uuid", "warehouse_id": whA,
			"quantity": float64(4), "order_type": "SALES"}},
		{"zero quantity", map[string]any{"item_id": itemA, "warehouse_id": whA,
			"quantity": float64(0), "order_type": "SALES"}},
		{"no order type", map[string]any{"item_id": itemA, "warehouse_id": whA,
			"quantity": float64(4)}},
		{"no item", map[string]any{"warehouse_id": whA, "quantity": float64(4), "order_type": "SALES"}},
	}
	for _, tc := range cases {
		f := &fake{}
		if _, err := tool(t, f, "reserve_inventory")(runCtx("33333333-3333-3333-3333-333333333333"), tc.args); err == nil {
			t.Errorf("%s: accepted, and the door saw it too", tc.name)
		}
		if len(f.calls) != 0 {
			t.Errorf("%s: refused after the door was already called - the error would have arrived as a SQLSTATE", tc.name)
		}
	}
}

func TestReservePassesTheDoorsTwoStatusesThrough(t *testing.T) {
	f := &fake{callRows: []map[string]any{
		{"reservation_id": nil, "status": "INSUFFICIENT_STOCK", "message": "Only 2 available, requested 5"},
	}}
	out, err := tool(t, f, "reserve_inventory")(runCtx("44444444-4444-4444-4444-444444444444"),
		map[string]any{"item_id": itemA, "warehouse_id": whA, "quantity": float64(5),
			"order_type": "SALES", "order_id": ordA})
	if err != nil {
		t.Fatalf("a business refusal must not be a tool error: %v", err)
	}
	if !strings.Contains(out, "INSUFFICIENT_STOCK") || !strings.Contains(out, "Only 2 available") {
		t.Errorf("the door's own words must reach the reader, got %q", out)
	}

	// A third status is a contract change, and this file must say so rather than relay silence.
	f2 := &fake{callRows: []map[string]any{{"status": "ERROR", "message": "!"}}}
	if _, err := tool(t, f2, "reserve_inventory")(runCtx("55555555-5555-5555-5555-555555555555"),
		map[string]any{"item_id": itemA, "warehouse_id": whA, "quantity": float64(1),
			"order_type": "SALES", "order_id": ordA}); err == nil {
		t.Fatal("the door published a status outside its documented two, and the tool stayed silent")
	}
}

func TestLowStockAlertLevelIsTheViewsVerdictNotAnOpinion(t *testing.T) {
	f := &fake{}
	if _, err := tool(t, f, "get_low_stock_items")(context.Background(),
		map[string]any{"alert_level": "ALMOST-GONE"}); err == nil {
		t.Error("invented alert_level accepted; the list's other verdict is silence, and inventing one is the prompt's forbidden move")
	}
	if _, err := tool(t, f, "get_low_stock_items")(context.Background(),
		map[string]any{"alert_level": "critical"}); err != nil {
		t.Errorf("lowercase CRITICAL should case-fold, not fail: %v", err)
	}
	if !strings.Contains(f.calls[0].sql, "alert_level = $1") {
		t.Errorf("filter did not become a parameter: %s", f.calls[0].sql)
	}
	if f.calls[0].args[0] != "CRITICAL" {
		t.Errorf("bound %v, want the folded constant", f.calls[0].args[0])
	}
}

func TestEmptyResultsSayWhichSilenceTheyAre(t *testing.T) {
	f := &fake{}
	out, err := tool(t, f, "get_low_stock_items")(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "note") {
		t.Errorf("an empty shortage list must read as good news, not as a broken tool: %s", out)
	}
	var rows []map[string]any
	if err := json.Unmarshal([]byte(out), &rows); err != nil {
		t.Fatalf("not a JSON array: %v", err)
	}
}

func TestShortfallAndSupplyAreArithmeticWithAnUnknown(t *testing.T) {
	if s := shortfall(map[string]any{"quantity_available": 4.0, "reorder_point": 30.0}); s != 26.0 {
		t.Errorf("shortfall %v, want 26", s)
	}
	if s := shortfall(map[string]any{"quantity_available": 31.0, "reorder_point": 30.0}); s != nil {
		t.Errorf("above the point is no shortfall at all, got %v", s)
	}

	avail := 20.0
	rows := []map[string]any{{"total_outbound": 10.0}, {"total_outbound": 10.0}} // 20 over 30 days
	if d := daysOfSupply(rows, 30, &avail); d != 30.0 {
		t.Errorf("days_of_supply %v, want 30 (20 available, 20/30 per day)", d)
	}
	if d := daysOfSupply(nil, 30, &avail); d != nil {
		t.Errorf("no outbound history must be UNKNOWN, not infinite or zero: %v", d)
	}
	if d := daysOfSupply(rows, 30, nil); d != nil {
		t.Errorf("missing stock total must be UNKNOWN too: %v", d)
	}
}

func TestMovementSummaryResolvesSkuThroughViews(t *testing.T) {
	f := &fake{queryRows: [][]map[string]any{
		{{"item_id": itemA}},            // the sku lookup
		{{"movement_date": "d", "total_outbound": 4.0}}, // the history
		{{"avail": 20.0}},               // the availability sum
	}}
	out, err := tool(t, f, "get_item_movement_summary")(context.Background(), map[string]any{"sku": "IN-1000"})
	if err != nil {
		t.Fatalf("summary: %v", err)
	}
	for _, c := range f.calls {
		if strings.Contains(c.sql, "FROM inventory_items") || strings.Contains(c.sql, "FROM vw_low") {
			t.Errorf("a read reached for %q; views only: %s", c.sql, "the ADR-003 rule")
		}
	}
	// 20 available, 4/30 per day: a generous window, a finite answer.
	if !strings.Contains(out, "days_of_supply") {
		t.Errorf("no derived opinion in %s", out)
	}
}

func TestAgentNameResolvesOnceFromTheEnvironment(t *testing.T) {
	t.Setenv(EnvAgentRole, "stock_room")
	if AgentName() != "stock_room" {
		t.Errorf("AgentName %q, want the environment's claim", AgentName())
	}
	t.Setenv(EnvAgentRole, "")
	if AgentName() != DefaultAgentRole {
		t.Errorf("with AGENT_ROLE unset: %q, want %q", AgentName(), DefaultAgentRole)
	}
}

func TestUUIDShapeIsShapeOnly(t *testing.T) {
	if !isUUIDShape("01a1a800-0000-7000-8000-00000000000a") {
		t.Error("a real id must pass")
	}
	for _, bad := range []string{"", "0", itemA + "0", strings.Replace(itemA, "-", "", 1), "z1a1a800-0000-7000-8000-00000000000a"} {
		if isUUIDShape(bad) {
			t.Errorf("%q is not uuid-shaped", bad)
		}
	}
}

func TestErrorWrappingStaysHonest(t *testing.T) {
	// The door failing with a database error propagates verbatim - the tool adds no verdict word
	// the schema did not write.
	sentinel := errors.New("40001 claim leased elsewhere")
	f := &fake{err: sentinel}
	if _, err := tool(t, f, "reserve_inventory")(runCtx("66666666-6666-6666-6666-666666666666"),
		map[string]any{"item_id": itemA, "warehouse_id": whA, "quantity": float64(1),
			"order_type": "SALES", "order_id": ordA}); !errors.Is(err, sentinel) {
		t.Errorf("the SQLSTATE's message was replaced, not wrapped: %v", err)
	}
}
