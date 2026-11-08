// Package turn carries the identity of the conversation a piece of code is running inside.
//
// It exists because a tool needs three facts it is not passed by the model: which run this call
// belongs to (the input to every idempotency key), which thread the caller is in (so a memory tool
// can scope itself), and somewhere to note which records the call touched (so the trajectory can
// say what the agent looked at without re-reading every tool output). Threading those through every
// function signature would touch each tool twice - once to accept them, once to ignore two of them -
// and a parameter list of pass-throughs is how a codebase grows an argument nobody can remove.
//
// The package imports nothing, which is the actual design constraint. The alternative homes for
// these helpers were pkg/tools and pkg/logging, and each forced an import cycle the fourth package
// resolved by copying the function.
package turn

import (
	"context"
	"log/slog"
)

type key int

const (
	runKey key = iota
	threadKey
	trailKey
)

// Trail is the run's record-keeping side, as the tools see it: a name to derive keys from and a place
// to note what a call touched.
//
// It is an interface rather than a concrete *logging.Run so that this package stays a leaf and the
// agent loop can pass whatever it uses to accumulate a trajectory, including a test double that
// asserts on the sources without a database anywhere near it.
type Trail interface {
	// ID is the run's unique identifier: the scope an idempotency key is derived within.
	ID() string
	// Source notes that this run touched a record, as "table:id".
	Source(table string, id any)
}

// From returns a context carrying the run, its trail, and the caller's thread.
//
// A nil parent is refused with the same panic every other function in this package will raise, rather
// than repaired into a Background(): context functions do not accept nil, and quietly accepting one
// here would mean a caller that lost the request's context kept working while dropping its deadline and
// cancellation. That is the worse of the two failures, and it is invisible.
func From(ctx context.Context, runID, threadID string, t Trail) context.Context {
	if ctx == nil {
		panic("turn: From called with a nil context")
	}
	ctx = context.WithValue(ctx, runKey, runID)
	ctx = context.WithValue(ctx, threadKey, threadID)
	if t != nil {
		ctx = context.WithValue(ctx, trailKey, t)
	}
	return ctx
}

// RunID is the current run's identifier, or "" outside a chat turn - a test, a CLI, a background
// job. Callers that build keys from it must handle that as "no key", not as an error: an unattributed
// write is a real case, and a constant key would collide across every one of them.
func RunID(ctx context.Context) string {
	if s, ok := ctx.Value(runKey).(string); ok {
		return s
	}
	return ""
}

// ThreadID is the caller's thread, or "".
func ThreadID(ctx context.Context) string {
	if s, ok := ctx.Value(threadKey).(string); ok {
		return s
	}
	return ""
}

// Source records that this turn touched a record. Outside a turn it is a no-op that says so at debug
// level: dropping a source silently is a trajectory that under-reports what the agent saw, and a
// debug line is the cheapest thing that keeps that honest.
func Source(ctx context.Context, table string, id any) {
	if t, ok := ctx.Value(trailKey).(Trail); ok && t != nil {
		t.Source(table, id)
		return
	}
	slog.Debug("source recorded outside a turn", "table", table, "id", id)
}
