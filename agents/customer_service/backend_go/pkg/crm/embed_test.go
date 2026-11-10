package crm

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"jada-backend/pkg/embed"
	"jada-backend/pkg/logging"
)

// The keeper's tests. What they hold is not "the code runs" but the three sentences the tick can tell
// a reader, because the tick has no human on the other end of it: how much of the corpus is
// searchable, whether this run moved any of it, and whether it failed while trying. agents/sales'
// keeper found out the hard way that the third of those can be reported as the second - 0031's
// "0 expired collected" beside a 42501 - and the shape of that failure is exactly what a schedule
// with nobody watching produces.

// routed is a Querier that answers by what was asked, because the keeper makes four different kinds
// of call in one tick and a fake that returns one canned row for all of them cannot tell a coverage
// scan from a write.
type routed struct {
	calls  []fakeCall
	status []map[string]any
	// statusSeq answers successive coverage scans with different rows, which is the only way to test
	// that the tick re-reads the register instead of adding to what it saw first.
	statusSeq [][]map[string]any
	statusN   int
	queue     []map[string]any
	doorRow   []map[string]any
	doorErr   error
	memory    []map[string]any
}

func (r *routed) Query(_ context.Context, sql string, args ...any) ([]map[string]any, error) {
	r.calls = append(r.calls, fakeCall{sql: sql, args: args})
	switch {
	case strings.Contains(sql, "vw_embedding_status"):
		if r.statusN < len(r.statusSeq) {
			defer func() { r.statusN++ }()
			return r.statusSeq[r.statusN], nil
		}
		return r.status, nil
	case strings.Contains(sql, "vw_unembedded_communications"):
		return r.queue, nil
	}
	return nil, fmt.Errorf("unexpected query: %s", sql)
}

func (r *routed) Call(_ context.Context, name string, args []any) ([]map[string]any, error) {
	r.calls = append(r.calls, fakeCall{name: name, args: args})
	switch name {
	case "search_similar_communications":
		return r.doorRow, nil
	case "embed_communications":
		if r.doorErr != nil {
			return nil, r.doorErr
		}
		return r.doorRow, nil
	case "get_memory":
		return r.memory, nil
	case "save_memory":
		return []map[string]any{{"success": true}}, nil
	}
	return nil, fmt.Errorf("unexpected call: %s", name)
}

func (r *routed) called(want string) bool {
	for _, c := range r.calls {
		if c.name == want || strings.Contains(c.sql, want) {
			return true
		}
	}
	return false
}

// embedder is a fake server that answers the declared width, and can be told to answer something
// else or nothing at all.
func embedder(t *testing.T, width int, fail bool) *embed.Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if fail {
			http.Error(w, "upstream unavailable", http.StatusBadGateway)
			return
		}
		var body struct {
			Input []string `json:"input"`
		}
		json.NewDecoder(req.Body).Decode(&body)
		data := make([]map[string]any, len(body.Input))
		for i := range body.Input {
			v := make([]float32, width)
			for j := range v {
				v[j] = 0.001
			}
			data[i] = map[string]any{"index": i, "embedding": v}
		}
		json.NewEncoder(w).Encode(map[string]any{"data": data})
	}))
	t.Cleanup(srv.Close)
	return &embed.Client{
		BaseURL: srv.URL, Model: "fake/embed:latest", Dimensions: embed.SchemaDimensions,
		BatchSize: 8, HTTP: srv.Client(),
	}
}

func status(embedded, total int, verdict, model string) []map[string]any {
	return []map[string]any{{
		"rows_total": int64(total), "rows_embedded": int64(embedded),
		"verdict": verdict, "embedded_by": model, "served_by": "http://fake/v1",
		"newest_at": "2026-11-09T12:00:00Z",
	}}
}

