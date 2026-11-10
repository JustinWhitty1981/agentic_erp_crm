// embed.go is the semantic half of the CRM surface: one read the model can call, and the timer whose
// job is to make that read have anything to answer with.
//
// Both halves exist because 0012 said so. That migration built the three hnsw indexes, proved with
// db/tests/6_4_vectors.sql that an ANN scan on them is cheaper than the seq scan it replaces, and then
// declined to build the rest: "indexing a capability nobody queries is B12's scoreboard, not a
// feature; wiring a semantic-search tool is Phase 5 code work." Phase 5 is this file. The blocker
// recorded in four places (PLAN.md, architecture.md, this agent's README, 0021's column comment) was
// that nothing in the deployment produced 1536 dimensions; what changed is an embedder behind a proxy
// that will answer an explicit width, which pkg/embed checks rather than trusts.
//
// The split between the two halves is the interesting decision, and it is the same one agents/sales and
// agents/inventory made for their keepers:
//
//   * A communication is embedded by the timer, and never by the write that created it. A trigger or
//     a tool that called out to a model server would make every CRM write as available as a GPU three
//     machines away, and 0021's door is not built to fail that way. The cost is honest and is stated
//     in the tool's description: a row written at 14:00 is invisible to a search until the next tick.
//   * What the timer does is fill gaps, not maintain a value. vw_unembedded_communications is its
//     whole queue, and embed_communications refuses a row that already has a vector, so an idle tick
//     writes nothing and - the part that would otherwise be invisible - files no audit rows for a
//     table nobody changed.
//
// Neither half has a model in the loop, for the reason agents/inventory states and 0035 repeats: the
// work is a statement the database answers exactly. What the loop does keep is the trajectory row, so
// "the embedder is running" is a query against agent_interactions and not a grep over container logs.

package crm

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"time"

	"jada-backend/pkg/embed"
	"jada-backend/pkg/logging"
	"jada-backend/pkg/memory"
	"jada-backend/pkg/turn"
)

// EmbedStateKey is the memory this keeper maintains: one row for the whole finding rather than one per
// communication, written only when the finding moved. Same shape as agents/sales' ReconcileKey and for
// the same reason - the memory says what is true, not how often the timer woke up.
//
// It is namespaced with this agent's own role, and that is 0032's lesson applied one store over:
// agent_memories has no agent column, so three writers share 17 keys by convention alone, and a key
// that reads like a fact about the deployment ("warehouse.main.id") is one process's note filed where
// another process will look for its own.
const EmbedStateKey = "customer_service.embedding.coverage"

const (
	// EnvEmbedRows is how much of the backlog one tick is allowed to take. It exists because the first
	// tick on a populated database is not like the rest: on this server that is 25 rows and about a
	// second, and on a database that has been recording communications for a year it is tens of
	// thousands of them, which is a minute of HTTP and a lock on the keeper's own deadline. The gap
	// drains over ticks; the sentence in the trajectory says how much is left, which is the only
	// reason a cap is a schedule and not a silent truncation.
	EnvEmbedRows = "EMBEDDING_ROWS_PER_TICK"
	// EnvCheckInterval is this process's timer. It is named the same as the inventory and sales
	// forks' key on purpose: three copies of one loop reading three different names for "how often"
	// is how one agent ends up running hourly and its sibling running daily while both READMEs say
	// hourly.
	EnvCheckInterval = "EMBEDDING_INTERVAL_MINUTES"

	defaultEmbedRows     = 500
	defaultEmbedMinutes  = 60
	embedFirstTickAfter  = 30 * time.Second
	defaultSearchResults = 5
	maxSearchResults     = 50
)

// Coverage is what vw_embedding_status says about the one column this agent writes. Read from the view
// and never counted in Go: the counts are the same arithmetic, and 0035's own §5 comment is the reason
// a client-side COUNT would be the second copy of a fact that can become the wrong one.
type Coverage struct {
	RowsTotal     int
	RowsEmbedded  int
	Verdict       string
	EmbeddedBy    string
	ServedBy      string
	NewestAt      string
	searchableSet bool
}

