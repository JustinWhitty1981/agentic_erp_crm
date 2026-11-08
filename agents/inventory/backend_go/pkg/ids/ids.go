// Package ids derives the identifiers this agent uses, and is the only place any of the derivations
// exists.
//
// Everything here is UUIDv5: a deterministic 16-byte name from a fixed namespace. Deterministic is
// the point. The alternative for each of these is a table mapping a thread to a conversation id, or
// a tool call to a claim key - a second identity for the same thing, which is the pattern 0011 and
// 0016 refuse wherever they meet it, and here the map would live in a process whose filesystem does
// not survive a redeploy.
//
// The package has no dependencies on purpose. Run identity is needed by the tool registry, the
// memory store and the CRM tools; the obvious place to put it is whichever of those three was
// written first, and the result is an import cycle the fourth package resolves by copying the
// function. Anything that many packages need and that needs nothing belongs here.
package ids

import (
	"crypto/rand"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Namespace is this project's UUIDv5 namespace.
//
// It was generated once, at random, and is written down here rather than derived from anything,
// because a namespace that changed silently would change every conversation id in the database at
// the same moment - each history would start from zero with no row anywhere saying why. The value
// has no meaning. Its stability does.
const Namespace = "f69d1282-6418-457f-90ba-5482b6cb90c9"

// Thread is the conversation id agent_interactions is keyed by, for one caller-side thread *of one
// agent* - and the agent half of that input is what this function's signature lacked until
// 2026-11-08, when the third deployed backend answered "Hi" by introducing itself as this agent. A
// derivation with no *whose* in it is not one conversation per agent: all three backends share one
// namespace, one tenant and - because every web UI posts the same thread string - one history, and
// pkg/agent's Rehydrate feeds that history back as prior assistant turns. Ten worked examples of
// another agent's voice outrank this process's system prompt, which was and is correct.
//
// agents/sales/backend_go/pkg/ids/ids.go carries the long form of the finding, and 0032 is the re-key
// of the rows this binary had already written. Recovery was possible only because pkg/logging files
// the caller's thread string into agent_interactions.telegram_chat_id: the hash is not the record.
func Thread(agentID, threadID string) string { return v5("thread", agentID, threadID) }

// CallKey is the idempotency claim key for one tool call inside one run.
//
// `resolved` is the argument vector exactly as it is about to be sent to the function - after
// defaults, coercions and identity substitutions - and that is the whole design. The database
// fingerprints the same vector (0011 hashes the business parameters it was given), so deriving a key
// from a different representation of the same call would produce two keys for one request, and two
// keys for one request is two rows for one phone call.
//
// The scope is deliberate and narrower than "the same request forever". Two calls in the same run
// with the same resolved arguments produce the same key, so when a model retries a tool after a
// timeout the second call is answered from the claim instead of writing a second row - the failure
// ADR-005 was written for. Two calls in two different runs produce different keys, so an agent that
// legitimately logs the same summary twice across two conversations gets two communications,
// because those are two events, not a retry. The alternative - keying on thread plus arguments
// alone - would make "log my call with Acme" return last month's row forever, and nothing in the CRM
// says those are the same call.
//
// An empty runID means the call belongs to no run, and it gets the empty string back rather than a
// hash of "": the caller then passes NULL for p_idempotency_key and the door runs undeduplicated,
// which is an honest failure mode, whereas a key derived from a constant is a key that collides
// across every unattributed write ever made.
func CallKey(runID, toolName string, resolved []any) string {
	if strings.TrimSpace(runID) == "" {
		return ""
	}
	return v5("call", runID, toolName, canonical(resolved))
}

// canonical renders the argument vector as a JSON array: the pre-image a key is drawn from.
//
// An array rather than an object because a positional call already has one canonical order - the
// function's own - so there is no map-key ordering for two spellings of one call to disagree about.
// An unmarshalable value is rendered with %v rather than dropped: a key that silently omitted an
// argument would collide with a call that genuinely lacked one, which is a false replay, and a false
// replay is the one outcome worse than a duplicate.
func canonical(resolved []any) string {
	vals := make([]any, len(resolved))
	for i, v := range resolved {
		vals[i] = normalise(v)
	}

	body, err := json.Marshal(vals)
	if err != nil {
		parts := make([]string, len(vals))
		for i, v := range vals {
			parts[i] = fmt.Sprintf("%q", fmt.Sprintf("%v", v))
		}
		body = []byte("[" + strings.Join(parts, ",") + "]")
	}
	return string(body)
}

// normalise makes the two spellings a model can produce for one argument hash the same.
//
// JSON numbers all arrive as float64, so 7, 7.0 and "7" are one threshold; nil and "  " are one
// absence; a timestamptz is its UTC instant whatever zone it was parsed into. Without this, a retry
// that quoted its number would derive a different key from the call it was retrying, and
// deduplication would fail quietly - which is the only way for this mechanism to fail unnoticed,
// since the symptom is a second copy of an interaction that already exists.
func normalise(v any) any {
	switch t := v.(type) {
	case nil:
		return nil
	case float64:
		if t == float64(int64(t)) {
			return int64(t)
		}
		return t
	case string:
		s := strings.TrimSpace(t)
		if s == "" {
			return nil
		}
		// Numeric strings become numbers so that the id 42 and the id "42" - which the same model
		// will emit for the same call, in the same run - are one request. This is the one place
		// the two forms are reconciled; id64 in the tools does the same coercion on the way INTO
		// the vector, so a value that reached here as a string did so because its door takes text.
		if n, err := strconv.ParseInt(s, 10, 64); err == nil {
			return n
		}
		if s == "true" || s == "false" {
			return s == "true"
		}
		return s
	case bool:
		return t
	case time.Time:
		return t.UTC().Format(time.RFC3339Nano)
	default:
		return v
	}
}

// v5 is RFC 4122's construction: SHA-1 over the namespace's 16 raw bytes followed by the name, then
// the version and variant bits set.
//
// The parts are joined with NUL, which cannot appear in a thread id, a run id or a JSON document, so
// the boundary between them is never ambiguous and ("ab","c") does not hash like ("a","bc"). The
// kind is the first part rather than a separate namespace because one constant to keep stable beats
// two, and disjoint prefixes already make the kinds unable to collide.
func v5(kind string, parts ...string) string {
	raw, err := hex.DecodeString(strings.ReplaceAll(Namespace, "-", ""))
	if err != nil || len(raw) != 16 {
		// A malformed constant is a programming error and should not panic an agent mid-chat. The
		// zero namespace makes the result a stable function of the name alone: as unique as it needs
		// to be, and visibly wrong in a log line.
		raw = make([]byte, 16)
	}

	name := kind + "\x00" + strings.Join(parts, "\x00")
	sum := sha1.Sum(append(raw, name...))
	sum[6] = (sum[6] & 0x0f) | 0x50 // version 5
	sum[8] = (sum[8] & 0x3f) | 0x80 // RFC 4122 variant
	return format(sum[:16])
}

// New returns a random version-4 UUID, for the identities that are not derived from anything: a run
// id, which has to be unique and has nothing to be unique relative to.
func New() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		// A run id that is not a uuid is still unique enough to correlate a log line, and the
		// column is text. Failing the whole run over a broken reader would be absurd.
		return fmt.Sprintf("run-%d", time.Now().UnixNano())
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return format(b[:])
}

func format(b []byte) string {
	return strings.Join([]string{
		hex.EncodeToString(b[0:4]), hex.EncodeToString(b[4:6]),
		hex.EncodeToString(b[6:8]), hex.EncodeToString(b[8:10]),
		hex.EncodeToString(b[10:16]),
	}, "-")
}
