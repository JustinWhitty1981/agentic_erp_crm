package ids

import "testing"

// TestMatchesAReferenceImplementation is a golden vector, and it is here because the interesting
// failure of a derivation is the one nobody notices: a hash built in the wrong order still produces a
// well-formed uuid, still distributes, and still passes every test that only checks the shape. The
// value below is what an independent implementation - Python's uuid.uuid5 over the same namespace and
// the same pre-image - produces. If it ever stops matching, this derivation changed, and every
// conversation id and claim key already in the database changed with it.
func TestMatchesAReferenceImplementation(t *testing.T) {
	// uuid5(UUID("f69d1282-6418-457f-90ba-5482b6cb90c9"), "thread\x00web:7c9f")
	if got, want := Thread("web:7c9f"), "dc86e0ce-0241-52fe-a400-5594423aff25"; got != want {
		t.Errorf("Thread(%q) =\n  got  %s\n  want %s\nthe derivation no longer matches an "+
			"independent implementation, which means every conversation id in agent_interactions "+
			"now belongs to a different thread", "web:7c9f", got, want)
	}
}

// TestCallKeyIsDeterministicAndScoped is the contract ADR-005's claim rests on, in the four directions
// that matter. Each one corresponds to a failure that is silent in the database: a key that changes
// when it should not duplicates a write, and a key that stays when it should change answers a new
// request from an old row.
func TestCallKeyIsDeterministicAndScoped(t *testing.T) {
	const run = "11111111-2222-3333-4444-555555555555"
	args := []any{"Acme", int64(7), nil, true}

	first := CallKey(run, "add_communication", args)
	if second := CallKey(run, "add_communication", args); first != second {
		t.Fatalf("one call produced two keys across invocations: %s then %s", first, second)
	}
	if len(first) != 36 || count(first, "-") != 4 {
		t.Fatalf("the key %q is not a uuid, and p_idempotency_key is a uuid column", first)
	}
	if first[14] != '5' {
		t.Errorf("the key %s is not version 5; a derived id should say which derivation it is", first)
	}

	if k := CallKey("66666666-6666-6666-6666-666666666666", "add_communication", args); k == first {
		t.Error("two runs produced one key, so the second run's write would be answered from the " +
			"first's cache and never happen")
	}
	if k := CallKey(run, "save_memory", args); k == first {
		t.Error("two operations produced one key, and 0011 settles a reused key as a conflict")
	}
	if k := CallKey(run, "add_communication", []any{"Acme", int64(8), nil, true}); k == first {
		t.Error("two different requests produced one key, which is a false replay - the outcome " +
			"worse than a duplicate")
	}
	if k := CallKey("", "add_communication", args); k != "" {
		t.Errorf("an unattributed call produced %q; it must produce nothing so the door runs "+
			"undeduplicated rather than sharing one constant key with every other unattributed call", k)
	}
}

// TestValuesAreNormalisedBeforeHashing is the difference between a key that deduplicates and one that
// does not: the same request spelled two ways by a model has to be one request to the database.
func TestValuesAreNormalisedBeforeHashing(t *testing.T) {
	pairs := [][2][]any{
		{{float64(7)}, {"7"}},
		{{float64(7)}, {float64(7.0)}},
		{{nil}, {""}},
		{{nil}, {"   "}},
		{{true}, {"true"}},
		{{int64(42)}, {"42"}},
		{{"same text"}, {"  same text  "}},
	}
	for i, p := range pairs {
		a := CallKey("r", "t", p[0])
		b := CallKey("r", "t", p[1])
		if a != b {
			t.Errorf("case %d: %v and %v are one argument and produced two keys", i, p[0][0], p[1][0])
		}
	}

	// And the ones that must NOT collide. "2026-11-03" and the empty string are different dates to a
	// door; folding them would be normalisation reaching past identity, which is exactly the filename
	// sanitiser's bug that 0023 replaced - and probe D of 0023 asserts the same boundary on the
	// database side, so the two halves of that rule are watched from both ends.
	keep := [][2][]any{
		{{"a_b"}, {"a b"}},
		{{float64(7)}, {float64(7.5)}},
		{{"2026-11-03"}, {nil}},
		{{"notes"}, {"note"}},
		{{[]any{"x"}}, {[]any{"y"}}},
	}
	for i, p := range keep {
		if CallKey("r", "t", p[0]) == CallKey("r", "t", p[1]) {
			t.Errorf("case %d: %v and %v are different requests and share a key", i, p[0][0], p[1][0])
		}
	}
}

// TestThreadStability is the property the conversation history depends on across a rebuild.
func TestThreadStability(t *testing.T) {
	const thread = "web:7c9f"
	if Thread(thread) != Thread(thread) {
		t.Fatal("Thread is not deterministic, so every restart starts a new conversation")
	}
	if Thread(thread) == Thread(thread+"2") {
		t.Fatal("two threads share a conversation")
	}
	if len(Thread(thread)) != 36 || Thread(thread)[14] != '5' {
		t.Errorf("Thread produced %q, and conversation_id is a uuid column", Thread(thread))
	}

	// The kinds are separated by a prefix in the pre-image rather than by separate namespaces, so the
	// prefix has to be doing real work. This is the assertion that catches the prefix being dropped,
	// which would otherwise show up as a history reading its own idempotency keys.
	if v5("thread", "x") == v5("call", "x") {
		t.Error("kind does not separate the pre-images, so a thread id and a call key can collide")
	}
	// Parts are joined with NUL, so the boundaries are unambiguous: without them, ("ab","c") and
	// ("a","bc") are the same byte string and would hash alike.
	if v5("call", "ab", "c") == v5("call", "a", "bc") {
		t.Error("part boundaries are not preserved, so two different calls share a key")
	}
}

func TestNewIsUnique(t *testing.T) {
	seen := make(map[string]bool, 5000)
	for i := 0; i < 5000; i++ {
		s := New()
		if seen[s] {
			t.Fatalf("New repeated itself on call %d", i)
		}
		seen[s] = true
		if len(s) != 36 || s[14] != '4' {
			t.Fatalf("%q is not a v4 uuid", s)
		}
	}
}

func count(s, sub string) int {
	n := 0
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			n++
		}
	}
	return n
}