// EmbedResult is one tick's finding, in Go before it is a sentence.
type EmbedResult struct {
	// Queued is how many rows the tick took out of the gap, and Offered how many it sent to the
	// embedder after the empty-document rows were dropped. The difference is the rows this agent
	// cannot describe, and it is reported rather than skipped quietly, because "nothing to embed"
	// for a row that has a summary is a bug in the view's composition rule.
	Queued   int
	Offered  int
	Embedded int
	Refused  int
	// SkippedEmpty counts the queued rows whose document is empty in all three text columns. They
	// are not sent and not written; they will be in next tick's queue too, which is why the tick
	// says so out loud instead of looping over them forever.
	SkippedEmpty int
	// CoverageAfter is the corpus, not this tick: the number a reader wants is "can I search this
	// company's history", and that is not a per-tick quantity.
	CoverageAfter Coverage
	// CoverageBefore is the same register read at the top of the tick. It exists for one case: the
	// scan that closes a tick can fail while the scan that opened it did not, and a sentence that
	// then says "coverage not readable" is throwing away a number this process already knows.
	// Stale-and-labelled beats absent, and both beat wrong.
	CoverageBefore Coverage
	// HaveBefore is whether that first read succeeded, so describe() does not print "0 of 0" about
	// a corpus it never saw.
	HaveBefore bool
	// ModelConflict is the sentence the door refuses with, when it refuses for the reason 0035 exists
	// for. It is a field and not merely an error because the tick must keep reporting it every hour
	// without writing anything: an operator has to decide, and a decision that is only in a log line
	// that scrolled away is not a decision pending, it is a policy unkept.
	ModelConflict string
	Failure       string
}

