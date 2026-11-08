package crm

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"time"

	"jada-backend/pkg/ids"
	"jada-backend/pkg/tools"
	"jada-backend/pkg/turn"
)

// Querier is the whole of the database this package needs. Naming it here rather than importing
// pkg/db keeps the tools testable against a fake, which matters because the interesting cases - a
// door that answers success=false, a view that returns nothing, a query that errors - are awkward
// to produce on demand against a real server and free to produce here.
//
// It is also the seam that keeps ADR-002 honest: there is no Exec in this interface. A CRM write
// cannot be an INSERT a caller composed; it has to be a Call, which means it has to be a function
// the schema already owns.
type Querier interface {
	// Query runs a SELECT and returns rows as generic values.
	Query(ctx context.Context, sql string, args ...any) ([]map[string]any, error)
	// Call invokes a stored function by name with positional arguments.
	Call(ctx context.Context, name string, args []any) ([]map[string]any, error)
}

// Limits. The caps exist because the reader is a language model with a context window and tool
// output is truncated at 12000 characters (pkg/formatters.MaxToolOutputChars): a tool that
// returned "all customers" does not get read, it gets cut off mid-row, which is worse than being
// told to narrow the question.
const (
	defaultCustomerRows = 10
	maxCustomerRows     = 100
	defaultCommRows     = 5 // requirement 3: "up to 5 most recent"
	maxCommRows         = 200
	defaultFollowupDays = 7 // the function's own DEFAULT, mirrored so the schema stays first
)

// This process's name in the audit trail, defined once: communications.agent_id and
// agent_interactions.bot_id are two columns for one fact, and a key name typed twice is a fact that
// can drift in one of them.
const (
	EnvAgentRole     = "AGENT_ROLE"
	DefaultAgentRole = "customer_service"
)

// Tools is the customer service agent's CRM surface: four reads and four writes, each read over a
// vw_* view the schema publishes for agents (ADR-003) and each write over a function that owns its
// decision (ADR-002). No tool here composes SQL against a business table, which is the rule 0021
// put a marker on: a caller-side INSERT is a rule the database cannot enforce, and finding 4.5 is
// what that looked like in practice - the blueprint's add_communication.py carried its own INSERT,
// qualified to a schema no migration creates.
//
// The descriptions are part of the model's prompt, so they are written for a reader that cannot
// see the schema: each says what the tool answers, what it refuses, and which fact it needs that
// only the caller has. Where the database refuses in a specific way - an ambiguous name, a
// blacklisted status - the description says so, because a model that expects a tool to succeed
// will retry it, and a retry of a refusal is the same refusal plus more tokens.
//
// Memory tools are not here. They are pkg/memory's own three, and they reach the same database
// through save_memory/get_memory/list_memories; splitting one agent's state across two packages
// would be a second definition of what this agent knows.
func Tools(q Querier) []tools.ToolDefinition {
	if q == nil {
		return nil
	}
	return []tools.ToolDefinition{
		getCustomerInfo(q),
		getCustomerCommunications(q),
		getEntityStats(q),
		getFollowupCustomers(q),
		addCustomer(q),
		updateCustomer(q),
		addCommunication(q),
		markCustomerFollowup(q),
	}
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

func getCustomerInfo(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "get_customer_info",
		Description: "Look up customer records: name, email, phone, address, status and the " +
			"timestamps. Supply exactly one of customer_name, email, phone or entity_id - they " +
			"are alternatives, not filters to combine. customer_name is a case-insensitive " +
			"substring, so a surname alone is enough and several matches come back rather than " +
			"one being chosen for you; email is matched case-insensitively and exactly; phone is " +
			"matched exactly as stored, so use email or name when a number in an unfamiliar " +
			"format finds nothing. Status is one of active, prospect, inactive, follow-up or " +
			"blacklisted, and a blacklisted customer still appears here - this tool reports, it " +
			"does not decide.",
		Parameters: object(map[string]any{
			"customer_name": text("Part or all of the customer's name."),
			"email":         text("An exact email address."),
			"phone":         text("An exact phone number as stored."),
			"entity_id":     integer("The entity id, when one is already known."),
			"limit":         integer("Rows to return, 1-100. Default 10."),
		}),
		Policy: tools.ToolPolicy{ReadOnly: true},
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			limit, err := clampInt(args, "limit", defaultCustomerRows, 1, maxCustomerRows)
			if err != nil {
				return "", err
			}

			name := str(args, "customer_name")
			email := str(args, "email")
			phone := str(args, "phone")
			id, err := id64(args, "entity_id")
			if err != nil {
				return "", err
			}

			named := 0
			for _, v := range []any{name, email, phone, id} {
				if v != nil {
					named++
				}
			}
			switch {
			case named == 0:
				// Refused in Go rather than answered with the whole table: this tool's purpose is
				// to find someone, and "everybody" is a different question with a different tool.
				return "", fmt.Errorf("name the customer: customer_name, email, phone or entity_id")
			case named > 1:
				return "", fmt.Errorf("supply one of customer_name, email, phone, entity_id - " +
					"combining them asks this tool to guess which one was meant")
			}

			// The pattern for the fuzzy arm stays inside the parameter rather than being built as
			// "'%' || $1 || '%'", because idx_entities_name_trgm answers an ILIKE with wildcards
			// in the value just as well, and writing the pattern in SQL puts the matching rule in
			// a second place - the same objection 0018 raises to restating a CHECK.
			where := []string{}
			vals := []any{}
			add := func(clause string, v any) {
				sql, took := clauseFor(clause, len(vals)+1)
				where = append(where, sql)
				if took {
					vals = append(vals, v)
				}
			}
			if name != nil {
				add("name ILIKE ?", "%"+name.(string)+"%")
			}
			if email != nil {
				add("lower(email) = lower(?)", email)
			}
			if phone != nil {
				add("phone = ?", phone)
			}
			if id != nil {
				add("id = ?", id)
			}

			sql := "SELECT id, name, email, phone, address, status, created_at, updated_at" +
				" FROM vw_customers WHERE " + strings.Join(where, " AND ") +
				" ORDER BY name LIMIT $" + strconv.Itoa(len(vals)+1)
			vals = append(vals, limit)

			rows, err := q.Query(ctx, sql, vals...)
			if err != nil {
				return "", err
			}
			return Rows(withNote(rows, "no customer matched; that is an answer, not a failure, "+
				"and a second call with the same argument will not change it"))
		},
	}
}

