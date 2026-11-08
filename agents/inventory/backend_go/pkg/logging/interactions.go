// The run record: everything one agent turn did, assembled during the turn and written once at
// the end.
//
// Two properties are load-bearing and easy to lose in a refactor, so they are the interface
// rather than an implementation detail:
//
//   - actions_taken and tool_observations stay the same length. vw_tool_calls pairs step n of
//     one with step n of the other by ordinality (0017), so a run that records a call without an
//     observation - the obvious mistake on an early return or a panic path - silently pairs every
//     later call with the wrong output. BeginTool/EndTool make the pair atomically enough that
//     forgetting is not the default, and every exit path in the agent calls Abandon on any step
//     still open.
//   - a row is written for a failed run. The failures are the reason the table exists. Record is
//     therefore called from a defer in the agent loop, and a database that cannot be reached
//     downgrades to a log line instead of to a missing row about a row that never happened.
package logging

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"jada-backend/pkg/ids"
)

// DB is the narrow slice of the db package this recorder needs. Taking an interface rather than
// the concrete type keeps the trajectory writer testable without a server, which matters because
// the interesting cases - a run that errored halfway, a run whose tools returned nothing - are
// awkward to produce against a real database and trivial to produce against a fake.
type DB interface {
	Exec(ctx context.Context, sql string, args ...any) error
	Tenant() string
}

// Run is one agent turn: one user message, the tool loop it caused, and the answer.
type Run struct {
	mu sync.Mutex

	ConversationID string
	RunID          string
	ThreadID       string
	BotID          string
	UserID         string
	HumanInput     string
	Model          string

	started time.Time

	thoughts     []string
	actions      []map[string]any
	observations []map[string]any
	sources      []string
	steps        map[int]time.Time

	// open counts tool calls that began and never ended, so Abandon can close them.
	open int

	finalOutput string
	errMessage  string
	tokensIn    *int
	tokensOut   *int
	finished    bool
}

// NewRun starts the clock. threadID is the caller's chat thread; botID names this agent, and it is
// what vw_tool_performance and vw_agent_activity_summary group by, so it must be stable across
// deployments and distinct between agents. It is also half of the conversation's identity - see
// ids.Thread - because a thread string alone is a name that does not say who is on it, and three
// agents on one tenant proved that is not a detail.
func NewRun(threadID, message, botID, model string) *Run {
	return &Run{
		ConversationID: conversationID(botID, threadID),
		RunID:          newUUID(),
		ThreadID:       threadID,
		BotID:          botID,
		HumanInput:     message,
		Model:          model,
		started:        time.Now(),
		steps:          map[int]time.Time{},
	}
}

func (r *Run) Elapsed() time.Duration { return time.Since(r.started) }

// ID is the run identifier in the form pkg/turn's Trail interface asks for. The field is RunID and
// the method is ID because a method and a field of one name cannot coexist, and the interface is
// deliberately phrased for callers that are not this type.
func (r *Run) ID() string { return r.RunID }

// Steps is how many tool calls the run has recorded so far, which is also the index the next call
// takes. The agent asks for it instead of keeping its own counter because the counter and the array
// are the same fact, and two places that hold one fact disagree the first time a path returns early.
func (r *Run) Steps() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.actions)
}

// ConversationID is the uuid one thread's history with one agent is filed under. Exported for the
// read path that rehydrates history, which has to ask the same question the writer answers - same two
// arguments, same order, and a test that says so, because a reader that derived it differently would
// silently rehydrate nothing and every conversation would start over on every restart.
func ConversationID(botID, threadID string) string { return conversationID(botID, threadID) }

// Thought records assistant text produced in one iteration of the loop. In the streaming path
// this is the reasoning-out-loud the model emits before it calls a tool; it is the field that
// makes "why did it choose that tool" answerable.
func (r *Run) Thought(text string) {
	if strings.TrimSpace(text) == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.thoughts = append(r.thoughts, text)
}

