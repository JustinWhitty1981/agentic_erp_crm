package orders

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"jada-backend/pkg/ids"
)

// str returns the argument as a string, or nil for "not supplied".
//
// nil is the value that reaches a function parameter as SQL NULL, which on these doors means
// "leave the column default alone" or "this optional fact was not mentioned" - not the empty
// string, which on a summary means the caller had nothing to say. An all-whitespace string is
// therefore treated as absent rather than as content, because a model that emits `"subject": " "`
// is not naming the subject, and forwarding it would store a blank the read paths then have to
// explain.
func str(args map[string]any, name string) any {
	v, ok := args[name]
	if !ok || v == nil {
		return nil
	}
	switch t := v.(type) {
	case string:
		s := strings.TrimSpace(t)
		if s == "" {
			return nil
		}
		return s
	case float64:
		// A number where a string was asked for: the CRM has numeric columns that are text by
		// declaration (entities.status, contacts.phone) and a model will send +15550100 as a JSON
		// number for either. Rendering it without an exponent is what keeps a phone number a phone
		// number.
		return strconv.FormatFloat(t, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(t)
	default:
		return fmt.Sprintf("%v", t)
	}
}

// strDefault is str for the arguments where an omitted value must not become NULL, because the
// function's DEFAULT is the answer the schema intends and passing NULL would defeat it -
// add_customer's p_country, whose default is 'US', accepts NULL and would store NULL.
//
// The default lives here as well as in the database, and that is the one place in this package
// where a value is stated twice. It is worth the duplication: sending NULL would be *correct*
// behaviour, and the difference between "the caller did not say" and "the caller said nothing" is
// invisible in the tool schema, so the tool says what it will do.
func strDefault(args map[string]any, name, def string) any {
	if v := str(args, name); v != nil {
		return v
	}
	return def
}

// id64 parses an integer key.
//
// The two conversions that lose are refused rather than rounded: 1.5 becoming 1, and a value
// beyond 2^53 arriving already altered by the JSON decoder. A tool that silently filed an
// interaction against a neighbouring customer id would be finding 4.5 in Go, and it would leave a
// trail that faithfully recorded the mistake.
func id64(args map[string]any, name string) (any, error) {
	v, ok := args[name]
	if !ok || v == nil {
		return nil, nil
	}
	switch t := v.(type) {
	case float64:
		if t != float64(int64(t)) {
			return nil, fmt.Errorf("%s must be a whole record id, got %v", name, t)
		}
		return int64(t), nil
	case int:
		return int64(t), nil
	case int64:
		return t, nil
	case string:
		s := strings.TrimSpace(t)
		if s == "" {
			return nil, nil
		}
		n, err := strconv.ParseInt(s, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("%s must be a whole record id, got %q", name, s)
		}
		return n, nil
	default:
		return nil, fmt.Errorf("%s must be a record id, got %T", name, v)
	}
}

// num reads a numeric the database already computed. pgx hands a numeric/decimal back as a string
// unless the caller asked for a different codec, so all three shapes are accepted and a fourth - a
// nil, meaning the column is unknown - answers false rather than zero. Every caller in this package
// uses that second return value, and the one place it is ignored is a bug: an unknown quantity added
// to a total is how a report starts lying.
func num(v any) (float64, bool) {
	switch t := v.(type) {
	case int64:
		return float64(t), true
	case int32:
		// int4, which is what an `integer` column is. Every numeric reader in these three forks was
		// written against the shapes a model's JSON arguments produce - float64, and the odd int64 -
		// so a row's int2 or int4 fell through to "not a number", which arrives as a zero rather than
		// as an error. pgx v5's own default map is the list worth copying: it sends int2 as int16,
		// int4 as int32, int8 as int64, float4 as float32, and numeric as pgtype.Numeric
		// (pgtype/pgtype_default.go:163-177).
		return float64(t), true
	case int16:
		return float64(t), true // smallint
	case uint64:
		return float64(t), true
	case float32:
		return float64(t), true // real
	case float64:
		return t, true
	case int:
		return float64(t), true
	case json.Number:
		// What pkg/db hands back for a numeric column since 2026-11-07. Before that case, every sum
		// this package took over a view fell through to `0, false`, and describe() printed the zero.
		f, err := strconv.ParseFloat(t.String(), 64)
		if err != nil {
			return 0, false
		}
		return f, true
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(t), 64)
		if err != nil {
			return 0, false
		}
		return f, true
	default:
		return 0, false
	}
}

