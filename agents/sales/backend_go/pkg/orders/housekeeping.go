// housekeeping.go is the timer's work: two jobs the schema was written with and never given a keeper,
// run on a schedule without a model in the loop.
//
// The first is `idempotency_sweep`. 0011 built the retention policy - a settled claim is history
// after 24 hours, an unclaimed one is live work and must survive - and nothing scheduled it, so the
// table grew a row for every write every agent made until this server held 28 rows past their
// retention and the register's "which calls are guarded" answer started counting stale claims as the
// current state of the world. 0030 collected that backlog in its own §8 and named the keeper as owed.
// This is it.
//
// The second is the reconciliation. `vw_order_commitments` answers, per line, whether the counter on
// the document agrees with the ledger that moved the stock, and until now the only way to find out was
// for someone to select it - which is the same class of gap as an alarm nobody subscribes to. The tick
// asks the question the view already knows how to answer, and files what it finds where the next
// conversation can read it.
//
// No model call, for the inventory agent's stated reason multiplied by two: both jobs are one
// statement the database answers exactly, and a stochastic step in the only path that has to run
// unconditionally is a schedule that sometimes does not. What the loop does keep is the trajectory row:
// each tick is a run with a duration, an outcome and response_sources, which is what turns "the sweep
// runs hourly" into `WHERE bot_id='sales'` and vw_failed_interactions rather than into a log line
// nobody reads.
package orders

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"encoding/json"
	"jada-backend/pkg/logging"
	"jada-backend/pkg/memory"
	"jada-backend/pkg/turn"
	"strconv"
)

// ReconcileKey is the memory this tick maintains: one row for the whole finding rather than one per
// document, and written only when the finding changed. Same shape as the inventory agent's alert key,
// for the same reason - the memory says what is true, not how often the timer woke up.
const ReconcileKey = "orders.reconciliation.state"

// HousekeepingResult is one tick's finding, in Go before it is a sentence.
type HousekeepingResult struct {
	// ClaimsCollected is how many settled claims past retention the sweep deleted. Zero is the
	// normal answer and the good one; it is not a failure. It is also, though, exactly what a sweep
	// that never ran leaves behind - which is why describe() reads this field together with
	// SweepFailure: "0 collected" and "0 collected because it could not" are different facts, and
	// only one of them is news.
	ClaimsCollected int
	// SweepFailure is the sweep's error, flattened to one line, when the first job did not run;
	// empty when it did. The reconciliation runs either way - that is what "must not stop" is worth
	// - so without this field a tick whose retention policy had silently stopped being enforced
	// would read, in the one column a human queries, exactly like a healthy one. On this server the
	// case has a name: 0011 closed idempotency_sweep to the runtime role, 0031 reopened it, and the
	// ticks between those two migrations answered 42501 while reporting "claims swept: 0 expired
	// collected".
	SweepFailure string
	// LinesChecked counts the order lines the reconciliation looked at.
	LinesChecked int
	// Disagreements is how many of them say the document's counter and the ledger do not agree - the
	// one value here that should be empty and is worth an alarm when it is not.
	Disagreements []map[string]any
	// UnresolvedUnits is the stock held against some document that no door has settled: what the
	// 13 units stuck since 0015 were before 0030 released them, and the number that starts climbing
	// again the day a fulfilment path is built without its release.
	UnresolvedUnits float64
	// UnlinkedUnits is held stock this view could not attribute to a line. It is reported apart from
	// the one above because the join that produces the first cannot see the second, and reading "no
	// unresolved units" when the truth is "nothing attributed" is the mistake the view was designed
	// to make impossible.
	UnlinkedUnits float64
}

