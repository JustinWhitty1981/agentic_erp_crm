// check.go is the timer's work: the deterministic stock check that runs every interval without
// a model in the loop.
//
// The choice against an LLM here is the requirements doc's Efficiency rule taken seriously: a
// model call every 30 minutes is 48 a day, 17,520 a year, to ask a question the database already
// answers in one indexed scan of a view - and it would introduce a stochastic step into the only
// path that has to run unconditionally. The model meets the data where a human asks: the chat
// turns run the tools in this same package. What the loop DOES keep, per AGENTS.md's rule that an
// agent you cannot read back is an agent you cannot fix, is the trajectory row: BeginTool/EndTool
// and Record make each check a run with a duration, an outcome and response_sources, which is
// what turns "must run successfully every 30 minutes" from a hope into `WHERE bot_id='inventory'`
// and vw_failed_interactions.
package inventory

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"jada-backend/pkg/logging"
	"jada-backend/pkg/memory"
	"jada-backend/pkg/turn"
)

// CheckResult is one tick's finding, in Go before it is a sentence.
type CheckResult struct {
	Scanned   int
	Critical  []map[string]any
	Low       []map[string]any
	Truncated bool
}

// RunCheck queries the alert view once, files the run in the trajectory, and raises a memory
// entry only when the finding changed - a critical alert is a fact the next chat turn should
// know without re-scanning, and re-saving the same fact every tick is the noise 0023's claim
// exists to make impossible.
//
// The alert scan mirrors get_low_stock_items' SQL by hand rather than calling the tool, and that
// duplication is on purpose in only one direction: the check must not depend on the tool layer,
// whose argument coercion and row caps exist for a model's context window that this path does
// not have. If the view's shape changes, the tool description's list and this projection change
// together; db/tests/4_8 is the net that catches one being edited without the other.
func RunCheck(ctx context.Context, q Querier, rec *logging.Recorder, model string) (*CheckResult, error) {
	started := time.Now()
	run := logging.NewRun("schedule", "<scheduled inventory check>", AgentName(), model)
	ctx = turn.From(ctx, run.ID(), "schedule", run)
	defer func() {
		if err := rec.Record(ctx, run); err != nil {
			slog.Error("could not record the scheduled check", "run_id", run.ID(), "err", err)
		}
	}()

	step := 0
	run.BeginTool(step, "scan vw_low_stock_alerts", nil)
	rows, err := q.Query(ctx,
		"SELECT item_id, sku, name, warehouse_name, quantity_on_hand, quantity_available,"+
			" reorder_point, lead_time_days, alert_level, stock_percentage"+
			" FROM vw_low_stock_alerts ORDER BY stock_percentage, sku LIMIT 500")
	result := &CheckResult{}
	if err == nil {
		result.Scanned = len(rows)
		result.Truncated = len(rows) == 500
		for _, r := range rows {
			if lvl, _ := r["alert_level"].(string); lvl == "CRITICAL" {
				result.Critical = append(result.Critical, r)
			} else {
				result.Low = append(result.Low, r)
			}
			turn.Source(ctx, "inventory_items", r["item_id"])
		}
	}
	out := describe(result)
	if result.Truncated {
		out += " (list truncated at 500 lines - the catalog outgrew one scan, see the doc's scalability note)"
	}
	run.EndTool(step, out, err)
	step++

	if err != nil {
		run.Finish("", err)
		return result, err
	}

	// The memory only moves when the finding moves: the key is the alert state, and a tick that
	// reads the same shortages as the last one has nothing it is allowed to call news. The read
	// goes to the get_memory DOOR and its content column, not to memory.Read - that renders rows
	// as JSON for the chat tools, and comparing a rendering to a signature is true forever, which
	// is how this line first shipped 48 duplicate memories a day: 0023's "how often the model
	// stuttered" failure, arriving from the timer instead of the model.
	sig := signature(result)
	prev, err := lastAlertState(ctx, q)
	if err == nil && prev != sig {
		memory.Save(ctx, "inventory.alert.state", sig)
		run.BeginTool(step, "save_memory", map[string]any{"key": "inventory.alert.state"})
		run.EndTool(step, "recorded", nil)
		step++
	}

	run.Finish(out, nil)
	slog.Info("inventory check", "critical", len(result.Critical), "low", len(result.Low),
		"ms", time.Since(started).Milliseconds())
	return result, nil
}

// lastAlertState reads the newest content stored under the alert key, through the same door the
// chat memory tools use. A key nobody has written answers "" - distinct from every real
// signature, which is exactly what the first save needs.
func lastAlertState(ctx context.Context, q Querier) (string, error) {
	rows, err := q.Call(ctx, "get_memory", []any{"inventory.alert.state", 1})
	if err != nil || len(rows) == 0 {
		return "", err
	}
	c, _ := rows[0]["content"].(string)
	return c, nil
}

// describe is the same sentence a chat answer would give, written for the trajectory's
// final_output column - where it is read by whoever debugs a week of runs in one query, not by a
// browser.
func describe(r *CheckResult) string {
	if r.Scanned == 0 {
		return "no stock below its reorder point"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%d below reorder point: %d critical", r.Scanned, len(r.Critical))
	for i, c := range r.Critical {
		if i == 5 {
			fmt.Fprintf(&b, " and %d more", len(r.Critical)-5)
			break
		}
		fmt.Fprintf(&b, "; %s at %s has %v available against %v",
			c["sku"], c["warehouse_name"], c["quantity_available"], c["reorder_point"])
	}
	return b.String()
}

// signature collapses a check to the fact a later check can be compared against: which lines
// are critical, by sku. LOW churn is noise for memory purposes; CRITICAL membership is not.
func signature(r *CheckResult) string {
	if len(r.Critical) == 0 {
		return "clear"
	}
	skus := make([]string, 0, len(r.Critical))
	for _, c := range r.Critical {
		s, _ := c["sku"].(string)
		skus = append(skus, s)
	}
	return "critical: " + strings.Join(skus, ", ")
}