func queued(ids ...int64) []map[string]any {
	out := make([]map[string]any, 0, len(ids))
	for _, id := range ids {
		out = append(out, map[string]any{
			"communication_id": id, "customer_name": "Acme", "nothing_to_embed": false,
			"embeddable_text": fmt.Sprintf("the customer said something number %d", id),
		})
	}
	return out
}

func TestKeeperWritesThroughTheDoorAndClaimsTheBatch(t *testing.T) {
	q := &routed{
		status:  status(2, 25, "PARTIAL", "fake/embed:latest"),
		queue:   queued(3, 4),
		doorRow: []map[string]any{{"success": true, "rows_embedded": int32(2), "rows_refused": int32(0), "message": "2 of 2 offered row(s) embedded"}},
		memory:  []map[string]any{{"content": `{"old":1}`}},
	}
	res, err := RunEmbeddings(context.Background(), q, embedder(t, embed.SchemaDimensions, false),
		logging.NewRecorder(nil, false))
	if err != nil {
		t.Fatalf("a healthy tick returned an error: %v", err)
	}
	if res.Queued != 2 || res.Offered != 2 || res.Embedded != 2 {
		t.Fatalf("the tick's own numbers are wrong: %+v", res)
	}
	if !q.called("embed_communications") {
		t.Fatal("the keeper wrote to communications directly: the door is the only writer 0035 allows")
	}

	var call *fakeCall
	for i := range q.calls {
		if q.calls[i].name == "embed_communications" {
			call = &q.calls[i]
		}
	}
	// The arity assertion every other door in this package has: the door defaults its last two
	// parameters, so a short call is not a type error, it is a different branch - here, no claim and
	// no served_by, and a retry of a half-finished batch that looks like two batches.
	if len(call.args) != 4 {
		t.Fatalf("embed_communications was called with %d positional arguments, want 4 "+
			"(items, model, served_by, claim)", len(call.args))
	}
	if call.args[1] != "fake/embed:latest" {
		t.Errorf("position 1 must name the embedder, because that is what embedding_space refuses on: %#v",
			call.args[1])
	}
	k, ok := call.args[3].(string)
	if !ok || len(k) != 36 || strings.Count(k, "-") != 4 {
		t.Errorf("the claim is not in the last position: %#v", call.args[3])
	}

	// The batch the door receives must be the rows the queue named, in the order the queue named
	// them. A vector attached to the wrong id is invisible forever: it is the right width, it is
	// valid, and it describes a conversation that did not say it.
	var items []map[string]any
	if err := json.Unmarshal([]byte(call.args[0].(string)), &items); err != nil {
		t.Fatalf("the batch is not the JSON the door expects: %v", err)
	}
	if len(items) != 2 {
		t.Fatalf("%d items offered for 2 queued rows", len(items))
	}
	for i, want := range []int64{3, 4} {
		if got, _ := items[i]["communication_id"].(float64); int64(got) != want {
			t.Errorf("item %d is communication_id %v, want %d - the pairing is the whole feature",
				i, items[i]["communication_id"], want)
		}
	}
}

// filed is a logging.DB that keeps the recorder's parameters instead of running the INSERT. The seam
// exists because RunEmbeddings builds its Run and files it in a defer: the arrays a tick wrote are
// reachable nowhere else, and a schedule with no human on the other end is only ever audited through
// them.
type filed struct{ rows [][]any }

func (f *filed) Exec(_ context.Context, _ string, args ...any) error {
	f.rows = append(f.rows, args)
	return nil
}
func (f *filed) Tenant() string { return "00000000-0000-0000-0000-000000000001" }

// filedArray decodes one jsonb parameter of a recorded row. jsonParam hands the recorder a
// json.RawMessage, so anything else means the recorder's shape moved under this test.
func filedArray(t *testing.T, v any) []map[string]any {
	t.Helper()
	raw, ok := v.(json.RawMessage)
	if !ok {
		t.Fatalf("the trajectory column arrived as %T, want json.RawMessage", v)
	}
	var out []map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("the trajectory column is not the array the views expect: %v", err)
	}
	return out
}

