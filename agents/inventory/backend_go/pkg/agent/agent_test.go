package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"

	"jada-backend/pkg/inventory"
	"jada-backend/pkg/logging"
	"jada-backend/pkg/tools"
	"jada-backend/pkg/turn"
)

func TestMain(m *testing.M) {
	slog.SetDefault(slog.New(slog.NewTextHandler(io.Discard, nil)))
	os.Exit(m.Run())
}

// captureRecorder is the trajectory sink: the row the loop decided to write, if any.
type captureRecorder struct {
	mu     sync.Mutex
	rows   []map[string]any
	runs   []*logging.Run
	record *logging.Recorder
}

func newCaptureRecorder() *captureRecorder {
	c := &captureRecorder{}
	c.record = logging.NewRecorder(c, true)
	return c
}

// logging.Recorder takes a DB interface with one method, so the sink implements it and reads the
// statement's own arguments back out. The alternative - inspecting the Run - would not prove that a
// row reached the database, which is the claim under test.
func (c *captureRecorder) Exec(_ context.Context, _ string, args ...any) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.rows = append(c.rows, map[string]any{"args": args})
	return nil
}

func (c *captureRecorder) Tenant() string { return "tenant-under-test" }

func (c *captureRecorder) Count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.rows)
}

func (c *captureRecorder) Last() []any {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.rows) == 0 {
		return nil
	}
	return c.rows[len(c.rows)-1]["args"].([]any)
}

// fakeModel is an OpenAI-compatible endpoint that replays a script.
//
// The agent loop is worth testing against an HTTP server rather than a seam because the parts that go
// wrong in production are the parts a seam would hide: how a tool call arrives split across SSE
// chunks, whether the tool round-trip actually feeds the model an observation, whether the trajectory
// is written when the model answers with a 500.
func fakeModel(t *testing.T, script []string) *httptest.Server {
	t.Helper()
	var n int
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		body, _ := io.ReadAll(r.Body)

		var req struct {
			Stream   bool             `json:"stream"`
			Messages []map[string]any `json:"messages"`
		}
		if err := json.Unmarshal(body, &req); err != nil {
			t.Fatalf("the agent sent the model unparseable JSON: %v", err)
		}

		if n == 0 {
			// The system prompt and the user turn are the only messages on the first call; a second
			// call means a tool result came back, and the loop is only honest if it sent one.
			if len(req.Messages) < 2 {
				t.Errorf("the first request carried %d messages", len(req.Messages))
			}
		}

		out := "the script ran out"
		if n < len(script) {
			out = script[n]
		}
		n++

		if !req.Stream {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, out)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		flusher := w.(http.Flusher)
		fmt.Fprintln(w, out)
		flusher.Flush()
	}))
}

func sseChunks(chunks ...string) string {
	var b strings.Builder
	for _, c := range chunks {
		fmt.Fprintf(&b, "data: %s\n\n", c)
	}
	b.WriteString("data: [DONE]\n\n")
	return b.String()
}

func toolCallChunk(id, name, argFragment string, index int) string {
	return fmt.Sprintf(`{"choices":[{"index":0,"delta":{"tool_calls":[{"index":%d,"id":%q,`+
		`"type":"function","function":{"name":%q,"arguments":%q}}]}}]}`,
		index, id, name, argFragment)
}

func textChunk(s string) string {
	return fmt.Sprintf(`{"choices":[{"index":0,"delta":{"content":%q}}]}`, s)
}

// runTurn drives one turn to completion and returns every event it emitted.
//
// RunChatStream closes its channel, so waiting for the drain goroutine is a real end-of-turn signal
// rather than a sleep, and the trajectory's recording defer has necessarily run by the time this
// returns. An earlier draft of this file drained the channel in the foreground and started the loop in
// a goroutine, which is a guaranteed deadlock: the drain blocks on an empty channel that the loop,
// blocked on a full one, cannot reach.
func runTurn(am *AgentManager, threadID, message string) []SSEEvent {
	events := make(chan SSEEvent, 256)
	var got []SSEEvent
	done := make(chan struct{})
	go func() {
		for ev := range events {
			got = append(got, ev)
		}
		close(done)
	}()
	am.RunChatStream(context.Background(), threadID, message, events)
	<-done
	return got
}

func newTestManager(t *testing.T, url string, list []tools.ToolDefinition) *AgentManager {
	t.Helper()
	t.Setenv("LLM_PROVIDER", "local")
	t.Setenv("VLLM_BASE_URL", url+"/v1")
	t.Setenv("VLLM_MODEL", "test-model")
	am := NewAgentManager(list)
	// Every turn of a test must be attributable, or the tool's idempotency key vanishes and the
	// scenario being tested is not the one that runs in production.
	return am
}