func getCustomerCommunications(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "get_customer_communications",
		Description: "One customer's recent interactions, newest first, from " +
			"vw_customer_communications_summary: date, direction, type, subject, summary, outcome, " +
			"and both sides of who was on the call - entity_id and contact_id beside the names, because " +
			"the ids are what the write tools take and the names are not acceptable in their place, " +
			"priority, sentiment, and whether a follow-up is owed. Name the customer with entity_id " +
			"or customer_name, never both. Defaults to the five most recent, which is what the " +
			"requirements ask for; raise limit for a longer history. An outcome of pending or " +
			"escalated means the thread is still open, and that is the signal to escalate on - it " +
			"is why outcome is returned where the blueprint's query omitted it.",
		Parameters: object(map[string]any{
			"entity_id":     integer("The customer's entity id."),
			"customer_name": text("Part or all of the customer's name, when no id is known."),
			"limit":         integer("Rows to return, 1-200. Default 5."),
			"since_days":    integer("Only interactions within this many days. Unlimited by default."),
			"direction":     text("inbound, outbound or internal. All of them by default."),
		}),
		Policy: tools.ToolPolicy{ReadOnly: true},
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			limit, err := clampInt(args, "limit", defaultCommRows, 1, maxCommRows)
			if err != nil {
				return "", err
			}
			// since_days is bounded from 0, where 0 and absent mean the same thing: no window.
			since, err := clampInt(args, "since_days", 0, 0, 3650)
			if err != nil {
				return "", err
			}

			id, err := id64(args, "entity_id")
			if err != nil {
				return "", err
			}
			name := str(args, "customer_name")
			switch {
			case id == nil && name == nil:
				return "", fmt.Errorf("name the customer with entity_id or customer_name")
			case id != nil && name != nil:
				return "", fmt.Errorf("name the customer one way: entity_id or customer_name")
			}

			vals := []any{}
			where := []string{}
			add := func(clause string, v any) {
				sql, took := clauseFor(clause, len(vals)+1)
				where = append(where, sql)
				if took {
					vals = append(vals, v)
				}
			}

			if id != nil {
				add("entity_id = ?", id)
			} else {
				add("entity_name ILIKE ?", "%"+name.(string)+"%")
			}

			// started_at and not created_at: 0022's finding is that those are different questions
			// and only one of them is about the conversation. A window on the row's write time
			// would hide an interaction that happened long ago and was logged yesterday - a case
			// that exists in real CRM data, and by design in db/seeds/.
			if since > 0 {
				add("started_at >= now() - make_interval(days => ?)", since)
			}
			if dir := str(args, "direction"); dir != nil {
				add("direction = ?", dir)
			}

			vals = append(vals, limit)
			// contact_id beside contact_name, for the reason the projection is otherwise the view's
			// own column list: add_communication takes a contact_id, tells the caller never to guess it,
			// and until now had no read in this process that returned one. A required-by-nothing,
			// guessable-by-nobody argument is a column that does not exist as far as a conversation is
			// concerned. TestEveryDoorKeyIsReadableFromARead is the assertion.
			sql := "SELECT id, started_at, entity_id, entity_name, contact_id, contact_name," +
				" communication_type, direction, subject, summary, channel, outcome, priority," +
				" sentiment_label, sentiment_score, duration_seconds, follow_up_required," +
				" follow_up_date, agent_id" +
				" FROM vw_customer_communications_summary WHERE " +
				strings.Join(where, " AND ") +
				// id as tiebreak: rows can share started_at, and without a stable second key the
				// limit-5 window is not reproducible - the same page can come back in another
				// order, which reads to a human exactly like the data having changed.
				" ORDER BY started_at DESC, id DESC LIMIT $" + strconv.Itoa(len(vals))

			rows, err := q.Query(ctx, sql, vals...)
			if err != nil {
				return "", err
			}
			return Rows(withNote(rows, "this customer has no communications on file, which is "+
				"itself an answer"))
		},
	}
}