// The trajectory the tick leaves behind, asserted rather than assumed. Every other test in this file
// reads EmbedResult, which is what the tick told the log; this one reads what it filed, which is the
// only version anyone debugs from six weeks later.
//
// The bug it is written against: the door call was closed by EndTool and never opened by BeginTool,
// and EndTool appends when the slot does not exist. So on a tick that embedded something - and only
// on such a tick, which is why 167 conversational runs were paired and every backfill was not - the
// two arrays came out 4 against 5, and vw_tool_calls, which joins them by position because they carry
// no key to join on, printed each later step's answer under the previous step's name.
func TestATickThatEmbeddedSomethingFilesEveryCallItMade(t *testing.T) {
	q := &routed{
		statusSeq: [][]map[string]any{
			status(0, 26, "EMPTY", "fake/embed:latest"),
			status(26, 26, "COMPLETE", "fake/embed:latest"),
		},
		queue: queued(3, 4),
		doorRow: []map[string]any{{"success": true, "rows_embedded": int32(2), "rows_refused": int32(0),
			"message": "2 of 2 offered row(s) embedded at 1536 dimensions by fake/embed:latest"}},
		memory: []map[string]any{{"content": `{"old":1}`}},
	}
	f := &filed{}
	if _, err := RunEmbeddings(context.Background(), q,
		embedder(t, embed.SchemaDimensions, false), logging.NewRecorder(f, true)); err != nil {
		t.Fatalf("a healthy tick returned an error: %v", err)
	}
	if len(f.rows) != 1 {
		t.Fatalf("%d trajectory rows filed for one tick, want exactly 1", len(f.rows))
	}
	args := f.rows[0]
	// Said out loud because this test reaches into the INSERT by position: actions_taken is 7 and
	// tool_observations is 8. A recorder that changed its column list must fail here rather than read
	// the wrong slot and pass.
	if len(args) != 15 {
		t.Fatalf("the recorder passes %d parameters, want 15 - update this test with the column list",
			len(args))
	}

	acts, obs := filedArray(t, args[7]), filedArray(t, args[8])

	// Equal length is pkg/logging's stated contract, and the half that is easy to keep by accident.
	if len(acts) != len(obs) {
		t.Fatalf("actions=%d observations=%d: step n of one now answers a different call than step n of "+
			"the other, which is how a debug view starts lying", len(acts), len(obs))
	}
	if len(acts) != 5 {
		t.Fatalf("%d steps filed, want the five a working tick makes: coverage, queue, embedder, door, "+
			"coverage", len(acts))
	}

	// The half that takes deliberate work: the names and the answers have to be the same call's, so a
	// reordering that preserved the length could not pass.
	if acts[3]["tool"] != "embed_communications" {
		t.Errorf("step 3 names %v, want embed_communications - the only write in the tick", acts[3]["tool"])
	}
	if out, _ := obs[3]["output"].(string); !strings.Contains(out, "2 of 2 offered") {
		t.Errorf("step 3 is answered by %q, which is not the door's message", out)
	}
	if acts[4]["tool"] != "scan vw_embedding_status" {
		t.Errorf("step 4 names %v, want the closing coverage scan", acts[4]["tool"])
	}
	if out, _ := obs[4]["output"].(string); !strings.HasSuffix(out, "COMPLETE") {
		t.Errorf("step 4 is answered by %q, want the register's own verdict - it is the sentence a "+
			"reader cross-checks against vw_embedding_status, and it used to be stranded in a slot "+
			"the view never reads", out)
	}
}