// TestToolCallRoundTripIsRecorded is the loop's central claim, end to end: the model asks for a tool,
// the tool runs, the answer comes back, and one trajectory row says so with its arrays aligned.
//
// The tool call arrives in three SSE fragments, which is what vLLM actually does with arguments: the
// name in one chunk and the JSON in pieces after it. A loop that assumed one chunk per call would
// register a tool with no arguments, and the symptom is a refusal that reads like a data problem.
func TestToolCallRoundTripIsRecorded(t *testing.T) {
	var calls int
	srv := fakeModel(t, []string{
		sseChunks(
			textChunk("Looking that up."),
			toolCallChunk("call_1", "probe", `{"customer_`, 0),
			toolCallChunk("", "", `name": "Acme"}`, 0),
		),
		sseChunks(textChunk("Acme is a customer. ")),
		sseChunks(textChunk("Acme is a customer, active since March.")),
	})
	defer srv.Close()

	probe := tools.ToolDefinition{
		Name:        "probe",
		Description: "test tool",
		Policy:      tools.ToolPolicy{ReadOnly: true},
		ExecuteContext: func(_ context.Context, args map[string]any) (string, error) {
			calls++
			// The arguments must have reassembled, or the loop is calling tools with the wrong input
			// and recording that it did so.
			if args["customer_name"] != "Acme" {
				t.Errorf("the tool received %#v; the streamed fragments did not reassemble", args)
			}
			return `[{"id":1,"name":"Acme"}]`, nil
		},
	}

	am := newTestManager(t, srv.URL, []tools.ToolDefinition{probe})
	rec := newCaptureRecorder()
	am.AttachRecorder(rec.record)

	runTurn(am, "web:test-1", "who is Acme?")

	if calls != 1 {
		t.Errorf("the tool ran %d times, want 1", calls)
	}
	if rec.Count() != 1 {
		t.Fatalf("%d trajectory rows were written, want exactly 1 - one row per run is the rule",
			rec.Count())
	}

	args := rec.Last()
	// Positions follow the INSERT's column list, which TestColumnListMatchesArgs pins in pkg/logging.
	// Reading them by index here is the point: this is the pairing check, across the real loop.
	human, _ := args[5].(string)
	if human != "who is Acme?" {
		t.Errorf("human_input = %q", human)
	}
	final, _ := args[9].(string)
	// The loop breaks as soon as a turn asks for no tools, so the third scripted chunk is never
	// fetched and the answer is the text from the turns that ran, joined. An expectation of
	// "active since March" here would have been a claim about a different loop.
	if !strings.Contains(final, "Acme is a customer") {
		t.Errorf("final_output = %q, want the answer that followed the tool call", final)
	}
	if n := rec.Count(); n != 1 {
		t.Errorf("%d rows for one turn", n)
	}

	acts := decodeJSONArray(t, args[7])
	obs := decodeJSONArray(t, args[8])
	if len(acts) != 1 || len(obs) != 1 {
		t.Fatalf("actions=%d observations=%d, want 1 and 1", len(acts), len(obs))
	}
	if acts[0]["tool"] != "probe" {
		t.Errorf("the run recorded a call to %v", acts[0]["tool"])
	}
	input, _ := acts[0]["tool_input"].(map[string]any)
	if input["customer_name"] != "Acme" {
		t.Errorf("the recorded tool_input is %#v", acts[0]["tool_input"])
	}
	if obs[0]["type"] != "result" {
		t.Errorf("the observation is typed %v; vw_tool_calls reports per-call success from that field",
			obs[0]["type"])
	}
	if out, _ := obs[0]["output"].(string); !strings.Contains(out, "Acme") {
		t.Errorf("the observation output is %q", obs[0]["output"])
	}
}

