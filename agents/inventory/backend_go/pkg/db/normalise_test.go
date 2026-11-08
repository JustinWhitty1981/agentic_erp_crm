package db

import (
	"encoding/json"
	"fmt"
	"github.com/jackc/pgx/v5/pgtype"
	"math/big"
	"testing"
	"time"
)

// TestNormaliseRendersValuesTheWayACallerReadsThem covers the row-to-JSON step every tool's answer
// passes through, and which produced the bug that made this file exist: a uuid column decoded into a
// [16]byte array, and encoding/json rendering that as sixteen numbers in a JSON array. Nothing failed,
// the shape was simply unreadable, and the only place it was visible was a trajectory endpoint a human
// would consult once, in an emergency.
func TestNormaliseRendersValuesTheWayACallerReadsThem(t *testing.T) {
	raw := [16]byte{
		0x01, 0xa1, 0xa6, 0xd7, 0xb8, 0xd9, 0x40, 0x60,
		0xbf, 0x8e, 0xdd, 0xe7, 0xee, 0xcb, 0x24, 0x00,
	}
	got, ok := normalise(raw).(string)
	if !ok {
		t.Fatalf("normalise([16]byte) = %T, want a string", normalise(raw))
	}
	if want := "01a1a6d7-b8d9-4060-bf8e-dde7eecb2400"; got != want {
		t.Errorf("normalise([16]byte) = %q, want %q", got, want)
	}

	// The same value through the encoder, because the failure was never in normalise's types alone -
	// it was what json does with what normalise returned.
	b, err := json.Marshal(map[string]any{"interaction_id": normalise(raw)})
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"interaction_id":"01a1a6d7-b8d9-4060-bf8e-dde7eecb2400"}`; string(b) != want {
		t.Errorf("marshalled as %s, want %s", b, want)
	}
}

func TestNormaliseLeavesTheOtherTypesAlone(t *testing.T) {
	if normalise(nil) != nil {
		t.Error("nil became something")
	}

	// A timestamp keeps its offset: 0022's finding was that a staleness clock read from the wrong
	// column of the wrong clock changes whether a follow-up is due.
	ts := time.Date(2026, 11, 4, 12, 0, 0, 0, time.UTC)
	if got, _ := normalise(ts).(string); got != "2026-11-04T12:00:00Z" {
		t.Errorf("time = %q, want the RFC3339 form with a zone", got)
	}
	if v := normalise(time.Time{}); v != nil {
		t.Errorf("a zero time rendered as %v; every caller that sees a timestamp treats absent as nil, "+
			"so year 1 is a lie about when something happened", v)
	}

	// Text held in a byte slice - what a `bytea`-typed or undecoded text column arrives as - must not
	// become base64.
	if got, _ := normalise([]byte("Grace Okafor")).(string); got != "Grace Okafor" {
		t.Errorf("[]byte text = %q, want the string it holds", got)
	}
	if s, ok := normalise([]byte{0xff, 0xfe, 0x00}).(string); ok {
		t.Errorf("non-UTF8 bytes became the string %q; they should stay bytes and be base64 at the edge", s)
	}
}

// TestNormaliseMakesNumericColumnsReadable is the second shape this file exists for, and the one no
// JSON reader ever saw: pgx hands a `numeric` column over as pgtype.Numeric, a struct that
// encoding/json renders correctly because the type implements Marshaler. Everything downstream of the
// encoder reads Go instead of JSON, and `%v` on that struct is what a deployed agent was printing.
func TestNormaliseMakesNumericColumnsReadable(t *testing.T) {
	for _, tc := range []struct {
		name string
		in   pgtype.Numeric
		text string // what a sentence built with %v must contain
	}{
		// 1320.00000000, the shape vw_inventory_valuation.total_value answers with.
		{"scale kept", pgtype.Numeric{Int: big.NewInt(132000000000), Exp: -8, Valid: true}, "1320.00000000"},
		{"zero", pgtype.Numeric{Int: big.NewInt(0), Exp: 0, Valid: true}, "0"},
		// 30.0000, which is the value the inventory check's line printed as {300000 -4 false finite true}.
		{"negative exponent", pgtype.Numeric{Int: big.NewInt(300000), Exp: -4, Valid: true}, "30.0000"},
		// NaN is legal in a Postgres numeric and illegal in JSON, so it stays a string and stays
		// quoted - the same bytes pgx's own marshaller produced before this case existed.
		{"not a number", pgtype.Numeric{NaN: true, Valid: true}, "NaN"},
		{"null", pgtype.Numeric{}, "<nil>"},
	} {
		got := normalise(tc.in)
		if s := fmt.Sprintf("%v", got); s != tc.text {
			t.Errorf("%s: normalise renders as %q; a sentence using it must read %q", tc.name, s, tc.text)
		}
		b, err := json.Marshal(map[string]any{"v": got})
		if err != nil {
			t.Errorf("%s: does not marshal: %v", tc.name, err)
			continue
		}
		if !json.Valid(b) {
			t.Errorf("%s: produced invalid JSON: %s", tc.name, b)
		}
	}

	// The claim that makes this a fix rather than a reformatting: the JSON a tool returns is
	// byte-identical to what the same column produced before normalise noticed it.
	raw := pgtype.Numeric{Int: big.NewInt(132000000000), Exp: -8, Valid: true}
	before, err := json.Marshal(map[string]any{"total_value": raw})
	if err != nil {
		t.Fatal(err)
	}
	after, err := json.Marshal(map[string]any{"total_value": normalise(raw)})
	if err != nil {
		t.Fatalf("a normalised numeric must still marshal: %v", err)
	}
	if string(before) != string(after) {
		t.Errorf("the fix changed a tool's JSON: was %s, now %s", before, after)
	}
	if string(after) != `{"total_value":1320.00000000}` {
		t.Errorf("unexpected numeric form %s", after)
	}
}