// A tick whose embedder is down must not sound like a tick with nothing to do. This is the same
// sentence 0031's first hour wrote, one column away: the failure and the healthy zero have to be
// distinguishable in the one field anybody reads.
func TestADeadEmbedderIsAFailureAndNotAnEmptyTick(t *testing.T) {
	q := &routed{status: status(0, 25, "EMPTY", ""), queue: queued(1, 2)}
	res, err := RunEmbeddings(context.Background(), q, embedder(t, embed.SchemaDimensions, true),
		logging.NewRecorder(nil, false))
	if err == nil {
		t.Fatal("the tick succeeded with no vectors")
	}
	if res.Embedded != 0 {
		t.Errorf("it reports %d embedded", res.Embedded)
	}
	if res.Failure == "" {
		t.Error("the tick's failure field is empty, so describe() cannot mention it")
	}
	out := describe(res)
	if !strings.Contains(out, "FAILURE") || !strings.Contains(out, "25") {
		t.Errorf("the trajectory sentence reads %q; it must say both what failed and how much of the "+
			"corpus is still unsearchable", out)
	}
	if strings.HasSuffix(out, "COMPLETE") || strings.HasSuffix(out, "coverage 25 of 25") {
		t.Errorf("a failed tick reported a finished corpus: %q", out)
	}
	if q.called("embed_communications") {
		t.Error("the door was called with no vectors behind it")
	}
}

// The register's counts are what the tick reports, and not before+embedded. The first draft of this
// line summed the two, which is arithmetic on top of a source of truth - and the case it gets wrong
// is the interesting one: another writer in flight, or a coverage scan that failed and left the
// struct at zero, both produce a confident wrong total.
func TestTheTickReportsTheRegisterAndNotItsOwnSum(t *testing.T) {
	q := &routed{
		queue:   queued(1, 2),
		doorRow: []map[string]any{{"success": true, "rows_embedded": int32(2), "message": "ok"}},
		statusSeq: [][]map[string]any{
			status(2, 25, "EMPTY", ""),
			status(4, 25, "PARTIAL", "fake/embed:latest"),
		},
	}
	res, err := RunEmbeddings(context.Background(), q, embedder(t, embed.SchemaDimensions, false),
		logging.NewRecorder(nil, false))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if res.CoverageAfter.RowsEmbedded != 4 {
		t.Errorf("the tick reported coverage %d; it must re-read the register rather than add to the "+
			"number it saw before it started", res.CoverageAfter.RowsEmbedded)
	}
	if !strings.Contains(describe(res), "4 of 25") {
		t.Errorf("describe() says %q", describe(res))
	}
}

// Rows the view says have nothing to embed must not reach the model. An empty document answers a
// valid, unit-norm vector, and every empty document's vector is close to every other one's: the
// corpus fills with rows that match each other and nothing else, which is a ranking poisoned by
// arithmetic that is correct.
func TestNothingToEmbedIsSkippedAndSaid(t *testing.T) {
	q := &routed{
		status: status(0, 3, "EMPTY", ""),
		queue: []map[string]any{
			{"communication_id": int64(1), "embeddable_text": "", "nothing_to_embed": true},
			{"communication_id": int64(2), "embeddable_text": "   ", "nothing_to_embed": false},
		},
	}
	res, err := RunEmbeddings(context.Background(), q, embedder(t, embed.SchemaDimensions, false),
		logging.NewRecorder(nil, false))
	if err != nil {
		t.Fatalf("a tick with nothing sendable returned an error: %v", err)
	}
	if res.Offered != 0 || res.SkippedEmpty != 2 {
		t.Fatalf("offered %d, skipped %d, want 0 and 2", res.Offered, res.SkippedEmpty)
	}
	if q.called("embed_communications") {
		t.Error("an empty batch reached the door")
	}
	if !strings.Contains(describe(res), "nothing to embed") {
		t.Errorf("the sentence hides the rows that will queue again forever: %q", describe(res))
	}
}

