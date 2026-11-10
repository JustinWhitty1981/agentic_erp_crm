// policy_claims_test.go holds one field to the code it describes.
//
// /api/tools used to answer "does this tool send an idempotency key" by matching the tool's name
// against two prefixes. On this agent that was accidentally right for eight tools; on agents/sales it
// is wrong today for seven of its eight writers, because ship, transition, create, cancel and receive
// are not add. A false is worse than an absent: a reader asking "can this be retried safely" gets an
// answer that contradicts vw_idempotency_status, which asks the same question of the function bodies
// and gets it right.
//
// So the assertion is behavioural. Each tool is executed against a fake with a run identity in the
// context, and the last positional argument of every door call is inspected for the uuid key()
// produces. Policy.Claims must agree with what the code sent - not with what its name suggests, and
// not with what whoever added the next tool remembered to update.
package crm

import (
	"strings"
	"testing"

	"jada-backend/pkg/embed"
)

func TestPolicyClaimsMatchesTheKeyActuallySent(t *testing.T) {
	// The shape each tool needs in order to reach a door at all: a read with no selector is refused
	// before any call, and a refusal is not a question about claims.
	shapes := map[string]map[string]any{
		"get_customer_info":           {"customer_name": "Acme"},
		"get_customer_communications": {"customer_name": "Acme"},
		"get_entity_stats":            {"customer_name": "Acme"},
		"get_followup_customers":      {},
		"add_customer":                {"name": "Acme", "email": "a@b.example.invalid"},
		"update_customer":             {"customer_name": "Acme", "email": "a@b.example.invalid"},
		"add_communication":           {"customer_name": "Acme", "summary": "said a thing"},
		"mark_customer_followup":      {"entity_id": float64(1), "mark": true},
	}

	for name, args := range shapes {
		// One fake per tool, built by the same call that produced the tool under test. An earlier
		// draft enumerated the registrations off one fake and read the call log off another, found no
		// claims anywhere, and accused add_customer of lying about its policy. A test that
		// contradicts the code is evidence only once you have proved both halves are looking at the
		// same object.
		f := &fake{rows: []map[string]any{{"success": true, "entity_id": int64(7),
			"communication_id": int64(9), "mark_customer_followup": "marked", "message": "ok"}}}
		var found bool
		for _, d := range Tools(f, nil) {
			if d.Name != name {
				continue
			}
			found = true
			if _, err := d.ExecuteContext(
				runCtx("a1a1a1a1-b1b1-c1c1-d1d1-e1e1e1e1e1e1"), args); err != nil {
				break
			}
			saw := false
			for _, c := range f.calls {
				if c.name == "" || len(c.args) == 0 {
					continue
				}
				if k, is := c.args[len(c.args)-1].(string); is && looksLikeUUID(k) {
					saw = true
				}
			}
			if d.Policy.Claims != saw {
				t.Errorf("%s: Policy.Claims=%v but the tool %s a claim as its last positional argument. "+
					"The field is what /api/tools answers with and the argument is the truth, so one of "+
					"them is a statement about retries that the other contradicts", name, d.Policy.Claims,
					map[bool]string{true: "sent", false: "sent no"}[saw])
			}
		}
		if !found {
			t.Errorf("%s is named in this test's shape table and is not registered: the table and the "+
				"surface have drifted apart, which is the same failure in a fixture", name)
		}
	}
}

// search_communications is the case the prefix list could not see coming, and the one this field exists
// to keep honest: it is a read over a door, so it claims nothing, and no name-prefix rule would have
// had an opinion about it either way.
func TestSearchCommunicationsClaimsNothing(t *testing.T) {
	for _, d := range Tools(&fake{}, new(embed.Client)) {
		if d.Name != "search_communications" {
			continue
		}
		if d.Policy.Claims {
			t.Error("a read that sends a claim would deduplicate a second, legitimate search of the " +
				"same corpus inside one run")
		}
		if !d.Policy.ReadOnly {
			t.Error("a search is registered as a write, so STRICT_TOOL_POLICIES and the approval gate " +
				"would gate a lookup")
		}
		return
	}
	t.Fatal("search_communications is not registered against an embedder")
}

func looksLikeUUID(s string) bool {
	return len(s) == 36 && strings.Count(s, "-") == 4
}
