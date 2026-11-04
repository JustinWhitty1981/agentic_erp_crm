package main

import (
	"context"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"jada-backend/pkg/db"
)

// TestTrajectoryViewNamesAreComplete is the no-database half: every key the endpoint will accept has to
// resolve to a relation. Without it a view added to the map and not to viewName would reach SQL as
// "SELECT ... FROM ", which is a 42601 on the request path rather than a failure here.
func TestTrajectoryViewNamesAreComplete(t *testing.T) {
	for name := range trajectoryViews {
		if viewName(name) == "" {
			t.Errorf("%q is a documented value of ?view= and maps to no relation", name)
		}
		if !strings.HasPrefix(viewName(name), "vw_") {
			t.Errorf("%q reads from %q; the naming rule is that an agent-facing read is a view",
				name, viewName(name))
		}
	}
	if len(trajectoryViews) != 4 {
		t.Errorf("%d trajectory listings; agents/customer_service/README.md documents four",
			len(trajectoryViews))
	}
}

// TestTrajectoryViewsNameRealColumns is the one that would have prevented two of the four endpoints
// from being dead on arrival.
//
// ?view=tool_calls and ?view=performance both answered 502 the first time anyone asked: the shared
// `ORDER BY "timestamp" DESC` names a column neither view has, and tool_calls projected tool_output
// where the view's column is observation. Nothing caught it because nothing had called them, which is
// the general shape of the failure - an endpoint that has never been exercised is documentation that
// happens to compile.
//
// The check reads pg_attribute, not the SQL text, and that is the whole point: a test that compares the
// query to itself is consistent and worthless.
func TestTrajectoryViewsNameRealColumns(t *testing.T) {
	if os.Getenv(db.EnvHost) == "" || os.Getenv(db.EnvPassword) == "" {
		t.Skip("AFPC_PG_HOST and AFPC_PG_PASSWORD are unset: this test asks the catalog which columns exist")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	d, err := db.Open(ctx)
	if err != nil {
		t.Skipf("cannot reach the database (%v)", err)
	}
	defer d.Close()

	// One read for the whole schema's views, so the test is a query rather than twenty.
	rows, err := d.Query(ctx, `SELECT c.relname, a.attname
		FROM pg_attribute a
		JOIN pg_class c ON c.oid = a.attrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = 'public' AND c.relkind = 'v' AND a.attnum > 0 AND NOT a.attisdropped`)
	if err != nil {
		t.Fatalf("reading the catalog: %v", err)
	}
	real := map[string]map[string]bool{}
	for _, r := range rows {
		v, _ := r["relname"].(string)
		a, _ := r["attname"].(string)
		if real[v] == nil {
			real[v] = map[string]bool{}
		}
		real[v][a] = true
	}
	if len(real) == 0 {
		t.Skip("this database has no views, so there is nothing to compare against")
	}

	for name, v := range trajectoryViews {
		relation := viewName(name)
		have, ok := real[relation]
		if !ok {
			t.Errorf("%s (?view=%s) does not exist in this database", relation, name)
			continue
		}
		for _, col := range splitCols(v.cols + ", " + v.order) {
			if col == "" {
				continue
			}
			if !have[col] {
				t.Errorf("?view=%s: %s has no column %q (similar names the view does have: %s). "+
					"vw_tool_calls's chronology is interaction_at and its tool result is observation, "+
					"which are the two renames 0017 made when it derived the view from the trajectory "+
					"instead of shipping a second log",
					name, relation, col, strings.Join(wantCols(have, col), ", "))
			}
		}
	}
}

// wantCols exists only to make the failure message useful: a wrong name is worth seeing beside the
// names the view really has. Prefix matching alone was useless the first time it ran - "timestamp"
// shares no three characters with "interaction_at" - so an empty match falls back to the whole list,
// which is short enough for a view and is the information a fixer needed anyway.
func wantCols(have map[string]bool, wrong string) []string {
	var out []string
	for c := range have {
		if len(wrong) >= 3 && strings.Contains(c, wrong[:3]) {
			out = append(out, c)
		}
	}
	if len(out) == 0 {
		for c := range have {
			out = append(out, c)
		}
	}
	sort.Strings(out)
	if len(out) > 12 {
		out = out[:12]
	}
	return out
}

// splitCols pulls identifiers out of a column list and an ORDER BY clause. Keywords and functions are
// dropped by the same rule for both, and a name that survives is one the database has to have.
func splitCols(text string) []string {
	drop := map[string]bool{
		"ORDER": true, "BY": true, "DESC": true, "ASC": true, "SELECT": true, "FROM": true, "LIMIT": true,
		"NULLS": true, "FIRST": true, "LAST": true,
	}
	fields := strings.FieldsFunc(text, func(r rune) bool {
		return r == ',' || r == ' ' || r == '\n' || r == '\t' || r == '"' || r == '`'
	})
	out := make([]string, 0, len(fields))
	for _, f := range fields {
		f = strings.TrimSpace(f)
		if f == "" || drop[strings.ToUpper(f)] {
			continue
		}
		// Skip anything that is not an identifier at all (a leftover parenthesis from a function call).
		if strings.ContainsAny(f, "()$*") {
			continue
		}
		out = append(out, strings.ToLower(f))
	}
	return out
}