// 0035's own reason for existing, seen from the side that has to live with it: the operator pointed
// the keeper at a second embedder, and the column already holds the first one's vectors.
func TestASecondModelIsReportedEveryTickAndWritesNothing(t *testing.T) {
	q := &routed{
		status: status(20, 25, "PARTIAL", "old/model"),
		queue:  queued(1),
		doorErr: fmt.Errorf("ERROR: embed_communications: communications.embedding was filled by " +
			"old/model, and this call names fake/embed:latest (SQLSTATE 23514)"),
	}
	res, err := RunEmbeddings(context.Background(), q, embedder(t, embed.SchemaDimensions, false),
		logging.NewRecorder(nil, false))
	if err == nil {
		t.Fatal("a refused write returned success")
	}
	if res.ModelConflict == "" {
		t.Fatal("the tick did not recognise the refusal, so it will report a plain error every hour " +
			"and nothing will name the decision that is pending")
	}
	if res.Embedded != 0 {
		t.Error("the conflict path wrote something")
	}
	if !strings.Contains(describe(res), "FAILURE") {
		t.Errorf("a tick that wrote nothing under a conflict must not read clean: %q", describe(res))
	}
}

func TestAnEmptyQueueIsAnAnswer(t *testing.T) {
	q := &routed{status: status(25, 25, "COMPLETE", "fake/embed:latest"), queue: nil}
	res, err := RunEmbeddings(context.Background(), q, embedder(t, embed.SchemaDimensions, false),
		logging.NewRecorder(nil, false))
	if err != nil {
		t.Fatalf("an idle tick failed: %v", err)
	}
	if !strings.Contains(describe(res), "nothing queued") {
		t.Errorf("describe() says %q", describe(res))
	}
	if q.called("embed_communications") {
		t.Error("an idle tick called the door, which files an audit row for a table it did not change")
	}
}

// A register with no row for the column means the catalog lost the column. The tick must say that
// rather than carry on with a zero-valued Coverage, whose "0 of 0 (EMPTY)" is a sentence about a
// database that does not exist.
func TestAMissingRegisterRowIsNotifiedAndNotDefaulted(t *testing.T) {
	q := &routed{status: nil}
	res, err := RunEmbeddings(context.Background(), q, embedder(t, embed.SchemaDimensions, false),
		logging.NewRecorder(nil, false))
	if err == nil {
		t.Fatal("the tick could not see the corpus and reported a finding anyway")
	}
	if res.Offered != 0 || q.called("embed_communications") {
		t.Error("it went looking for work it could not describe")
	}
	if !strings.Contains(describe(res), "coverage not readable") {
		t.Errorf("describe() says %q; an unreadable register must be visible in the tick's own sentence",
			describe(res))
	}
}

func TestNoEmbedderIsAStateAndNotAFailure(t *testing.T) {
	q := &routed{status: status(0, 25, "EMPTY", "")}
	res, err := RunEmbeddings(context.Background(), q, nil, logging.NewRecorder(nil, false))
	if err != nil {
		t.Fatalf("an unconfigured deployment must not fail every tick: %v", err)
	}
	if res.Embedded != 0 || q.called("embed_communications") {
		t.Error("it wrote without an embedder")
	}
}

func TestCoverageReadsBigintAndIntegerFromTheDriver(t *testing.T) {
	// A count comes back as a bigint (int64) and a dimensions as an integer (int32). A reader that
	// switches on int64 alone reports 0 for the second, which is 0031's zero-shaped bug in a new
	// column: the register would say "0 of 25" while the JSON plane showed 20.
	q := &routed{status: []map[string]any{{
		"rows_total": int64(25), "rows_embedded": int64(20), "verdict": "PARTIAL",
		"embedded_by": "m", "served_by": "u", "newest_at": "",
	}}}
	got, err := coverage(context.Background(), q)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got.RowsTotal != 25 || got.RowsEmbedded != 20 {
		t.Fatalf("read %d of %d", got.RowsEmbedded, got.RowsTotal)
	}
	if !strings.Contains(got.sentence(), "20 of 25") {
		t.Errorf("sentence() says %q", got.sentence())
	}

	fromInt32 := intAt([]map[string]any{{"n": int32(7)}}, "n")
	fromJSON := intAt([]map[string]any{{"n": json.Number("8")}}, "n")
	if fromInt32 != 7 || fromJSON != 8 {
		t.Errorf("int32=%d json.Number=%d", fromInt32, fromJSON)
	}
}

