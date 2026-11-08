package turn

import (
	"context"
	"fmt"
	"testing"
)

type trail struct {
	id      string
	sources []string
}

func (t *trail) ID() string { return t.id }
func (t *trail) Source(table string, id any) {
	// %v rather than a hand-rolled formatter: the run's own Source does exactly this, and a test that
	// reimplemented the formatting would be checking its own copy of the rule instead of the real one.
	t.sources = append(t.sources, fmt.Sprintf("%s:%v", table, id))
}

// TestCarriersRoundTrip is the plumbing every write tool depends on, stated once.
//
// A tool that silently read an empty run id would derive no claim key, and the symptom is a duplicate
// row rather than an error - which is ADR-005's failure mode in the exact shape ADR-005 was written to
// prevent. Asserting the carrier works is cheap; asserting it through a real tool is done in pkg/crm.
func TestCarriersRoundTrip(t *testing.T) {
	tr := &trail{id: "aaaa0000-bbbb-cccc-dddd-eeeeffff0000"}
	ctx := From(context.Background(), tr.id, "web:thread-1", tr)

	if got := RunID(ctx); got != tr.id {
		t.Errorf("RunID = %q, want the run the turn was built with", got)
	}
	if got := ThreadID(ctx); got != "web:thread-1" {
		t.Errorf("ThreadID = %q", got)
	}

	Source(ctx, "entities", int64(42))
	Source(ctx, "entities", int64(42))
	Source(ctx, "communications", int64(7))

	// This asserts the CARRIER, not the deduplication: the stub trail above records what it is handed,
	// and the "same record twice is one entry" rule belongs to logging.Run.Source, where it is
	// asserted in its own test. Checking dedup here would be checking this file's copy of the rule
	// rather than the rule - which is how a test keeps passing after the real one starts repeating.
	want := []string{"entities:42", "entities:42", "communications:7"}
	if len(tr.sources) != len(want) {
		t.Fatalf("the trail saw %v, want %v", tr.sources, want)
	}
	for i := range want {
		if tr.sources[i] != want[i] {
			t.Errorf("source %d is %q, want %q - call order is what ties a tool call to what it "+
				"touched", i, tr.sources[i], want[i])
		}
	}
}

// TestEmptyContextIsNotAnError is the case a test or a CLI lands in. A carrier that panicked here
// would take down the process for a call that has no conversation, which is a worse outcome than the
// missing key it would be protecting against.
func TestEmptyContextIsNotAnError(t *testing.T) {
	if got := RunID(context.Background()); got != "" {
		t.Errorf("RunID on a bare context = %q, want empty", got)
	}
	if got := ThreadID(context.Background()); got != "" {
		t.Errorf("ThreadID on a bare context = %q, want empty", got)
	}
	Source(context.Background(), "entities", int64(1)) // must not panic
}

// TestNilContextIsRefusedEverywhere states the package's one rule about nil contexts at every entry
// point, so that a future function added here cannot quietly become the exception. From used to repair
// a nil parent into a Background(); the test that asserted that behaviour is what surfaced the
// inconsistency, and the repair was removed rather than the rule being doubled.
func TestNilContextIsRefusedEverywhere(t *testing.T) {
	cases := map[string]func(){
		"From":     func() { From(nil, "r", "t", nil) },
		"RunID":    func() { _ = RunID(nil) },
		"ThreadID": func() { _ = ThreadID(nil) },
		"Source":   func() { Source(nil, "entities", int64(1)) },
	}
	for name, fn := range cases {
		t.Run(name, func(t *testing.T) {
			defer func() {
				if recover() == nil {
					t.Errorf("%s(nil) accepted a nil context, so a caller that lost the request's "+
						"context now runs with no deadline and no cancellation, silently", name)
				}
			}()
			fn()
		})
	}
}