// days reads an integer. The name is historical, inherited from the fork this package came from,
// and it is used for every whole number this package takes, because the coercion rules are identical and two helpers that differ
// only in which argument they were written for is how a package starts disagreeing with itself.
func days(args map[string]any, name string, def int) (int, error) {
	v, ok := args[name]
	if !ok || v == nil {
		return def, nil
	}
	switch t := v.(type) {
	case float64:
		if t != float64(int64(t)) {
			return 0, fmt.Errorf("%s must be a whole number, got %v", name, t)
		}
		return int(t), nil
	case string:
		s := strings.TrimSpace(t)
		if s == "" {
			return def, nil
		}
		n, err := strconv.Atoi(s)
		if err != nil {
			return 0, fmt.Errorf("%s must be a whole number, got %q", name, t)
		}
		return n, nil
	case int:
		return t, nil
	case int64:
		return int(t), nil
	default:
		return 0, fmt.Errorf("%s must be a number, got %T", name, v)
	}
}

// boolArg is a boolean the model may send as a JSON bool, the string "true", or 1.
//
// A string it cannot read answers with the default rather than an error, which is the one place
// this package chooses tolerance over precision. The reason is the flag's shape: it selects a
// branch, so a misread would be visible in the answer either way, and a refused tool call over
// `yes` versus `true` costs a whole turn.
func boolArg(args map[string]any, name string, def bool) any {
	v, ok := args[name]
	if !ok || v == nil {
		return def
	}
	switch t := v.(type) {
	case bool:
		return t
	case string:
		s := strings.ToLower(strings.TrimSpace(t))
		if s == "" {
			return def
		}
		b, err := strconv.ParseBool(s)
		if err != nil {
			return def
		}
		return b
	case float64:
		return t != 0
	default:
		return def
	}
}

// IdempotencyKey derives ADR-005's claim key for one tool call inside one run.
//
// The rules - which vector the key is drawn from, how its values are normalised, and why the scope
// is one run rather than one thread - are pkg/ids.CallKey's. This is a name, not a second
// implementation, so that the CRM's keys and the memory tools' keys cannot drift apart while both
// claim to obey ADR-005.
func IdempotencyKey(runID, toolName string, resolved []any) string {
	return ids.CallKey(runID, toolName, resolved)
}

// Rows is what every read tool returns: records rendered as the JSON string the agent loop hands
// to the model. The array is never null, because a reader that sees `null` cannot tell "no rows"
// from "the tool broke", and the second one is worth asking about.
func Rows(records []map[string]any) (string, error) {
	if records == nil {
		records = []map[string]any{}
	}
	return mustJSON(records)
}

func mustJSON(v any) (string, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// withNote attaches an explanation to an empty result set, and clampInt bounds an integer
// argument - both shared with the customer service agent's identically-named helpers, kept here
// because a tool that answers `[]` to "is anything low?" makes the model guess which silence it
// got, and a limit that silently substitutes is a tool answering a different question.
func withNote(rows []map[string]any, note string) []map[string]any {
	if len(rows) > 0 {
		return rows
	}
	return []map[string]any{{"count": 0, "note": note}}
}

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

// clauseFor rewrites a WHERE fragment's single `?` into the positional parameter that falls at
// argument index n, and reports whether the fragment carried an argument at all.
//
// That second question is the whole reason this helper exists, and it arrived from a bug rather
// than from taste: five of this package's filters are conditions with nothing to bind - `is_active`,
// `quantity_open > 0`, `ledger_agreement = 'DISAGREES'`, `is_terminal IS NOT TRUE`,
// `quantity_unresolved > 0` - and the clause builder appended a nil to the argument vector for each
// of them anyway. The SQL then never mentions that position, Postgres cannot infer a type for a
// parameter it cannot see, and the whole query is refused: `42P18 could not determine data type of
// parameter $2`. Nothing about those filters is optional from the model's side, so what a caller saw
// was a read tool that worked when they happened to pass a name and failed when they did not.
// get_suppliers refused 20 of its 28 calls on this server on 2026-11-07 - `is_active` is one of the
// five, and it is added on the default path - and the create_order case died several steps upstream
// of its own write because the agent could not find the supplier the previous case had registered.
//
// The rule belongs here rather than at the five call sites for the reason ADR-002 gives about SQL:
// a rule that lives in more than one place is enforced in none of them.
// TestNoQuerySendsAParameterItsSQLNeverNames is the version a sixth filter has to pass.
func clauseFor(fragment string, n int) (string, bool) {
	i := strings.Index(fragment, "?")
	if i < 0 {
		return fragment, false
	}
	return fragment[:i] + "$" + strconv.Itoa(n) + fragment[i+1:], true
}
