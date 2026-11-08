package orders

import (
	"context"
	"errors"
	"strings"
	"testing"

	"encoding/json"
	"fmt"
	"jada-backend/pkg/logging"
)

// What a tick is: two jobs, one sentence, and a trajectory row. These three cases test the sentence
// and the sequencing, because both had a defect the deployment found on its own - see
// TestATickStillReconcilesWhenTheSweepFails.
//
// There is no model here, so nothing is stochastic and everything is assertable; what there IS is a
// schedule that runs when nobody is watching, which is exactly the kind of code a test earns.

// tickDB answers the three statements one tick sends, with each half's outcome chosen independently.
// The package's shared `fake` gives one error for every call, and the whole point of these cases is
// what happens when exactly ONE half fails.
type tickDB struct {
	sweepErr  error
	sweepRows []map[string]any
	lines     []map[string]any
	lineErr   error
	calls     []string
}

func (t *tickDB) Query(_ context.Context, sql string, _ ...any) ([]map[string]any, error) {
	t.calls = append(t.calls, "scan")
	if t.lineErr != nil {
		return nil, t.lineErr
	}
	return t.lines, nil
}

func (t *tickDB) Call(_ context.Context, name string, _ []any) ([]map[string]any, error) {
	t.calls = append(t.calls, name)
	switch name {
	case "idempotency_sweep":
		return t.sweepRows, t.sweepErr
	default:
		// get_memory. Answered with an error on purpose: memory.Save falls back to a FILE store when
		// no database client is configured, and a test that reached it would write into the working
		// tree. The memory half is not what any case here asserts.
		return nil, errors.New("no memory client in this test")
	}
}

func disagreeRow(order, item string, line int) map[string]any {
	return map[string]any{
		"order_number": order, "order_type": "PURCHASE", "line_number": line,
		"item_name": item, "quantity": float64(10), "quantity_fulfilled": float64(4),
		"quantity_committed": float64(0), "quantity_unresolved": float64(0),
		"quantity_committed_unlinked": float64(0), "ledger_quantity": float64(9),
		"ledger_agreement": "DISAGREES", "order_id": orderA, "order_line_id": lineA,
	}
}

func openRow(order, item string, line int) map[string]any {
	return map[string]any{
		"order_number": order, "order_type": "PURCHASE", "line_number": line,
		"item_name": item, "quantity": float64(2), "quantity_fulfilled": float64(0),
		"quantity_committed": float64(2), "quantity_unresolved": float64(2),
		"quantity_committed_unlinked": float64(2), "ledger_quantity": float64(0),
		"ledger_agreement": "nothing moved yet", "order_id": orderA, "order_line_id": lineA,
	}
}

func TestDescribeSaysAFailedSweepFailed(t *testing.T) {
	broken := describe(&HousekeepingResult{
		SweepFailure: "ERROR: permission denied for function idempotency_sweep (SQLSTATE 42501)",
		LinesChecked: 4,
	})
	if !strings.Contains(broken, "CLAIM SWEEP FAILED") || !strings.Contains(broken, "42501") {
		t.Errorf("a tick whose sweep was refused reads as an ordinary zero:\n  %s", broken)
	}
	if strings.Contains(broken, "claims swept: 0 expired collected") {
		t.Errorf("the healthy clause survived into the failure sentence, so the two are still confusable:\n  %s", broken)
	}

	healthy := describe(&HousekeepingResult{ClaimsCollected: 3, LinesChecked: 4})
	if !strings.Contains(healthy, "claims swept: 3 expired collected") {
		t.Errorf("a clean tick no longer says what it collected:\n  %s", healthy)
	}
	if strings.Contains(healthy, "FAILED") {
		t.Errorf("a clean tick announces a failure:\n  %s", healthy)
	}

	// The claim the whole test exists for, stated once directly: the two sentences must not be
	// the same sentence, because on this server they were, and the difference between them is
	// whether retention was enforced for the hour.
	if broken == healthy {
		t.Error("a failed sweep and a successful one render identically")
	}

	// An unmigrated or empty database says so, and does not imply that lines were reconciled.
	if empty := describe(&HousekeepingResult{}); !strings.Contains(empty, "no order lines exist") {
		t.Errorf("zero lines should name itself as zero lines, not as a clean sweep of nothing:\n  %s", empty)
	}
}

func TestATickStillReconcilesWhenTheSweepFails(t *testing.T) {
	q := &tickDB{
		sweepErr: errors.New("ERROR: permission denied for function idempotency_sweep (SQLSTATE 42501)"),
		lines:    []map[string]any{disagreeRow("PO-000042", "Steel Sheet", 1), openRow("PO-000042", "Calibration", 2)},
	}
	res, err := RunHousekeeping(context.Background(), q, logging.NewRecorder(nil, false), "test-model")
	if err == nil {
		t.Fatal("a tick whose sweep was refused reported success: the failure would reach neither " +
			"vw_failed_interactions nor the log")
	}
	if res.LinesChecked != 2 || len(res.Disagreements) != 1 {
		t.Errorf("the reconciliation did not run because the sweep failed: lines=%d disagreements=%d "+
			"(a broken retention policy must not silence the alarm that has nothing to do with it)",
			res.LinesChecked, len(res.Disagreements))
	}
	var sawScan bool
	for _, c := range q.calls {
		if c == "scan" {
			sawScan = true
		}
	}
	if !sawScan {
		t.Errorf("the tick never reached the view; calls were %v", q.calls)
	}
	s := describe(res)
	for _, want := range []string{"CLAIM SWEEP FAILED", "DISAGREE", "PO-000042"} {
		if !strings.Contains(s, want) {
			t.Errorf("the tick's sentence is missing %q: %s", want, s)
		}
	}
}

