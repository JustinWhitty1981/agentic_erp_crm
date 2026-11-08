package ids

import "testing"

// TestMatchesAReferenceImplementation is a golden vector, and it is here because the interesting
// failure of a derivation is the one nobody notices: a hash built in the wrong order still produces a
// well-formed uuid, still distributes, and still passes every test that only checks the shape. The
// values below are what an independent implementation - Python's uuid.uuid5 over the same namespace
// and the same pre-image - produces, one per deployed agent, because the agent is part of the input.
//
// Three vectors rather than one, and that is the finding this signature came from: on 2026-11-08 the
// sales agent introduced itself as the Inventory Control Agent, because the thread string alone named
// one conversation shared by all three backends and rehydration handed it the other agent's turns.
// If any value here stops matching, the derivation changed, and every conversation id already in the
// database now belongs to a different thread. The last time that happened it could be repaired -
// 0032 re-derived the rows because pkg/logging keeps the caller's thread string in
// agent_interactions.telegram_chat_id - but that recovery depends on a column named for a transport
// nobody uses, so do not count on it being possible twice.
func TestMatchesAReferenceImplementation(t *testing.T) {
	for _, tc := range []struct {
		agent, thread string
		want          string
	}{
		// uuid5(NS, "thread\x00customer_service\x00web:7c9f"), and the same for the other two.
		{"customer_service", "web:7c9f", "2ea5874c-f768-5323-a05e-3dfee5205e7b"},
		{"inventory", "web:7c9f", "d44a7bca-7a4d-57e0-b590-90f501b61557"},
		{"sales", "web:7c9f", "8e14e8f2-32b3-513e-8c07-13053be02278"},
	} {
		if got := Thread(tc.agent, tc.thread); got != tc.want {
			t.Errorf("Thread(%q, %q) =\n  got  %s\n  want %s\nthe derivation no longer matches an "+
				"independent implementation, which means every conversation id in agent_interactions "+
				"now belongs to a different thread", tc.agent, tc.thread, got, tc.want)
		}
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

// TestThreadStability is the property the conversation history depends on across a rebuild - and the
// property that was incomplete until the agent joined the input: stability for one agent must not
// mean sameness across agents.
func TestThreadStability(t *testing.T) {
	const agent, thread = "sales", "web:7c9f"
	if Thread(agent, thread) != Thread(agent, thread) {
		t.Fatal("Thread is not deterministic, so every restart starts a new conversation")
	}
	if Thread(agent, thread) == Thread(agent, thread+"2") {
		t.Fatal("two threads share a conversation")
	}
	if len(Thread(agent, thread)) != 36 || Thread(agent, thread)[14] != '5' {
		t.Errorf("Thread produced %q, and conversation_id is a uuid column", Thread(agent, thread))
	}

	// The assertion whose absence the sales agent's own greeting told us about: three deployed
	// processes, one tenant, and every web UI posting the same thread string. If the agent is not in
	// the derivation, this is one conversation between all of them and rehydration mixes the voices.
	seen := map[string]string{}
	for _, who := range []string{"customer_service", "inventory", "sales"} {
		id := Thread(who, thread)
		if other, dup := seen[id]; dup {
			t.Errorf("%s and %s share conversation id %s for thread %q: one agent's history would be "+
				"read back as another agent's", other, who, id, thread)
		}
		seen[id] = who
	}
	// And the join has to be unambiguous, because "whose" and "which" are two strings and a boundary
	// that is not marked is a boundary somebody will cross with a role named "s" and a thread named
	// "alesx".
	if Thread("s", "ales"+thread) == Thread("sales", thread) {
		t.Error("part boundaries are not preserved, so an agent and a thread can trade letters")
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