// RunHousekeeping does both jobs in one connection, files the run, and raises the memory only when
// the finding moved.
func RunHousekeeping(ctx context.Context, q Querier, rec *logging.Recorder, model string) (*HousekeepingResult, error) {
	started := time.Now()
	run := logging.NewRun("schedule", "<scheduled order housekeeping: claim sweep and commitment reconciliation>",
		AgentName(), model)
	ctx = turn.From(ctx, run.ID(), "schedule", run)
	defer func() {
		if err := rec.Record(ctx, run); err != nil {
			slog.Error("could not record the scheduled housekeeping run", "run_id", run.ID(), "err", err)
		}
	}()

	result := &HousekeepingResult{}
	step := 0

	// 1. The claim retention. The door takes no arguments and answers a count, which is the whole
	//    contract; a failed sweep must not stop the reconciliation, so the two steps record their own
	//    errors and the run reports the first one it saw.
	run.BeginTool(step, "idempotency_sweep", nil)
	rows, sweepErr := q.Call(ctx, "idempotency_sweep", []any{})
	if sweepErr != nil {
		result.SweepFailure = oneLine(sweepErr)
		run.EndTool(step, "", sweepErr)
	} else {
		result.ClaimsCollected = intArg(rows)
		run.EndTool(step, fmt.Sprintf("%d expired claim(s) collected", result.ClaimsCollected), nil)
	}
	step++

	// 2. The reconciliation, in one scan. The projection is the view's own verdict columns: this
	//    function computes nothing, which is the point of 0030 §6 having put the arithmetic in SQL in
	//    the first place - a rule restated in Go is a rule that can drift from the rule the database
	//    enforces, and 4_8's column census is the net under this list too.
	run.BeginTool(step, "scan vw_order_commitments", nil)
	lines, err := q.Query(ctx,
		"SELECT order_number, order_type, line_number, item_name, quantity, quantity_fulfilled,"+
			" quantity_committed, quantity_unresolved, quantity_committed_unlinked, ledger_quantity,"+
			" ledger_agreement, order_id, order_line_id"+
			" FROM vw_order_commitments ORDER BY order_number, line_number LIMIT 2000")
	if err == nil {
		result.LinesChecked = len(lines)
		for _, l := range lines {
			if v, _ := l["ledger_agreement"].(string); v == "DISAGREES" {
				result.Disagreements = append(result.Disagreements, l)
			}
			if n, ok := num(l["quantity_unresolved"]); ok {
				result.UnresolvedUnits += n
			}
			if n, ok := num(l["quantity_committed_unlinked"]); ok {
				result.UnlinkedUnits += n
			}
			turn.Source(ctx, "order_items", l["order_line_id"])
		}
	}
	out := describe(result)
	run.EndTool(step, out, err)
	step++

	slog.Info("order housekeeping", "claims_collected", result.ClaimsCollected,
		"sweep_failed", result.SweepFailure != "", "lines", result.LinesChecked,
		"disagreements", len(result.Disagreements), "unresolved_units", result.UnresolvedUnits,
		"unlinked_units", result.UnlinkedUnits, "ms", time.Since(started).Milliseconds())

	// The memory moves when the finding moves, and it moves on the strength of the SCAN alone. A
	// sweep that failed says nothing about whether a line's counter agrees with the ledger that moved
	// its stock, and an earlier shape of this block returned before reaching here whenever either job
	// broke - so a privilege gap in the retention policy silenced the reconciliation alarm too, which
	// is the header's "must not stop the reconciliation" existing as a comment instead of as control
	// flow. The fix is 0031's grant; the fix here is that one broken half cannot hide the other.
	//
	// Guarded by err and not by optimism: a scan that failed leaves every total at zero, and storing
	// that signature would overwrite last week's real finding with a sentence that reads clean.
	// Comparison is against the door's stored content and not a rendering of rows, for the inventory
	// check's documented reason - comparing a rendering to a signature is true forever, and that
	// shipped 48 duplicate memories a day.
	if err == nil {
		sig := signature(result)
		prev, perr := lastFinding(ctx, q)
		if perr == nil && prev != sig {
			memory.Save(ctx, ReconcileKey, sig)
			run.BeginTool(step, "save_memory", map[string]any{"key": ReconcileKey})
			run.EndTool(step, "recorded", nil)
			step++
		}
	}

	// One error per run, the first one seen, so vw_failed_interactions names the tick that could not
	// do its job whichever half broke, and the trajectory's error_message agrees with the sentence
	// above it.
	failure := err
	if failure == nil {
		failure = sweepErr
	}
	run.Finish(out, failure)
	return result, failure
}

// oneLine flattens an error into what describe() can embed: a newline in agent_interactions.final_output
// is a column nobody's query reads cleanly, and the driver's error strings are long by default.
func oneLine(err error) string {
	return strings.Join(strings.Fields(strings.ReplaceAll(err.Error(), "\n", " ")), " ")
}