func TestSearchToolIsRegisteredOnlyWithAnEmbedder(t *testing.T) {
	q := &routed{}
	var names []string
	for _, d := range Tools(q, nil) {
		names = append(names, d.Name)
	}
	for _, n := range names {
		if n == "search_communications" {
			t.Fatal("the tool is registered with no embedder: the prompt advertises a capability the " +
				"deployment does not have")
		}
	}
	if len(names) != 8 {
		t.Fatalf("without an embedder the surface is %d tools, want the 8 CRM ones", len(names))
	}

	withEmbedder := Tools(q, embedder(t, embed.SchemaDimensions, false))
	if len(withEmbedder) != 9 {
		t.Fatalf("with an embedder the surface is %d tools, want 9", len(withEmbedder))
	}
	var found bool
	for _, d := range withEmbedder {
		if d.Name == "search_communications" {
			found = true
			if d.Policy.ReadOnly != true {
				t.Error("a search is not read-only, so STRICT_TOOL_POLICIES and the approval gate treat " +
					"it as a write")
			}
		}
	}
	if !found {
		t.Fatal("search_communications is missing from a surface that has an embedder")
	}
}

func TestSearchSendsThreePositionsAndAVectorOfTheDeclaredWidth(t *testing.T) {
	q := &routed{
		// The status rows answer the coverage note; the search's own rows come from Call, so this
		// fake has to give the door something non-empty.
		doorRow: []map[string]any{{"communication_id": int64(9), "customer_name": "Acme"}},
	}
	for _, d := range Tools(q, embedder(t, embed.SchemaDimensions, false)) {
		if d.Name != "search_communications" {
			continue
		}
		if _, err := d.ExecuteContext(context.Background(), map[string]any{
			"query": "customers who complained about shipping", "days": float64(7),
			// limit omitted on purpose: it must arrive as the tool's own default rather than as NULL,
			// because the door's DEFAULT 10 only fires when the position is missing, and db.Call
			// spells every position.

		}); err != nil {
			t.Fatalf("err: %v", err)
		}
	}
	var call *fakeCall
	for i := range q.calls {
		if q.calls[i].name == "search_similar_communications" {
			call = &q.calls[i]
		}
	}
	if call == nil {
		t.Fatal("the search door was never called")
	}
	if len(call.args) != 3 {
		t.Fatalf("%d positional arguments, want 3 (vector, days, limit)", len(call.args))
	}
	rendered, _ := call.args[0].(string)
	var v []float32
	if err := json.Unmarshal([]byte(rendered), &v); err != nil {
		t.Fatalf("the query vector is not the rendering pgvector reads: %v", err)
	}
	if len(v) != embed.SchemaDimensions {
		t.Errorf("the query is %d dimensions against a column that declares %d", len(v), embed.SchemaDimensions)
	}
	if n, ok := call.args[1].(int); !ok || n != 7 {
		t.Errorf("days arrived as %#v, want the integer 7", call.args[1])
	}
}

// An omitted window has to arrive as SQL NULL and not as 0: 0 means "the last zero days", which is a
// different question, and the door would answer it with an empty list that reads like the corpus is
// empty. db.Call names every position, so this is the branch where the tool must send nil on purpose.
func TestSearchWithoutADaysSendsNULLAndNotZero(t *testing.T) {
	q := &routed{doorRow: []map[string]any{{"communication_id": int64(1)}}}
	for _, d := range Tools(q, embedder(t, embed.SchemaDimensions, false)) {
		if d.Name != "search_communications" {
			continue
		}
		if _, err := d.ExecuteContext(context.Background(), map[string]any{"query": "shipping"}); err != nil {
			t.Fatalf("err: %v", err)
		}
	}
	for _, c := range q.calls {
		if c.name == "search_similar_communications" {
			if c.args[1] != nil {
				t.Fatalf("an omitted window arrived as %#v, want nil", c.args[1])
			}
			return
		}
	}
	t.Fatal("the search door was never called")
}