// RunEmbeddings drains what it can of the gap, files the run, and raises the memory only when the
// finding moved.
func RunEmbeddings(ctx context.Context, q Querier, e *embed.Client, rec *logging.Recorder) (*EmbedResult, error) {
	started := time.Now()
	model := "not configured"
	if e != nil {
		model = e.Model
	}
	run := logging.NewRun("schedule", "<scheduled embedding sweep: fill communications.embedding>",
		agentName(), model)
	ctx = turn.From(ctx, run.ID(), "schedule", run)
	defer func() {
		if err := rec.Record(ctx, run); err != nil {
			slog.Error("could not record the scheduled embedding run", "run_id", run.ID(), "err", err)
		}
	}()

	result := &EmbedResult{}
	step := 0
	var firstErr error

	// 1. Where the corpus stands, before anything moves. One row of the register, and the reason the
	//    tick knows the difference between "there was nothing to do" and "there is no way to do it".
	run.BeginTool(step, "scan vw_embedding_status", nil)
	before, err := coverage(ctx, q)
	if err != nil {
		result.Failure = oneLine(err)
		firstErr = err
		run.EndTool(step, "", err)
	} else {
		result.CoverageBefore = before
		result.HaveBefore = true
		run.EndTool(step, before.sentence(), nil)
	}
	step++

	switch {
	case e == nil:
		// Nothing to do, and the reason is configuration rather than an accident. Stated this way
		// because the alternative - the tick not being armed at all - means the absence of rows in
		// agent_interactions would be the only signal, and an absent row is what an outage looks
		// like.
		result.Failure = "no embedder configured"
		out := EnvEmbedModel + " is unset, so communications.embedding stays empty and a similarity " +
			"query cannot answer anything. This is a deployment choice, not a failure."
		run.Finish(out, nil)
		slog.Info("embedding sweep skipped", "why", "no embedder configured",
			"ms", time.Since(started).Milliseconds())
		return result, nil

	case err != nil:
		out := "could not read the corpus coverage, so nothing was embedded this tick: " + result.Failure
		run.Finish(out, firstErr)
		return result, firstErr
	}

	// 2. The queue. ORDER BY id and not by started_at: a backlog drains oldest-first, which is the
	//    order that makes the corpus homogeneous soonest, and an id is stable while a row's date can
	//    be edited by update. LIMIT is the tick's budget (EnvEmbedRows).
	limit := envInt(EnvEmbedRows, defaultEmbedRows)
	run.BeginTool(step, "take from vw_unembedded_communications", map[string]any{"limit": limit})
	rows, err := q.Query(ctx,
		"SELECT communication_id, customer_name, embeddable_text, nothing_to_embed "+
			"FROM vw_unembedded_communications ORDER BY communication_id LIMIT $1", limit)
	if err != nil {
		result.Failure = oneLine(err)
		if firstErr == nil {
			firstErr = err
		}
		run.EndTool(step, "", err)
		run.Finish("the queue could not be read, so nothing was embedded this tick: "+result.Failure,
			firstErr)
		return result, firstErr
	}
	result.Queued = len(rows)
	run.EndTool(step, fmt.Sprintf("%d row(s) queued", result.Queued), nil)
	step++

	texts := make([]string, 0, len(rows))
	ids := make([]any, 0, len(rows))
	for _, r := range rows {
		if b, _ := r["nothing_to_embed"].(bool); b {
			result.SkippedEmpty++
			continue
		}
		t, _ := r["embeddable_text"].(string)
		if strings.TrimSpace(t) == "" {
			result.SkippedEmpty++
			continue
		}
		texts = append(texts, t)
		ids = append(ids, r["communication_id"])
	}
	result.Offered = len(texts)

	// 3 and 4. The vectors and the write, both skipped by an idle tick, which then falls through to the
	// closing scan rather than returning early. That fall-through is the fix and not a style choice:
	// on the early-return shape a tick with nothing queued reported CoverageAfter as the zero value it
	// still was, so describe() said "coverage not readable" about a corpus the same tick had just read,
	// and remember() wrote "0/0||" over the last true finding. An idle tick overwriting the record with
	// a zero is the same defect as a failed one doing it, and TestTheMemoryMovesWhenTheCoverageMoves is
	// what keeps it fixed.
	if result.Offered > 0 {
		// pkg/embed's contract is that this returns either len(texts) vectors of the declared width or
		// an error, and the width is checked there because the server has answered this request two
		// different ways with a status code that said everything was fine.
		run.BeginTool(step, "embed "+strconv.Itoa(result.Offered)+" text(s)",
			map[string]any{"model": e.Model, "count": result.Offered})
		vecs, err := e.Embed(ctx, texts)
		if err != nil {
			result.Failure = oneLine(err)
			firstErr = err
			run.EndTool(step, "", err)
			run.Finish(describe(result), firstErr)
			slog.Error("embedding sweep failed", "err", err, "ms", time.Since(started).Milliseconds())
			return result, firstErr
		}
		run.EndTool(step, fmt.Sprintf("%d vector(s) at %d dimensions", len(vecs), e.Dimensions), nil)
		step++

		items := make([]map[string]any, 0, len(ids))
		for i := range ids {
			vec, merr := json.Marshal(vecs[i])
			if merr != nil {
				result.Failure = oneLine(merr)
				run.Finish("could not render the vectors: "+result.Failure, merr)
				return result, merr
			}
			items = append(items, map[string]any{
				"communication_id": ids[i],
				// A string and not a nested array: it is the rendering pgvector itself prints, so the
				// shape in the trajectory row is the shape in the column. The door accepts either and
				// measures whichever arrives.
				"embedding": string(vec),
			})
		}
		encoded, jerr := mustJSON(items)
		if jerr != nil {
			result.Failure = oneLine(jerr)
			run.Finish("the batch could not be rendered for the door: "+result.Failure, jerr)
			return result, jerr
		}
		vals := []any{encoded, e.Model, e.BaseURL}
		// The step has to be opened as well as closed, and this is the only call in the tick that did
		// not open one. BeginTool appends the paired placeholder that keeps actions_taken and
		// tool_observations the same length (pkg/logging states that shape as a contract, and 0017's
		// vw_tool_calls joins the two arrays by position because they carry no key to join on);
		// EndTool overwrites a slot that exists and appends one that does not. So closing a step that
		// was never opened grew tool_observations by one, and every step after it read as the answer
		// to the call before it - which on a tick that embedded anything showed this door's message
		// under the closing coverage scan's name, and stranded that scan's own sentence where the view
		// never looks. The run row was always right; only the per-call trail was mis-paired.
		run.BeginTool(step, "embed_communications",
			map[string]any{"rows": len(ids), "model": e.Model})
		drow, err := q.Call(ctx, "embed_communications",
			append(vals, key(ctx, "embed_communications", vals)))
		if err != nil {
			result.Failure = oneLine(err)
			firstErr = err
			run.EndTool(step, "", err)
			// The refusal 0035 exists to raise, recognised rather than flattened into a generic
			// error: an operator has to decide, and a decision pending that only exists in a log line
			// that scrolled away is a policy unkept.
			if strings.Contains(result.Failure, "was filled by") {
				result.ModelConflict = result.Failure
				run.Finish(describe(result)+"; "+result.ModelConflict, firstErr)
				slog.Error("embedding sweep refused: the configured model is not the model in the column",
					"configured", e.Model, "err", result.Failure)
				return result, firstErr
			}
			run.Finish(describe(result)+"; the write door refused: "+result.Failure, firstErr)
			slog.Error("embedding sweep failed at the door", "err", err,
				"ms", time.Since(started).Milliseconds())
			return result, firstErr
		}
		run.EndTool(step, firstMessage(drow), nil)
		step++
		result.Embedded = intAt(drow, "rows_embedded")
		result.Refused = intAt(drow, "rows_refused")
		for _, id := range ids {
			turn.Source(ctx, "communications", id)
		}
	}

	// 5. Coverage after, from the same view, so the tick's own claim can be checked against the same
	//    source it was computed from. Not before+embedded, which would be a sum of two numbers that
	//    can each be wrong: the register is the one answer.
	run.BeginTool(step, "scan vw_embedding_status", nil)
	after, err := coverage(ctx, q)
	if err != nil {
		run.EndTool(step, "", err)
		result.Failure = oneLine(err)
		if firstErr == nil {
			firstErr = err
		}
	} else {
		result.CoverageAfter = after
		run.EndTool(step, after.sentence(), nil)
	}
	step++

	out := describe(result)
	run.Finish(out, firstErr)
	if err == nil {
		remember(ctx, q, result)
	}
	reported := after
	if !after.searchableSet && result.HaveBefore {
		reported = result.CoverageBefore
	}
	slog.Info("embedding sweep", "queued", result.Queued, "offered", result.Offered,
		"embedded", result.Embedded, "skipped_empty", result.SkippedEmpty,
		"coverage", fmt.Sprintf("%d/%d", reported.RowsEmbedded, reported.RowsTotal),
		"conflict", result.ModelConflict != "", "ms", time.Since(started).Milliseconds())
	return result, firstErr
}

