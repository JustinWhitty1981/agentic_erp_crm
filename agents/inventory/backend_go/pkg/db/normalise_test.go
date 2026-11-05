package db

import (
	"encoding/json"
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