func getEntityStats(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "get_entity_stats",
		Description: "Communication metrics per customer from vw_entity_communication_stats: total " +
			"communications, resolved, pending and escalated counts, positive and negative " +
			"sentiment counts, average sentiment, and the first and last contact dates. Use it " +
			"before deciding whether an account is difficult, and as the summary an escalation " +
			"should carry. With no argument it returns every customer's stats, so pass entity_id " +
			"or entity_name unless the question really is about everybody.",
		Parameters: object(map[string]any{
			"entity_name": text("Part or all of the entity name."),
			"entity_id":   integer("The entity id."),
			"limit":       integer("Rows to return, 1-100. Default 10."),
		}),
		Policy: tools.ToolPolicy{ReadOnly: true},
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			limit, err := clampInt(args, "limit", defaultCustomerRows, 1, maxCustomerRows)
			if err != nil {
				return "", err
			}
			id, err := id64(args, "entity_id")
			if err != nil {
				return "", err
			}
			name := str(args, "entity_name")

			vals := []any{}
			var where []string
			if id != nil {
				where = append(where, "entity_id = $"+strconv.Itoa(len(vals)+1))
				vals = append(vals, id)
			}
			if name != nil {
				where = append(where, "entity_name ILIKE $"+strconv.Itoa(len(vals)+1))
				vals = append(vals, "%"+name.(string)+"%")
			}

			sql := "SELECT entity_id, entity_name, entity_type, status, total_communications," +
				" resolved_count, pending_count, escalated_count, positive_count, negative_count," +
				" avg_sentiment, first_contact_date, last_contact_date, avg_duration_seconds" +
				" FROM vw_entity_communication_stats"
			if len(where) > 0 {
				sql += " WHERE " + strings.Join(where, " AND ")
			}
			vals = append(vals, limit)
			// Busiest accounts first: unfiltered, this is the list a supervisor reads, and "the
			// customers with the most history" is the useful order. NULLS LAST because a customer
			// with no communications has no total, not a zero one.
			sql += " ORDER BY total_communications DESC NULLS LAST, entity_name LIMIT $" +
				strconv.Itoa(len(vals))

			rows, err := q.Query(ctx, sql, vals...)
			if err != nil {
				return "", err
			}
			return Rows(rows)
		},
	}
}