// ---------------------------------------------------------------------------
// The parts above are the feature. What is below is the arithmetic it reports with.
// ---------------------------------------------------------------------------

// EnvEmbedModel is named here as well as in pkg/embed because it decides whether a tool is registered
// and whether a timer is armed, and both of those are this package's business.
const EnvEmbedModel = embed.EnvModel

// coverage reads the one row of the register that describes the column this agent owns.
func coverage(ctx context.Context, q Querier) (Coverage, error) {
	rows, err := q.Query(ctx,
		"SELECT rows_total, rows_embedded, verdict, "+
			"coalesce(embedded_by, '') AS embedded_by, "+
			"coalesce(served_by, '') AS served_by, "+
			"newest_embedded_at::text AS newest_at "+
			"FROM vw_embedding_status WHERE table_name = 'communications'")
	if err != nil {
		return Coverage{}, err
	}
	if len(rows) == 0 {
		// The register is derived from the catalog, so a missing row means the catalog lost the
		// column. That is not "0 of 0": it is a schema the keeper has no contract with, and saying
		// so is the difference between an odd tick and a broken deployment.
		return Coverage{}, fmt.Errorf("vw_embedding_status has no row for communications.embedding, " +
			"so the column this sweep exists to fill is not in the catalog it reports")
	}
	return Coverage{
		RowsTotal:     intAt(rows, "rows_total"),
		RowsEmbedded:  intAt(rows, "rows_embedded"),
		Verdict:       strAt(rows, "verdict"),
		EmbeddedBy:    strAt(rows, "embedded_by"),
		ServedBy:      strAt(rows, "served_by"),
		NewestAt:      strAt(rows, "newest_at"),
		searchableSet: true,
	}, nil
}

// sentence is the register in the fewest words that keep its meaning. It reads the verdict rather than
// recomputing one: EMPTY, PARTIAL, UNSTAMPED, MISMATCH, UNINDEXED and COMPLETE are 0035's categories
// and a second set of adjectives in Go would be a second opinion on the same data.
func (c Coverage) sentence() string {
	if !c.searchableSet {
		return "coverage unknown"
	}
	return fmt.Sprintf("%d of %d rows embedded; %s", c.RowsEmbedded, c.RowsTotal, c.Verdict)
}

