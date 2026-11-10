package crm

import (
	"context"
	"testing"

	"jada-backend/pkg/embed"
	"jada-backend/pkg/logging"
	"jada-backend/pkg/memory"
)

// memFake is the write side of the memory store, which pkg/memory holds as a package-level seam
// (memory.Use) rather than passing it in.
type memFake struct{ saves int }

func (m *memFake) Call(_ context.Context, name string, _ []any) ([]map[string]any, error) {
	if name == "save_memory" {
		m.saves++
	}
	return []map[string]any{{"success": true}}, nil
}

// TestTheMemoryMovesWhenTheCoverageMoves holds the keeper to one write per change.
//
// The read half of the memory goes through the injected Querier (lastCoverage, because the previous
// finding has to come from the same door the agents read) and the write half through pkg/memory's own
// store, which is the same database in production and two different seams in a test. So a fake is
// installed BEFORE the tick runs: after it, this test would be counting nothing.
//
// The failure this exists to prevent is measured and has a date on it: agents/inventory compared a
// rendering of rows against a signature and wrote 48 duplicate memories a day, because the comparison
// was true on every tick forever.
func TestTheMemoryMovesWhenTheCoverageMoves(t *testing.T) {
	t.Run("the finding moved", func(t *testing.T) {
		q := &routed{
			status:  status(4, 25, "PARTIAL", "fake/embed:latest"),
			queue:   queued(1, 2),
			doorRow: []map[string]any{{"success": true, "rows_embedded": int32(2), "message": "ok"}},
			memory:  []map[string]any{{"content": "2/25|fake/embed:latest|EMPTY"}},
		}
		mem := &memFake{}
		memory.Use(mem)
		defer memory.Use(nil)

		if _, err := RunEmbeddings(context.Background(), q,
			embedder(t, embed.SchemaDimensions, false), logging.NewRecorder(nil, false)); err != nil {
			t.Fatalf("err: %v", err)
		}
		if mem.saves != 1 {
			t.Errorf("%d memory writes; coverage moved from 2/25 to 4/25 and that is worth one row",
				mem.saves)
		}
		var reads int
		for _, c := range q.calls {
			if c.name == "get_memory" {
				reads++
			}
		}
		if reads == 0 {
			t.Error("the tick never asked what it had last said, so it could not have known to write")
		}
	})

	t.Run("the finding is unchanged", func(t *testing.T) {
		q := &routed{
			status: status(4, 25, "PARTIAL", "fake/embed:latest"),
			queue:  nil,
			memory: []map[string]any{{"content": signature(Coverage{
				RowsEmbedded: 4, RowsTotal: 25, Verdict: "PARTIAL",
				EmbeddedBy: "fake/embed:latest", searchableSet: true})}},
		}
		mem := &memFake{}
		memory.Use(mem)
		defer memory.Use(nil)

		if _, err := RunEmbeddings(context.Background(), q,
			embedder(t, embed.SchemaDimensions, false), logging.NewRecorder(nil, false)); err != nil {
			t.Fatalf("err: %v", err)
		}
		if mem.saves != 0 {
			t.Errorf("%d memory writes on an idle tick with an unchanged finding", mem.saves)
		}
	})

	t.Run("a tick that could not read the corpus writes nothing", func(t *testing.T) {
		q := &routed{
			status: nil,
			memory: []map[string]any{{"content": "4/25|fake/embed:latest|PARTIAL"}},
		}
		mem := &memFake{}
		memory.Use(mem)
		defer memory.Use(nil)

		if _, err := RunEmbeddings(context.Background(), q,
			embedder(t, embed.SchemaDimensions, false), logging.NewRecorder(nil, false)); err == nil {
			t.Fatal("a tick with no register row reported success")
		}
		// The reason this is the case worth its own subtest: storing the zero-valued Coverage of a
		// failed scan would overwrite last week's real finding with a sentence that reads clean,
		// which is the shape of the 48-duplicate bug turned around.
		if mem.saves != 0 {
			t.Errorf("%d memory writes from a tick that saw nothing: it just overwrote the last true "+
				"finding with a zero", mem.saves)
		}
	})
}

func TestSignatureIsStableAcrossSpellings(t *testing.T) {
	// The comparison is content to content, so the signature has to be a function of exactly the four
	// things that make a finding and nothing else - not of a timestamp, which changes every tick and
	// would put the 48-duplicate bug straight back in.
	a := Coverage{RowsEmbedded: 4, RowsTotal: 25, Verdict: "PARTIAL", EmbeddedBy: "m", NewestAt: "one"}
	b := Coverage{RowsEmbedded: 4, RowsTotal: 25, Verdict: "PARTIAL", EmbeddedBy: "m", NewestAt: "two"}
	if signature(a) != signature(b) {
		t.Errorf("the signature moved with the clock: %q vs %q", signature(a), signature(b))
	}
	c := Coverage{RowsEmbedded: 5, RowsTotal: 25, Verdict: "PARTIAL", EmbeddedBy: "m"}
	if signature(a) == signature(c) {
		t.Error("one more embedded row is not a change in the finding")
	}
}