func getFollowupCustomers(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "get_followup_customers",
		Description: "Customers who need to be contacted, from get_followup_customers: id, name, " +
			"email, phone, the date of the last interaction, and the reason. The reason is one of " +
			"'No recent communications' (nothing on file, or the last interaction is older than " +
			"days_threshold), 'Status marked for follow-up' (a human marked the account), or " +
			"'Unresolved communication' (the most recent recorded outcome is pending or " +
			"escalated), checked in that order. days_threshold defaults to 7. The list is reached " +
			"through each customer's PRIMARY contact, so an account with no primary contact " +
			"appears nowhere - and it carries no status column, so read it alongside " +
			"get_customer_info before anyone telephones a blacklisted account.",
		Parameters: object(map[string]any{
			"days_threshold": integer("How many days without contact counts as stale. Default 7."),
		}),
		Policy: tools.ToolPolicy{ReadOnly: true},
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			// The bound is deliberately loose. 0022 refuses a negative or NULL threshold as
			// 22023, and this tool should surface THAT sentence rather than invent its own; what
			// Go checks is that the argument is a whole number at all, because a model that sends
			// "7 days" would otherwise get a type error out of the driver.
			d, err := days(args, "days_threshold", defaultFollowupDays)
			if err != nil {
				return "", err
			}
			if d < 0 {
				return "", fmt.Errorf("days_threshold must not be negative - it is an age in days")
			}

			rows, err := q.Call(ctx, "get_followup_customers", []any{d})
			if err != nil {
				return "", err
			}
			return Rows(withNote(rows, fmt.Sprintf(
				"nobody needs contact within %d days, which is an answer and not a failure to "+
					"find something", d)))
		},
	}
}

// ---------------------------------------------------------------------------
// Writes
// ---------------------------------------------------------------------------

func addCustomer(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "add_customer",
		Description: "Create a customer: one entity, one contact, the primary relationship between " +
			"them, and an address if one was given. For an individual pass first_name and " +
			"last_name; for a business pass organization_name, which becomes the entity name, " +
			"plus the contact person's name. email or phone is required. A duplicate is refused " +
			"with a message naming the existing record rather than merged into it - if that " +
			"happens, look the customer up instead of creating one. status defaults to active, " +
			"and address_type to home for an individual or headquarters for a business. Returns " +
			"success, entity_id, contact_id and a sentence; keep entity_id for later calls.",
		Parameters: object(map[string]any{
			"first_name":        text("Contact's given name. Required for an individual."),
			"last_name":         text("Contact's family name."),
			"email":             text("Email address."),
			"phone":             text("Phone number, in the form the caller gave it."),
			"organization_name": text("Company name. Required for a business."),
			"entity_type":       text("individual (default) or business."),
			"status":            text("active (default), prospect or follow-up."),
			"street":            text("Street line."),
			"city":              text("City."),
			"state":             text("State or province."),
			"postal_code":       text("Postal code."),
			"country":           text("Two-letter country code. Default US."),
			"address_type":      text("home, business, mailing, shipping, billing or headquarters."),
			"is_primary":        boolean("Whether this contact is the primary one. Default true."),
		}),
		Policy: tools.ToolPolicy{ReadOnly: false},
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			vals := []any{
				str(args, "first_name"), str(args, "last_name"), str(args, "email"),
				str(args, "phone"), str(args, "street"), str(args, "city"), str(args, "state"),
				str(args, "postal_code"), strDefault(args, "country", "US"),
				strDefault(args, "status", "active"),
				strDefault(args, "entity_type", "individual"),
				str(args, "organization_name"),
				str(args, "address_type"), // NULL lets the door choose by entity_type
				boolArg(args, "is_primary", true),
			}
			row, err := q.Call(ctx, "add_customer",
				append(vals, key(ctx, "add_customer", vals)))
			if err != nil {
				return "", err
			}
			return answer(ctx, row, "add_customer")
		},
	}
}