// signature is what the memory compares against: the finding, not a rendering of the rows that
// produced it. Comparing a rendering to a signature is what shipped agents/inventory 48 duplicate
// memories a day, so the comparison here is content to content.
func signature(c Coverage) string {
	return fmt.Sprintf("%d/%d|%s|%s", c.RowsEmbedded, c.RowsTotal, c.EmbeddedBy, c.Verdict)
}

// remember writes the finding once per change, through the memory door rather than a store: this is
// what the agent knows, and 0023 moved what an agent knows into agent_memories for the reason that a
// process whose memory dies with its container has no memory.
func remember(ctx context.Context, q Querier, r *EmbedResult) {
	sig := signature(r.CoverageAfter)
	prev, err := lastCoverage(ctx, q)
	if err != nil || prev == sig {
		return
	}
	memory.Save(ctx, EmbedStateKey, sig)
}

func lastCoverage(ctx context.Context, q Querier) (string, error) {
	rows, err := q.Call(ctx, "get_memory", []any{EmbedStateKey, 1})
	if err != nil || len(rows) == 0 {
		return "", err
	}
	c, _ := rows[0]["content"].(string)
	return c, nil
}

// describe is the tick's sentence, in the one column anyone queries: agent_interactions.final_output.
// It is written for a reader doing a week of ticks in one SELECT, which is the only way the claim
// "the sweep runs hourly" is ever checked.
func describe(r *EmbedResult) string {
	var b strings.Builder
	if r.Queued == 0 {
		b.WriteString("nothing queued: ")
	} else {
		fmt.Fprintf(&b, "%d queued, %d offered, %d embedded, %d refused; ",
			r.Queued, r.Offered, r.Embedded, r.Refused)
	}
	if r.SkippedEmpty > 0 {
		fmt.Fprintf(&b, "%d row(s) have nothing to embed and will queue again; ", r.SkippedEmpty)
	}
	if gap := r.gapLeft(); gap > 0 && r.Embedded == 0 && r.Failure != "" {
		fmt.Fprintf(&b, "the gap still stands at %d row(s); ", gap)
	}
	if r.CoverageAfter.searchableSet {
		fmt.Fprintf(&b, "coverage %d of %d (%s)", r.CoverageAfter.RowsEmbedded,
			r.CoverageAfter.RowsTotal, r.CoverageAfter.Verdict)
		if r.CoverageAfter.EmbeddedBy != "" {
			fmt.Fprintf(&b, " by %s", r.CoverageAfter.EmbeddedBy)
		}
	} else if r.HaveBefore {
		// The number from the top of the tick, said as such. Throwing it away is the same shape as
		// 0031's "0 collected" beside a 42501: an absent fact reading as a benign one.
		fmt.Fprintf(&b, "coverage %d of %d as of this tick's first scan (%s); the closing scan failed",
			r.CoverageBefore.RowsEmbedded, r.CoverageBefore.RowsTotal, r.CoverageBefore.Verdict)
	} else {
		b.WriteString("coverage not readable this tick")
	}
	if r.Failure != "" {
		b.WriteString("; FAILURE: " + r.Failure)
	}
	return b.String()
}

// StartEmbeddingTimer owns the schedule: first tick 30 seconds after boot, then every
// EMBEDDING_INTERVAL_MINUTES (default 60) for as long as the process lives.
//
// It recovers from a panicking tick rather than dying with it, for the reason both sibling forks state:
// this goroutine holds the liveness of the service it runs in, and a nil surfacing here would take the
// chat endpoints down with the schedule. The panic lands in the trajectory as the tick's own
// error_message before the loop sleeps again, which is what turns "it stopped running" into a row in
// vw_failed_interactions.
func StartEmbeddingTimer(q Querier, e *embed.Client, rec *logging.Recorder) {
	interval := embeddingInterval()
	slog.Info("embedding timer armed", "every", interval.String(), "first_tick_in",
		embedFirstTickAfter.String(), "model", e.Describe())

	tick := func() {
		defer func() {
			if p := recover(); p != nil {
				slog.Error("embedding tick panicked; the timer continues", "panic", p)
			}
		}()
		ctx, cancel := context.WithTimeout(context.Background(), interval)
		defer cancel()
		if _, err := RunEmbeddings(ctx, q, e, rec); err != nil {
			slog.Error("embedding tick failed; the next tick will try again", "err", err)
		}
	}

	time.AfterFunc(embedFirstTickAfter, func() {
		tick()
		t := time.NewTicker(interval)
		defer t.Stop()
		for range t.C {
			tick()
		}
	})
}