// lastFinding reads the newest content stored under the reconciliation key through the memory DOOR,
// so this compares stored text to computed text. An unwritten key answers "", which is distinct from
// every real signature - the first tick therefore always records.
func lastFinding(ctx context.Context, q Querier) (string, error) {
	rows, err := q.Call(ctx, "get_memory", []any{ReconcileKey, 1})
	if err != nil || len(rows) == 0 {
		return "", err
	}
	c, _ := rows[0]["content"].(string)
	return c, nil
}

// intArg reads the single integer a no-row-count door like idempotency_sweep answers with. The
// column is named for the function, because `SELECT * FROM f()` names its output after f when f
// RETURNS a scalar - which is the whole reason this is a lookup by value rather than by key.
func intArg(rows []map[string]any) int {
	for _, r := range rows {
		for _, v := range r {
			switch n := v.(type) {
			case int64:
				return int(n)
			case int:
				return n
			case int32:
				// The arm that mattered. `idempotency_sweep` RETURNS integer, and pgx v5's default map
				// sends `integer` - int4 - to Go as an int32 (pgtype/pgtype_default.go:164), so a switch
				// without this arm reads every real sweep as 0 and describe() prints "0 expired
				// collected" about a sweep that collected some. Same class of defect as the numeric one
				// pkg/db's normalise now unwraps: the JSON plane marshals all of these correctly, and
				// only the Go-side read is blind to which Go type the driver chose.
				// TestIntArgReadsEveryIntegerTheDriverSends is that fact, enforced at build time.
				return int(n)
			case int16:
				return int(n) // smallint
			case uint64:
				return int(n)
			case float32:
				return int(n) // real
			case float64:
				return int(n) // double precision, and SUM() over an integer column
			case json.Number:
				// A numeric column answering a count - SUM() over numeric keeps its scale, so parse it
				// rather than truncate the text.
				f, err := strconv.ParseFloat(n.String(), 64)
				if err != nil {
					return 0
				}
				return int(f)
			}
		}
	}
	return 0
}

// describe is the sentence the trajectory's final_output column carries: written for whoever reads a
// week of ticks in one query, not for a browser.
func describe(r *HousekeepingResult) string {
	var b strings.Builder
	if r.SweepFailure != "" {
		// The failure in the same clause as the number that would otherwise read as a healthy zero,
		// because for an hourly tick that nobody watches live this string IS the monitoring.
		fmt.Fprintf(&b, "CLAIM SWEEP FAILED (%s): retention was not enforced this tick, %d expired "+
			"claims collected; ", r.SweepFailure, r.ClaimsCollected)
	} else {
		fmt.Fprintf(&b, "claims swept: %d expired collected; ", r.ClaimsCollected)
	}
	if r.LinesChecked == 0 {
		b.WriteString("no order lines exist to reconcile")
		return b.String()
	}
	fmt.Fprintf(&b, "%d lines reconciled", r.LinesChecked)
	if len(r.Disagreements) > 0 {
		fmt.Fprintf(&b, ", %d DISAGREE", len(r.Disagreements))
		for i, d := range r.Disagreements {
			if i == 4 {
				fmt.Fprintf(&b, " and %d more", len(r.Disagreements)-4)
				break
			}
			fmt.Fprintf(&b, "; %s line %v holds %v against a ledger of %v",
				d["order_number"], d["line_number"], d["quantity_fulfilled"], d["ledger_quantity"])
		}
	} else {
		b.WriteString(", none disagreeing")
	}
	fmt.Fprintf(&b, "; %.4g units held unresolved, %.4g of them attributed to no line",
		r.UnresolvedUnits, r.UnlinkedUnits)
	return b.String()
}

// signature collapses a tick to what a later tick can be compared against: the count of lines whose
// counters and ledger disagree, their numbers, and the two totals. It leaves out the sweep count on
// purpose - claims expire every hour in normal operation, and a signature that moved on that would
// rewrite the memory on every tick and tell anyone reading it nothing.
func signature(r *HousekeepingResult) string {
	parts := make([]string, 0, len(r.Disagreements))
	for _, d := range r.Disagreements {
		parts = append(parts, fmt.Sprintf("%v", d["order_number"]))
	}
	return fmt.Sprintf("%d lines, %d disagreements (%s), %.4g unresolved, %.4g unattributed",
		r.LinesChecked, len(r.Disagreements), strings.Join(parts, " "),
		r.UnresolvedUnits, r.UnlinkedUnits)
}