func updateCustomer(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "update_customer",
		Description: "Change an existing customer's details. Identify the customer with " +
			"search_name plus search_email or search_phone; the search fields select and never " +
			"change anything, and an ambiguous selection is refused rather than applied to " +
			"whichever row the scan reached first. Then pass only the fields to change - an " +
			"omitted field keeps its current value, and no field can be blanked through this " +
			"tool. It carries no idempotency claim, but it sets values, so repeating it lands the " +
			"same state; confirm afterwards with get_customer_info.",
		Parameters: object(map[string]any{
			"search_name":  text("The name as currently stored."),
			"search_email": text("The email as currently stored."),
			"search_phone": text("The phone as currently stored."),
			"first_name":   text("New given name."),
			"last_name":    text("New family name."),
			"email":        text("New email."),
			"phone":        text("New phone."),
			"street":       text("New street line."),
			"city":         text("New city."),
			"state":        text("New state."),
			"postal_code":  text("New postal code."),
			"country":      text("New country code."),
			"status":       text("New status: active, prospect, inactive, follow-up, blacklisted."),
		}),
		Policy: tools.ToolPolicy{ReadOnly: false},
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			vals := []any{
				str(args, "search_name"), str(args, "search_email"), str(args, "search_phone"),
				str(args, "first_name"), str(args, "last_name"), str(args, "email"),
				str(args, "phone"), str(args, "street"), str(args, "city"), str(args, "state"),
				str(args, "postal_code"), str(args, "country"), str(args, "status"),
			}
			row, err := q.Call(ctx, "update_customer", vals)
			if err != nil {
				return "", err
			}
			return answer(ctx, row, "update_customer")
		},
	}
}

func addCommunication(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "add_communication",
		Description: "Record one interaction with one customer - a call, email, meeting, chat, " +
			"note, sms or telegram - and nothing else. Name the customer with entity_id or " +
			"customer_name, never both: a substring that matches several customers is refused WITH " +
			"the candidates listed, so re-issue with the id rather than trying the name again. " +
			"summary is required and is the line a human will read later; full_content is the " +
			"body when there is one. direction is inbound (they contacted us), outbound (we " +
			"contacted them) or internal (a note, nobody was called). outcome records where the " +
			"thread stands - pending or escalated leaves it open and puts the customer on " +
			"get_followup_customers. follow_up_required needs follow_up_date: a flag with no day " +
			"is a wish. follow_up_action goes no further than this row; the followups table is a " +
			"different object with no writer in the schema, so nothing here creates a task. A " +
			"retry of the same call inside one turn is answered from the first one's result and " +
			"does not file a second copy of a phone call.",
		Parameters: object(map[string]any{
			"customer_name": text("Part or all of the customer's name."),
			"entity_id":     integer("The customer's entity id, preferred once one is known."),
			"contact_id": integer("The person actually spoken to, as contacts.id - never guessed " +
				"from the primary contact. This is the id, not the name: two contacts of one company " +
				"can share a name in the log and only one of them said the thing. Read it from " +
				"get_customer_communications' own rows, which carry contact_id beside contact_name; " +
				"on a customer you have never written up, there is no read here that produces one, " +
				"and the honest answer is to ask. 0021's finding is the reason it is not defaulted: " +
				"a wrong contact poisons vw_entity_communication_stats, which is derived from this " +
				"column and is what an escalation reads."),
			"communication_type": text("call, email, meeting, chat, note, sms or telegram. Default note."),
			"direction":          text("inbound, outbound or internal. Default outbound."),
			"subject":            text("A short line; threads are grouped by it."),
			"summary":            text("One line describing what happened. Required."),
			"full_content":       text("The body or transcript, when there is one."),
			"channel":            text("Free text - phone, email, web, telegram. What was used, not what type it was."),
			"sentiment_label":    text("positive, neutral, negative or mixed."),
			"priority":           text("low, medium or high."),
			"outcome":            text("resolved, pending, escalated or closed."),
			"duration_seconds":   integer("How long the interaction lasted."),
			"follow_up_required": boolean("Whether contact is owed."),
			"follow_up_date":     text("The day it is owed, YYYY-MM-DD. Required with follow_up_required."),
			"follow_up_action":   text("What to do about it."),
			"parent_id":          integer("The id of the message this replies to; roots the whole chain."),
			"started_at":         text("When the interaction happened, ISO-8601. Defaults to now."),
		}),
		Policy: tools.ToolPolicy{ReadOnly: false},
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			started, err := timestamp(str(args, "started_at"))
			if err != nil {
				return "", err
			}
			followDate, err := dateOnly(str(args, "follow_up_date"))
			if err != nil {
				return "", err
			}
			entity, err := id64(args, "entity_id")
			if err != nil {
				return "", err
			}
			contact, err := id64(args, "contact_id")
			if err != nil {
				return "", err
			}
			parent, err := id64(args, "parent_id")
			if err != nil {
				return "", err
			}
			dur, err := optionalInt(args, "duration_seconds")
			if err != nil {
				return "", err
			}

			vals := []any{
				str(args, "customer_name"), entity, contact,
				strDefault(args, "communication_type", "note"),
				strDefault(args, "direction", "outbound"),
				str(args, "subject"), str(args, "summary"), str(args, "full_content"),
				str(args, "channel"),
				// agent_id is the caller's identity, not the model's invention: it is what
				// vw_agent_activity_summary groups by, and a value the model can type is a value
				// the model can be asked to type.
				AgentID(),
				str(args, "sentiment_label"), str(args, "priority"), str(args, "outcome"),
				started, dur,
				boolArg(args, "follow_up_required", false), followDate,
				str(args, "follow_up_action"), parent,
			}
			row, err := q.Call(ctx, "add_communication",
				append(vals, key(ctx, "add_communication", vals)))
			if err != nil {
				return "", err
			}
			return answer(ctx, row, "add_communication")
		},
	}
}