func TestATickWithAFailedScanFilesNoCleanFinding(t *testing.T) {
	q := &tickDB{
		sweepRows: []map[string]any{{"idempotency_sweep": int64(2)}},
		lineErr:   errors.New("relation vw_order_commitments does not exist"),
	}
	res, err := RunHousekeeping(context.Background(), q, logging.NewRecorder(nil, false), "test-model")
	if err == nil {
		t.Fatal("a tick that could not read the view reported success")
	}
	if res.ClaimsCollected != 2 {
		t.Errorf("the sweep's own answer was lost when the scan failed: %d", res.ClaimsCollected)
	}
	for _, c := range q.calls {
		if c == "save_memory" {
			t.Error("the tick stored a zero-line finding after a failed scan: last week's real " +
				"finding is now overwritten by a sentence that reads clean")
		}
	}
	if res.SweepFailure != "" {
		t.Errorf("a working sweep is recorded as failed: %s", res.SweepFailure)
	}
}

func TestOneLineKeepsTheSentenceQueryable(t *testing.T) {
	got := oneLine(errors.New("ERROR:  permission denied\nDETAIL:  more"))
	if strings.ContainsAny(got, "\n") {
		t.Errorf("oneLine left a newline in a column that is read with SELECT left(...): %q", got)
	}
	if !strings.Contains(got, "permission denied") {
		t.Errorf("oneLine lost the reason: %q", got)
	}
}

// TestIntArgReadsEveryIntegerTheDriverSends is the second half of the same discovery. The sweep's
// count is the one number in the tick's sentence that is not a row scan, and `idempotency_sweep`
// RETURNS integer - int4 - which pgx hands to Go as an int32. The parser switched on int64, int and
// float64, so a sweep that collected eleven claims reported zero, in the column whose whole purpose
// is to distinguish "nothing expired" from "the sweep did not run".
func TestIntArgReadsEveryIntegerTheDriverSends(t *testing.T) {
	rows := []map[string]any{
		{"idempotency_sweep": int32(11)}, // integer, which is the live one
		{"idempotency_sweep": int64(11)}, // bigint
		{"idempotency_sweep": int16(11)}, // smallint
		{"idempotency_sweep": 11},        // int, the shape a hand-built row takes
		{"idempotency_sweep": float64(11)},
		{"idempotency_sweep": float32(11)},
		{"count": int32(11)}, // column name irrelevant: this reads whatever the function answered
		{"idempotency_sweep": json.Number("11")},
	}
	for i, r := range rows {
		if got := intArg([]map[string]any{r}); got != 11 {
			t.Errorf("case %d (%T): intArg = %d, want 11 - a driver type this parser does not read",
				i, r[valueKey(r)], got)
		}
	}
	if got := intArg([]map[string]any{{"idempotency_sweep": nil}}); got != 0 {
		t.Errorf("a null answer became %d; 0 is the right fallback for a value that is not there", got)
	}
}

func valueKey(r map[string]any) string {
	for k := range r {
		return k
	}
	return ""
}

// TestTheTickAddsUpWhatTheViewAddsUpTo is the defect this file's header names, stated as the number
// the live database was giving at the time: vw_order_commitments answered 13 unresolved units over
// four backfill lines, and the tick filed "0 units held unresolved" beside them. Both because the
// quantities are `numeric` and the reader was a type switch that did not include what pgx sends for
// numeric. The rows below are in json.Number form for that reason - the shape normalise produces now
// - and the assertion is on the sentence, because the sentence is what a human queries.
func TestTheTickAddsUpWhatTheViewAddsUpTo(t *testing.T) {
	line := func(unresolved, unlinked float64) map[string]any {
		return map[string]any{
			"order_number": "SO-000016", "order_type": "SALES", "line_number": int32(1),
			"item_name": "Coolant 5L Jerrican",
			"quantity":  json.Number("5.0000"), "quantity_fulfilled": json.Number("0.0000"),
			"quantity_committed":          json.Number("5.0000"),
			"quantity_unresolved":         json.Number(fmt.Sprintf("%.4f", unresolved)),
			"quantity_committed_unlinked": json.Number(fmt.Sprintf("%.4f", unlinked)),
			"ledger_quantity":             json.Number("0"), "ledger_agreement": "nothing moved yet",
			"order_id": orderA, "order_line_id": lineA,
		}
	}
	q := &tickDB{
		sweepRows: []map[string]any{{"idempotency_sweep": int32(2)}},
		lines:     []map[string]any{line(5, 0), line(4, 0), line(2, 0), line(2, 0)},
	}
	res, err := RunHousekeeping(context.Background(), q, logging.NewRecorder(nil, false), "test-model")
	if err != nil {
		t.Fatal(err)
	}
	if res.UnresolvedUnits != 13 {
		t.Errorf("UnresolvedUnits = %v, want 13: the tick reports 0 while the view says 13, which is "+
			"the false clean bill this whole file exists to prevent", res.UnresolvedUnits)
	}
	if res.UnlinkedUnits != 0 {
		t.Errorf("UnlinkedUnits = %v, want 0", res.UnlinkedUnits)
	}
	if res.ClaimsCollected != 2 {
		t.Errorf("ClaimsCollected = %d, want 2 - the sweep answered int32 and the parser read 0",
			res.ClaimsCollected)
	}
	s := describe(res)
	for _, want := range []string{"13 units held unresolved", "2 expired collected"} {
		if !strings.Contains(s, want) {
			t.Errorf("the sentence is missing %q:\n  %s", want, s)
		}
	}
}