// TestModelFailureStillWritesARow is ADR-001 applied to the loop: the run that produced nothing is the
// one a reader most needs.
//
// The reference implementation returned as soon as the model call failed, which meant a 500 from the
// inference server left no trace at all - and "the agent went quiet" is exactly the incident report
// that needs the row.
func TestModelFailureStillWritesARow(t *testing.T) {
	var n int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		io.Copy(io.Discard, r.Body)
		n++
		if n == 1 {
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprint(w, sseChunks(toolCallChunk("c1", "probe", `{}`, 0)))
			return
		}
		http.Error(w, `{"error":"upstream exploded"}`, http.StatusBadGateway)
	}))
	defer srv.Close()

	probe := tools.ToolDefinition{
		Name:           "probe",
		Description:    "test tool",
		ExecuteContext: func(context.Context, map[string]any) (string, error) { return "ok", nil },
	}

	am := newTestManager(t, srv.URL, []tools.ToolDefinition{probe})
	rec := newCaptureRecorder()
	am.AttachRecorder(rec.record)

	runTurn(am, "web:test-fail", "go")

	args := rec.Last()
	errMsg, _ := args[13].(string)
	if !strings.Contains(errMsg, "502") {
		t.Errorf("error_message = %q; the row exists but does not say what happened", errMsg)
	}
	if len(decodeJSONArray(t, args[7])) != 1 {
		t.Error("the tool call the run did make is missing from the trajectory, so the row describes " +
			"a run that got further than it did")
	}
}

func decodeJSONArray(t *testing.T, v any) []map[string]any {
	t.Helper()
	// json.RawMessage and []byte are the same bytes and different types: a single-case assertion on
	// []byte compiles, and fails, because the recorder marshals through RawMessage.
	var b []byte
	switch value := v.(type) {
	case json.RawMessage:
		b = value
	case []byte:
		b = value
	default:
		t.Fatalf("the jsonb column was bound as %T, not encoded JSON", v)
	}
	var out []map[string]any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("not a JSON array: %v in %s", err, b)
	}
	return out
}

// TestUnknownToolIsAnObservationNotATrajectory checks the path where the model names a tool that was
// never registered - which happens the moment the prompt and the wiring disagree, the same fault 4.5
// describes about a schema and a tool.
func TestUnknownToolIsAnObservationNotATrajectory(t *testing.T) {
	var n int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		io.Copy(io.Discard, r.Body)
		n++
		w.Header().Set("Content-Type", "text/event-stream")
		if n == 1 {
			fmt.Fprint(w, sseChunks(toolCallChunk("c1", "no_such_tool", `{}`, 0)))
			return
		}
		fmt.Fprint(w, sseChunks(textChunk("I cannot do that.")))
	}))
	defer srv.Close()

	am := newTestManager(t, srv.URL, []tools.ToolDefinition{{
		Name:           "probe",
		Description:    "the only tool",
		ExecuteContext: func(context.Context, map[string]any) (string, error) { return "ok", nil },
	}})
	rec := newCaptureRecorder()
	am.AttachRecorder(rec.record)

	runTurn(am, "web:test-unknown", "do the impossible")
	args := rec.Last()
	acts := decodeJSONArray(t, args[7])
	obs := decodeJSONArray(t, args[8])
	if len(acts) != 1 || len(obs) != 1 {
		t.Fatalf("actions=%d observations=%d: a call to a tool that does not exist still has to be a "+
			"paired step, or every later step pairs wrongly", len(acts), len(obs))
	}
	if obs[0]["type"] != "error" {
		t.Errorf("an unregistered tool was recorded as %v, not an error", obs[0]["type"])
	}
}

// TestToolOrderingSurvivesOutOfOrderChunks guards the pairing vw_tool_calls performs.
//
// A provider may interleave the deltas of two calls, and the accumulation is keyed by the chunk's
// index. Sorting them any other way pairs step 0 of actions_taken with step 1's output, and the run
// then reads as if the wrong tool had returned the right answer - a trajectory that misleads is worse
// than one that is missing.
func TestToolOrderingSurvivesOutOfOrderChunks(t *testing.T) {
	var order []string
	var mu sync.Mutex

	srv := fakeModel(t, []string{
		// Each call's arguments arrive in two fragments, and the two calls interleave with index 1
		// first: this is what a provider actually emits, and it is the case that would pair step 0
		// of one array with step 1 of the other if assembly sorted by arrival.
		sseChunks(
			toolCallChunk("b", "second", `{"n":`, 1),
			toolCallChunk("a", "first", `{"n":`, 0),
			toolCallChunk("", "", `2}`, 1),
			toolCallChunk("", "", `1}`, 0),
		),
		sseChunks(textChunk("done")),
		sseChunks(textChunk("done")),
	})
	defer srv.Close()

	mk := func(name string) tools.ToolDefinition {
		return tools.ToolDefinition{
			Name:        name,
			Description: "records that it ran",
			ExecuteContext: func(_ context.Context, args map[string]any) (string, error) {
				mu.Lock()
				order = append(order, fmt.Sprintf("%s:%v", name, args["n"]))
				mu.Unlock()
				return "ok", nil
			},
		}
	}

	am := newTestManager(t, srv.URL, []tools.ToolDefinition{mk("first"), mk("second")})
	rec := newCaptureRecorder()
	am.AttachRecorder(rec.record)

	runTurn(am, "web:test-order", "both")
	args := rec.Last()
	acts := decodeJSONArray(t, args[7])
	obs := decodeJSONArray(t, args[8])
	if len(acts) != 2 || len(obs) != 2 {
		t.Fatalf("actions=%d observations=%d, want 2 and 2", len(acts), len(obs))
	}

	mu.Lock()
	defer mu.Unlock()
	// Index order, not arrival order: the chunks above arrive with index 1 first on purpose.
	if acts[0]["tool"] != "first" || acts[1]["tool"] != "second" {
		t.Errorf("the trajectory recorded %v then %v; vw_tool_calls would report the steps in that order",
			acts[0]["tool"], acts[1]["tool"])
	}
	if len(order) != 2 || order[0] != "first:1" {
		t.Errorf("the tools ran in order %v", order)
	}
}