// embeddingInterval reads this process's tick period. It is a function rather than six lines inside
// StartEmbeddingTimer so it can be tested: the alternative is a test that either waits out a real
// schedule or asserts nothing about the one knob the timer has.
func embeddingInterval() time.Duration {
	v := strings.TrimSpace(os.Getenv(EnvCheckInterval))
	if v == "" {
		return defaultEmbedMinutes * time.Minute
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		slog.Warn(EnvCheckInterval+" is not a positive number of minutes; keeping the default",
			"value", v, "default_minutes", defaultEmbedMinutes)
		return defaultEmbedMinutes * time.Minute
	}
	return time.Duration(n) * time.Minute
}

// oneLine flattens an error into a sentence: a newline in final_output is a column nobody reads
// cleanly, and pgx's and net/http's error strings are long by default.
func oneLine(err error) string {
	if err == nil {
		return ""
	}
	return strings.Join(strings.Fields(strings.ReplaceAll(err.Error(), "\n", " ")), " ")
}

func strAt(rows []map[string]any, key string) string {
	if len(rows) == 0 {
		return ""
	}
	s, _ := rows[0][key].(string)
	return s
}

// intAt reads one integer column out of a row. Every arm is load-bearing and the list is pgx's own
// default map: `integer` arrives as an int32 and `bigint` as an int64, so a reader that switches on
// int64 alone reports 0 for a bigint's smaller cousin, and the count that is confidently zero is the
// defect 0031's keeper shipped with. A count from the register is a bigint; a limit is an integer.
func intAt(rows []map[string]any, key string) int {
	if len(rows) == 0 {
		return 0
	}
	switch n := rows[0][key].(type) {
	case int64:
		return int(n)
	case int32:
		return int(n)
	case int:
		return n
	case json.Number:
		f, err := n.Float64()
		if err != nil {
			return 0
		}
		return int(f)
	case float64:
		return int(n)
	case string:
		v, _ := strconv.Atoi(n)
		return v
	}
	return 0
}

func firstMessage(rows []map[string]any) string {
	if s := strAt(rows, "message"); s != "" {
		return s
	}
	return "the door answered without a message"
}

// remainingOf is how many rows the corpus still cannot be searched by meaning. It is a subtraction of
// two numbers from the register rather than a count this package ran itself, and it is a function only
// so the guard against a negative is stated once: a tick that embedded rows concurrently with another
// writer can otherwise report "-3 rows left", which is not a fact about the database.
func remainingOf(c Coverage) int {
	if n := c.RowsTotal - c.RowsEmbedded; n > 0 {
		return n
	}
	return 0
}

// agentName is this process's identity in the trail, as a string. AgentID returns it as `any`
// because it is a function parameter there and a column value here, and the one rule both packages
// depend on is that the literal appears once - which is why pkg/agent's AgentName reads crm's own
// two constants instead of declaring its own pair. This is the third reader of that pair, and a
// cycle prevents it from calling pkg/agent, so the helper is here.
func agentName() string {
	if v := strings.TrimSpace(os.Getenv(EnvAgentRole)); v != "" {
		return v
	}
	return DefaultAgentRole
}

// envInt is an integer knob with a default, and a warning that names the default it kept rather than
// one it did not: the inventory fork's line said 30 in a package whose fallback was 60, and an
// operator who set a nonsense value would go looking for a schedule that was never running.
func envInt(name string, def int) int {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		slog.Warn(name+" is not a positive number; keeping the default", "value", v, "default", def)
		return def
	}
	return n
}

// gapLeft is how many rows of the corpus no similarity query can see yet. It is a subtraction of two
// numbers from the register rather than a count this package ran itself, and the negative guard is
// here rather than at the call sites because a tick racing another writer would otherwise report
// "-3 rows left", which is not a fact about any database.
func (r *EmbedResult) gapLeft() int {
	c := r.CoverageAfter
	if !c.searchableSet {
		c = r.CoverageBefore
	}
	if n := c.RowsTotal - c.RowsEmbedded; n > 0 {
		return n
	}
	return 0
}