func TestSearchRefusesAnEmptyQuestion(t *testing.T) {
	q := &routed{}
	for _, d := range Tools(q, embedder(t, embed.SchemaDimensions, false)) {
		if d.Name != "search_communications" {
			continue
		}
		for _, args := range []map[string]any{
			{}, {"query": ""}, {"query": "   "},
		} {
			if _, err := d.ExecuteContext(context.Background(), args); err == nil {
				t.Errorf("an empty query %#v was accepted, and a search for nothing returns everything "+
					"or nothing depending on the index", args)
			}
		}
	}
}

// The empty-result case is the one a human will actually hit while the backlog drains, and "nothing
// matches" is the wrong lesson to take from it.
func TestAnEmptySearchSaysWhetherThereWasAnythingToSearch(t *testing.T) {
	cases := map[string]struct {
		status []map[string]any
		want   string
	}{
		"nothing embedded at all": {
			status: status(0, 25, "EMPTY", ""),
			want:   "nothing is embedded yet",
		},
		"corpus draining": {
			status: status(3, 250, "PARTIAL", "fake/embed:latest"),
			want:   "3 of 250",
		},
		"fully embedded": {
			status: status(250, 250, "COMPLETE", "fake/embed:latest"),
			want:   "an answer and not a failure",
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			q := &searchFake{routed: routed{status: tc.status}}
			for _, d := range Tools(q, embedder(t, embed.SchemaDimensions, false)) {
				if d.Name != "search_communications" {
					continue
				}
				out, err := d.ExecuteContext(context.Background(), map[string]any{"query": "shipping"})
				if err != nil {
					t.Fatalf("err: %v", err)
				}
				if !strings.Contains(out, tc.want) {
					t.Errorf("an empty search answered %q, which does not contain %q", out, tc.want)
				}
			}
		})
	}
}

// searchFake answers the search door with zero rows, the coverage scan with the test's status, and
// the query embedder is not involved (that is HTTP).
type searchFake struct {
	routed
}

func (s *searchFake) Call(_ context.Context, name string, args []any) ([]map[string]any, error) {
	s.calls = append(s.calls, fakeCall{name: name, args: args})
	if name == "search_similar_communications" {
		return []map[string]any{}, nil
	}
	return nil, nil
}

func (s *searchFake) Query(_ context.Context, sql string, args ...any) ([]map[string]any, error) {
	s.calls = append(s.calls, fakeCall{sql: sql, args: args})
	if strings.Contains(sql, "vw_embedding_status") {
		return s.status, nil
	}
	return nil, nil
}

func TestEmbeddingTimerEnvIsReadAsMinutes(t *testing.T) {
	// StartEmbeddingTimer schedules with time.AfterFunc and returns immediately; what a test can
	// assert without waiting is that a nonsense interval does not become a silent default that
	// contradicts the log line beside it. The fork that got this wrong said 30 in a package whose
	// fallback was 60.
	if got := embeddingInterval(); got != defaultEmbedMinutes*time.Minute {
		t.Errorf("an unset interval is %v, want the documented default", got)
	}
	for _, bad := range []string{"not-a-number", "0", "-5"} {
		t.Setenv(EnvCheckInterval, bad)
		if got := embeddingInterval(); got != defaultEmbedMinutes*time.Minute {
			t.Errorf("%s produced %v; a value that cannot be a schedule must keep the default the "+
				"warning names", bad, got)
		}
	}
	t.Setenv(EnvCheckInterval, "15")
	if got := embeddingInterval(); got != 15*time.Minute {
		t.Errorf("15 minutes produced %v", got)
	}
}