// BeginTool records a call and returns its step number. Every step must be closed by exactly one
// of EndTool or Abandon.
func (r *Run) BeginTool(step int, name string, args map[string]any) {
	r.mu.Lock()
	defer r.mu.Unlock()

	input := args
	if input == nil {
		input = map[string]any{}
	}
	r.actions = append(r.actions, map[string]any{
		"tool":       name,
		"tool_input": input,
		"timestamp":  time.Now().UTC().Format(time.RFC3339Nano),
	})
	// The placeholder keeps the two arrays the same length from the moment the call begins, so a
	// panic or an early return between BeginTool and EndTool cannot leave a dangling step.
	r.observations = append(r.observations, map[string]any{
		"type":   "in_progress",
		"output": "",
	})
	r.steps[step] = time.Now()
	r.open++
}

// EndTool closes a step with its output. An error is recorded as data in the observation, which
// is what makes per-call failure visible in vw_tool_calls.observation_type - the thing 0017 had
// to state as not derivable because the Python writer put a class name in that field for results
// and errors alike.
func (r *Run) EndTool(step int, output string, callErr error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	kind := "result"
	if callErr != nil {
		kind = "error"
		output = callErr.Error()
	}
	if step < len(r.observations) {
		r.observations[step] = map[string]any{"type": kind, "output": output}
	} else {
		r.observations = append(r.observations, map[string]any{"type": kind, "output": output})
	}
	if r.open > 0 {
		r.open--
	}
}

// Abandon closes any step that began and never ended. Called on every exit path.
func (r *Run) Abandon() {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.closeOpenSteps()
}

// Finish closes the run. Both the answer and the error are recorded, and a run with an error is
// still written - that is the point.
func (r *Run) Finish(final string, runErr error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.finished {
		return
	}
	r.closeOpenSteps()
	r.finalOutput = final
	if runErr != nil {
		r.errMessage = runErr.Error()
	}
	r.finished = true
}

// closeOpenSteps is the only place the "a call that never returned is an error observation" rule
// exists, and both public paths above call it. Two copies of one rule is exactly what 0010's B25
// counts, and this file is the one that would drift silently: the second copy would differ only
// on a path someone forgot to test.
func (r *Run) closeOpenSteps() {
	for i := range r.observations {
		if t, _ := r.observations[i]["type"].(string); t == "in_progress" {
			r.observations[i] = map[string]any{
				"type":   "error",
				"output": "the run ended before this call returned",
			}
		}
	}
	r.open = 0
}

// Source records that this run touched a record, in "table:id" form. It goes into
// response_sources, which is the column that answers "what did the agent look at" without
// re-reading every tool output.
func (r *Run) Source(table string, id any) {
	if id == nil {
		return
	}
	s := fmt.Sprintf("%s:%v", table, id)
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, e := range r.sources {
		if e == s {
			return
		}
	}
	r.sources = append(r.sources, s)
}

// Usage carries token counts when the provider streams them. nil means the endpoint did not
// report usage, which is recorded as an absent fact rather than a zero.
func (r *Run) Usage(in, out int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.tokensIn, r.tokensOut = &in, &out
}

// Row is the trajectory in the shape the views expect, exposed for tests and for the
// LOG_AGENT_INTERACTIONS=false path, where the same structure is printed instead of inserted.
func (r *Run) Row() map[string]any {
	r.mu.Lock()
	defer r.mu.Unlock()

	acts := r.actions
	if acts == nil {
		acts = []map[string]any{}
	}
	obs := r.observations
	if obs == nil {
		obs = []map[string]any{}
	}
	srcs := r.sources
	if srcs == nil {
		srcs = []string{}
	}

	// The three jsonb columns and the text[] column are handed over in their Go shapes, not as
	// pre-married strings: pgx encodes []map[string]any into a jsonb parameter and []string into a
	// text[] one, and a string bound into a jsonb column would have to be cast, which is how a
	// double-encoded array - a JSON string containing an array - reaches the database and makes
	// vw_tool_calls answer zero rows for a run that made four.
	row := map[string]any{
		"conversation_id":   r.ConversationID,
		"run_id":            r.RunID,
		"thread_id":         r.ThreadID,
		"bot_id":            r.BotID,
		"human_input":       r.HumanInput,
		"agent_thoughts":    r.thoughts,
		"actions_taken":     acts,
		"tool_observations": obs,
		"response_sources":  srcs,
		"final_output":      r.finalOutput,
		"model_used":        r.Model,
		"duration_ms":       int(time.Since(r.started).Milliseconds()),
		"step_count":        len(r.actions),
	}
	if r.UserID != "" {
		row["user_id"] = r.UserID
	}
	if r.errMessage != "" {
		row["error_message"] = r.errMessage
	}
	if r.tokensIn != nil || r.tokensOut != nil {
		u := map[string]any{}
		if r.tokensIn != nil {
			u["prompt_tokens"] = *r.tokensIn
		}
		if r.tokensOut != nil {
			u["completion_tokens"] = *r.tokensOut
		}
		row["token_usage"] = u
	}
	return row
}