// TestResetDoesNotLoseTheHistory is the sentence the endpoint's own message promises: /api/reset
// clears what the model is shown, not what the database recorded.
func TestResetDoesNotLoseTheHistory(t *testing.T) {
	srv := fakeModel(t, []string{sseChunks(textChunk("one")), sseChunks(textChunk("two"))})
	defer srv.Close()

	am := newTestManager(t, srv.URL, nil)
	am.ResetHistory("web:x")
	am.appendHistory("web:x", ChatMessage{Role: "user", Content: "hi"})
	if len(am.GetHistory("web:x")) != 1 {
		t.Fatal("the history was not appended")
	}
	am.ResetHistory("web:x")
	if got := am.GetHistory("web:x"); len(got) != 0 {
		t.Errorf("after reset the history still holds %d messages", len(got))
	}
}

// TestHistoryIsBounded protects the context window: the loop trims to MaxHistoryMessages, and a
// conversation that grew without bound would eventually fail the request at the model server with an
// error that names neither the cause nor the turn.
func TestHistoryIsBounded(t *testing.T) {
	am := NewAgentManager(nil)
	for i := 0; i < MaxHistoryMessages*3; i++ {
		am.appendHistory("web:bound", ChatMessage{Role: "user", Content: fmt.Sprintf("m%d", i)})
	}
	h := am.GetHistory("web:bound")
	if len(h) != MaxHistoryMessages {
		t.Fatalf("history holds %d messages, capped at %d", len(h), MaxHistoryMessages)
	}
	// The most recent must survive: trimming from the wrong end would keep the first exchanges and
	// drop the one the caller just made, which reads as amnesia rather than as a limit.
	last := h[len(h)-1].Content
	if !strings.Contains(last, fmt.Sprintf("m%d", MaxHistoryMessages*3-1)) {
		t.Errorf("the newest message was the one dropped: %q", last)
	}
}

// TestRunIDReachesTheTool is the end-to-end form of the ADR-005 wiring, and the reason pkg/turn
// exists.
//
// The claim key a write door receives is derived from the run, so if the loop failed to put the run in
// the context the tools run against, every write would go out with a NULL key: no error, no log line,
// and a duplicate row on every retry. The symptom appears weeks later in a customer's history, so the
// check belongs here, where the plumbing is assembled, rather than only in the tool that consumes it.
//
// It is asserted through the recorded row rather than through a test seam: the run is its own trail, so
// there is nothing to inject, and a hook that let a test substitute one would stop covering the path
// production takes.
func TestRunIDReachesTheTool(t *testing.T) {
	var gotRun string

	srv := fakeModel(t, []string{
		sseChunks(toolCallChunk("c1", "probe", `{}`, 0)),
		sseChunks(textChunk("done")),
		sseChunks(textChunk("done")),
	})
	defer srv.Close()

	probe := tools.ToolDefinition{
		Name:        "probe",
		Description: "reports what the turn gave it",
		ExecuteContext: func(ctx context.Context, _ map[string]any) (string, error) {
			gotRun = turn.RunID(ctx)
			turn.Source(ctx, "entities", int64(5))
			return "ok", nil
		},
	}

	am := newTestManager(t, srv.URL, []tools.ToolDefinition{probe})
	rec := newCaptureRecorder()
	am.AttachRecorder(rec.record)

	runTurn(am, "web:test-runid", "go")

	if gotRun == "" {
		t.Fatal("a tool ran with no run id, so its writes carry no idempotency claim")
	}
	if len(gotRun) != 36 {
		t.Errorf("the run id the tool saw is %q, not a uuid", gotRun)
	}

	args := rec.Last()
	if rid, _ := args[1].(string); rid != gotRun {
		t.Errorf("the row's run_id is %q but the tool saw %q - two identities for one run", rid, gotRun)
	}

	// response_sources is $11, which is args[10]: the INSERT has sixteen columns and fifteen bound
	// arguments, because the timestamp column is filled by now(). Reading by index is the point of the
	// test, so the offset is spelled out rather than guessed - pkg/logging's
	// TestColumnListMatchesArgs is what keeps this arithmetic honest.
	src := decodeStringArray(t, args[10])
	if len(src) != 1 || src[0] != "entities:5" {
		t.Errorf("response_sources = %v, want the one record the tool touched", src)
	}
}