func markCustomerFollowup(q Querier) tools.ToolDefinition {
	return tools.ToolDefinition{
		Name: "mark_customer_followup",
		Description: "Set or clear the follow-up mark on a customer's status. followup=true moves " +
			"status to follow-up and puts the account at the top of get_followup_customers for the " +
			"reason that a human decided, not that an inference did; followup=false returns it to " +
			"active. The answer is the word the database used - marked, already marked, cleared, " +
			"or unchanged (status is X) - and an inactive or blacklisted customer is refused rather " +
			"than promoted by overwriting that fact, so a refusal there is correct and retrying " +
			"will not help. Take this step after logging an interaction that leaves work owed.",
		Parameters: func() map[string]any {
			p := object(map[string]any{
				"entity_id": integer("The customer's entity id. Required."),
				"followup":  boolean("True to mark, false to clear. Default true."),
			})
			p["required"] = []string{"entity_id"}
			return p
		}(),
		Policy: tools.ToolPolicy{ReadOnly: false},
		ExecuteContext: func(ctx context.Context, args map[string]any) (string, error) {
			id, err := id64(args, "entity_id")
			if err != nil {
				return "", err
			}
			if id == nil {
				return "", fmt.Errorf("entity_id is required - name the customer to mark")
			}

			rows, err := q.Call(ctx, "mark_customer_followup",
				[]any{id, boolArg(args, "followup", true)})
			if err != nil {
				return "", err
			}
			if len(rows) == 0 {
				return "", fmt.Errorf("mark_customer_followup returned no row")
			}

			// This function answers with a bare scalar rather than a named column, and pgx calls
			// the column after the function. Renaming it to "result" here is not decoration: a
			// payload key that changes when a function is renamed is a key nothing documents,
			// and a tool whose entire answer is an unpredictable field name is one the model
			// cannot be told how to read.
			word := rows[0]["mark_customer_followup"]
			if word == nil {
				for _, v := range rows[0] {
					word = v
					break
				}
			}
			turn.Source(ctx, "entities", id)
			slog.Info("follow-up mark changed", "entity_id", id, "result", word)
			return Rows([]map[string]any{{"entity_id": id, "result": word}})
		},
	}
}

// ---------------------------------------------------------------------------
// Shared plumbing
// ---------------------------------------------------------------------------

// AgentID is what goes into communications.agent_id.
//
// It comes from the environment rather than from a tool argument on purpose. The column is the
// trail's answer to "which agent did this", and vw_agent_activity_summary groups by it, so a
// value the model can type is a value the model can be asked to type - which is the difference
// between an audit column and a note.
//
// It reads the same key agent.AgentName() reads, because the two columns are one fact: this process.
// An earlier draft read a separate AGENT_BOT_ID here, so setting AGENT_ROLE moved
// agent_interactions.bot_id and left communications.agent_id at the default - a deployment running as
// a second role would file its interactions under one name and its audit trail under another, which
// is the exact split the column exists to prevent. pkg/agent's TestAgentIdentityIsOneValue names that
// failure and checks for it.
func AgentID() any {
	if v := strings.TrimSpace(os.Getenv(EnvAgentRole)); v != "" {
		return v
	}
	return DefaultAgentRole
}