// Recorder writes runs to agent_interactions.
type Recorder struct {
	db      DB
	enabled bool
}

func NewRecorder(d DB, enabled bool) *Recorder { return &Recorder{db: d, enabled: enabled} }

func (rc *Recorder) Enabled() bool { return rc != nil && rc.enabled && rc.db != nil }

// Record inserts one row. The error it returns is for the caller to log, never to act on: a run
// that cannot be recorded has already answered the human, and losing the chat to lose the audit
// row would be the wrong trade in the opposite direction from ADR-001.
func (rc *Recorder) Record(ctx context.Context, r *Run) error {
	if r == nil {
		return nil
	}
	r.Abandon()

	if !rc.Enabled() {
		slog.Debug("trajectory not recorded", "run_id", r.RunID, "row", r.Row())
		return nil
	}

	row := r.Row()

	// "timestamp" is a reserved word unquoted, and the column pair with created_at is the one
	// 0010's register distinguishes: timestamp is when the interaction happened, created_at is
	// when the row was written. Both are left to their column defaults here, except timestamp,
	// which is set explicitly because a run that is recorded in a later transaction than it
	// happened should not inherit the recording time as its own.
	// The column list is spelled out rather than INSERT ... SELECT, and every jsonb parameter is
	// cast in the statement: pgx sends a []map[string]any as a text literal, and an uncast text
	// parameter into a jsonb column is a 42804 that reads like a type bug rather than a missing cast.
	sql := `INSERT INTO agent_interactions (
              conversation_id, run_id, telegram_chat_id, bot_id, user_id, "timestamp",
              human_input, agent_thoughts, actions_taken, tool_observations,
              final_output, response_sources, model_used, token_usage,
              error_message, duration_ms
          ) VALUES (
              $1::uuid, $2, $3, $4, $5, now(),
              $6, $7::text[], $8::jsonb, $9::jsonb,
              $10, $11::jsonb, $12, $13::jsonb,
              $14, $15
          )`

	thoughts, _ := row["agent_thoughts"].([]string)
	if thoughts == nil {
		thoughts = []string{}
	}

	err := rc.db.Exec(ctx, sql,
		row["conversation_id"], row["run_id"], nilIfEmpty(row["thread_id"]),
		row["bot_id"], nilIfEmpty(row["user_id"]),
		row["human_input"], thoughts,
		jsonParam(row["actions_taken"]), jsonParam(row["tool_observations"]),
		nilIfEmpty(row["final_output"]), jsonParam(row["response_sources"]), row["model_used"],
		jsonParam(row["token_usage"]), nilIfEmpty(row["error_message"]),
		row["duration_ms"],
	)
	if err != nil {
		return err
	}

	slog.Debug("trajectory recorded",
		"run_id", r.RunID, "conversation_id", r.ConversationID,
		"steps", row["step_count"], "duration_ms", row["duration_ms"],
		"errored", row["error_message"] != nil)
	return nil
}

func nilIfEmpty(v any) any {
	if s, ok := v.(string); ok && s == "" {
		return nil
	}
	return v
}

// textArray renders a []string as a Postgres text[] literal. pgx would prefer a []string bound
// directly, and that is what happens for agent_thoughts below; this helper stays for callers that
// hold a JSON value.
// jsonParam marshals a value for a jsonb parameter. A value that cannot be marshalled becomes
// "null" rather than an error, because a trajectory row that fails to write over an unencodable
// tool argument would discard the whole run - human_input, error and all - to protect one column.
func jsonParam(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		slog.Error("trajectory field could not be encoded; recording null", "err", err)
		return json.RawMessage("null")
	}
	return b
}

func conversationID(botID, threadID string) string { return ids.Thread(botID, threadID) }

func newUUID() string { return ids.New() }