// decodeStringArray is decodeJSONArray for the jsonb column that holds strings rather than objects.
func decodeStringArray(t *testing.T, v any) []string {
	t.Helper()
	var b []byte
	switch value := v.(type) {
	case json.RawMessage:
		b = value
	case []byte:
		b = value
	default:
		t.Fatalf("the jsonb column was bound as %T, not encoded JSON", v)
	}
	var out []string
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("not a JSON array of strings: %v in %s", err, b)
	}
	return out
}

// TestAgentIdentityIsOneValueForBothAuditColumns guards a drift that raised no error and failed no
// test: communications.agent_id came from AGENT_BOT_ID and agent_interactions.bot_id from AGENT_ROLE,
// so deploying this binary as a second role moved one column and left the other at the default. The
// trail then says two agents were in the room, and anything that groups by the identity -
// vw_agent_activity_summary above all - splits one agent's work in half, which reads as a quiet agent
// rather than as a broken setting.
//
// It lives here because the comparison needs both packages and pkg/agent is the only one that imports
// the other: the loop owns the trajectory row, crm owns the interaction row, and neither should have
// to know the other's name.
func TestAgentIdentityIsOneValueForBothAuditColumns(t *testing.T) {
	// Unset and set are the two states a deployment can be in, and both have to agree. An assertion
	// made only with a value set would pass for two readers of two keys that happen to fall back to
	// the same string.
	for _, role := range []string{"", "front_desk"} {
		t.Setenv(inventory.EnvAgentRole, role)
		want := AgentName()
		got := inventory.AgentName()
		if got != want {
			t.Errorf("AGENT_ROLE=%q: agent_interactions.bot_id would be %q, inventory's own writes "+
				"%q - one process, two identities in the trail", role, want, got)
		}
		if role == "" && want != inventory.DefaultAgentRole {
			t.Errorf("with AGENT_ROLE unset the name is %q, not the documented default %q",
				want, inventory.DefaultAgentRole)
		}
	}
}

// TestRehydrateAsksForThisAgentsConversation is the read path, asserted rather than trusted. History
// rehydration is the only place this process reads agent_interactions to decide what it already knows,
// and the argument that matters is the conversation id - derived here from (bot, thread), so a thread
// string reused against another agent's port cannot pull this agent's turns, and cannot lose them into
// another's.
func TestRehydrateAsksForThisAgentsConversation(t *testing.T) {
	q := &fakeQuerier{}
	am := NewAgentManager(nil)
	am.BotID = "sales"
	if n := am.Rehydrate(context.Background(), q, "web:shared-thread"); n != 0 {
		t.Fatalf("an empty history rehydrated %d messages", n)
	}
	if len(q.sqls) != 1 {
		t.Fatalf("rehydration sent %d queries, want 1", len(q.sqls))
	}
	asked, want := q.args[0][0], logging.ConversationID("sales", "web:shared-thread")
	if asked != want {
		t.Errorf("rehydration asked for conversation %v; the writer files this agent's turns under %v",
			asked, want)
	}
	if other := logging.ConversationID("inventory", "web:shared-thread"); asked == other {
		t.Errorf("the same thread names one conversation for two agents (%s), so this process would read "+
			"another agent's turns as its own history", asked)
	}
}

type fakeQuerier struct {
	sqls []string
	args [][]any
}

func (f *fakeQuerier) Query(_ context.Context, sql string, args ...any) ([]map[string]any, error) {
	f.sqls = append(f.sqls, sql)
	f.args = append(f.args, args)
	return nil, nil
}

func (f *fakeQuerier) Call(_ context.Context, name string, args []any) ([]map[string]any, error) {
	f.sqls = append(f.sqls, "CALL "+name)
	f.args = append(f.args, args)
	return nil, nil
}