// key derives ADR-005's claim for one write inside one run.
//
// It is computed from the RESOLVED argument vector - the values actually sent to the function,
// after defaults and coercion - and not from the model's raw JSON. The two differ in both
// directions worth caring about: a retry that omits a field the first call spelled out resolves
// to the same request, and a retry that reorders fields resolves to the same request, whereas the
// raw maps do not. Deriving from raw JSON would therefore produce two different keys for one
// operation, which is not a deduplication failure in the abstract - it is a second copy of a
// phone call on a customer's record.
//
// An empty run id - a tool invoked outside a chat turn, from a test or a CLI - yields no key at
// all, so the door runs without deduplication. The alternative would be one constant uuid for
// every unattributed call, which would make the second customer created in a demo invisible to
// the first one's claim.
func key(ctx context.Context, toolName string, resolved []any) any {
	k := ids.CallKey(turn.RunID(ctx), toolName, resolved)
	if k == "" {
		slog.Debug("this write is not claim-guarded: no run id in context", "tool", toolName)
		return nil
	}
	return k
}

// answer renders a write door's single row. success=false is a result rather than an exception -
// that is the door's own contract, and 0016 chose it for a reason - but the log line separates
// them, because "which refusals does the model keep trying" is the first question worth asking
// about a deployed agent and it is unanswerable from the tool output alone.
//
// Sources are recorded from the answer row rather than from the arguments: an entity_id the
// database resolved is a fact, and one the model guessed is a hope.
func answer(ctx context.Context, rows []map[string]any, fn string) (string, error) {
	if len(rows) == 0 {
		return "", fmt.Errorf("%s returned no row: the operation did not happen", fn)
	}
	row := rows[0]

	ok, _ := row["success"].(bool)
	if !ok {
		slog.Info("write refused", "function", fn, "message", row["message"])
		return mustJSON(row)
	}

	slog.Info("write accepted", "function", fn,
		"entity_id", row["entity_id"], "communication_id", row["communication_id"],
		"contact_id", row["contact_id"], "message", row["message"])

	for _, col := range []string{"entity_id", "contact_id", "communication_id", "memory_id"} {
		if v, present := row[col]; present && v != nil {
			turn.Source(ctx, sourceTable(col), v)
		}
	}
	return mustJSON(row)
}

func sourceTable(column string) string {
	switch column {
	case "entity_id":
		return "entities"
	case "contact_id":
		return "contacts"
	case "communication_id":
		return "communications"
	case "memory_id":
		return "agent_memories"
	default:
		return column
	}
}

// withNote attaches an explanation to an empty result set. `[]` and "nothing matched" look alike
// in a transcript, and the difference decides whether the agent tells a human "no records" or
// tries the same query four more times.
func withNote(rows []map[string]any, note string) []map[string]any {
	if len(rows) > 0 {
		return rows
	}
	return []map[string]any{{"count": 0, "note": note}}
}

func object(props map[string]any) map[string]any {
	return map[string]any{
		"type":       "object",
		"properties": props,
	}
}

func text(desc string) map[string]any {
	return map[string]any{"type": "string", "description": desc}
}

func integer(desc string) map[string]any {
	// ["integer","string"] because a model that has just read a table of ids will quote one, and
	// these doors take a bigint either way (id64 accepts both). Declaring the type as strictly
	// integer would make the schema a lie about what the tool accepts, which is the class of
	// drift 0022 was written about - a signature that says one thing and a body that does another.
	return map[string]any{
		"type":        []string{"integer", "string"},
		"description": desc,
	}
}

func boolean(desc string) map[string]any {
	return map[string]any{"type": "boolean", "description": desc}
}

// clampInt reads an integer argument and bounds it. The default is used only when the argument is
// absent; a value that is present and outside [min,max] is an error rather than something to
// substitute, because silently replacing what the caller asked for is how a tool starts answering
// a different question than it was asked.
func clampInt(args map[string]any, name string, def, min, max int) (int, error) {
	if v, ok := args[name]; !ok || v == nil {
		return def, nil
	}
	n, err := days(args, name, def)
	if err != nil {
		return 0, err
	}
	if n < min || n > max {
		return 0, fmt.Errorf("%s must be between %d and %d, got %v", name, min, max, args[name])
	}
	return n, nil
}

func optionalInt(args map[string]any, name string) (any, error) {
	if v, ok := args[name]; !ok || v == nil {
		return nil, nil
	}
	n, err := days(args, name, 0)
	if err != nil {
		return nil, err
	}
	if n < 0 {
		return nil, fmt.Errorf("%s must not be negative", name)
	}
	return n, nil
}

// timestamp parses the ISO-8601 forms a model actually emits. Accepting four and refusing a
// fifth with a message that names them is cheaper than silently reading "2026-11-01" as UTC
// midnight when the caller meant local, which is 0022's finding in miniature.
// parseTemporal reads a string a date or timestamp column is being given, and reports whether the input
// named a zone. The two callers part company on what to do with that answer: timestamp() anchors a
// zone-less value in the container's zone, because a person writing "3 November, 2pm" means their own
// 2pm; dateOnly() has no use for the answer at all, because a calendar day has no zone to be wrong about.
//
// The anchor is the whole content of this function. time.Parse of a value with no zone in it yields that
// calendar day at midnight **UTC**, and the old code then called .Local() - which does not move the
// clock, it relabels the same instant. So in a container six hours behind UTC, "2026-11-03" meant
// 03:00 on the 3rd, and a bare date handed to a `date` column came back as the day before once anything
// formatted it in local time. ParseInLocation is the one call that means what the comment claimed.
func parseTemporal(s string) (t time.Time, bare bool, ok bool) {
	layouts := []struct {
		layout string
		bare   bool // no zone in the input, so local time is the caller's meaning
	}{
		{time.RFC3339Nano, false},
		{"2006-01-02T15:04:05", true},
		{"2006-01-02 15:04:05", true},
		{"2006-01-02", true},
	}
	for _, l := range layouts {
		p, err := time.Parse(l.layout, s)
		if err != nil {
			continue
		}
		if l.bare {
			p = time.Date(p.Year(), p.Month(), p.Day(), p.Hour(), p.Minute(), p.Second(),
				p.Nanosecond(), time.Local)
		}
		return p, l.bare, true
	}
	return time.Time{}, false, false
}

// errUnreadable is one message for both readers of a date-shaped argument, because a refusal that names
// the accepted forms in two places is a list that will be corrected in one of them.
func errUnreadable(s string) error {
	return fmt.Errorf("%q is not a date this tool reads "+
		"(try 2026-11-03T14:30:00Z, 2026-11-03 14:30:00 or 2026-11-03)", s)
}

func timestamp(v any) (any, error) {
	s, ok := v.(string)
	if !ok || strings.TrimSpace(s) == "" {
		return nil, nil
	}
	s = strings.TrimSpace(s)

	t, _, ok := parseTemporal(s)
	if !ok {
		return nil, errUnreadable(s)
	}
	return t, nil
}

func dateOnly(v any) (any, error) {
	s, ok := v.(string)
	if !ok || strings.TrimSpace(s) == "" {
		return nil, nil
	}
	t, _, ok := parseTemporal(strings.TrimSpace(s))
	if !ok {
		return nil, fmt.Errorf("follow_up_date: %w", errUnreadable(strings.TrimSpace(s)))
	}
	// p_follow_up_date is a `date`, not a timestamptz: it names a calendar day and carries no zone, so
	// the day must be read out of the value without any zone conversion at all. This used to go through
	// timestamp(), which anchored a bare input at midnight UTC and then relabelled it local - and
	// Format, applied to that relabelled instant in a container west of UTC, printed **the day before**.
	// A live turn asked for "next Tuesday", the reply said 2026-11-10, and the row stored 2026-11-09, a
	// Monday: the prose and the row disagreed and only the row is what vw_pending_followups acts on.
	//
	// Format takes the day from the location the parsed value already has, which for a bare input is the
	// day that was typed and for an input with an offset is the day in the zone the string states. Those
	// are the only two claims about a date that a caller can make.
	return t.Format("2006-01-02"), nil
}
