// Package logging is the verbose half of the agent: what happened, in a form a human can read
// from the container, and in a form a query can use afterwards.
//
// Two channels, on purpose, because they answer different questions and only one of them can
// carry raw customer data:
//
//   - slog to stdout answers "what is this process doing right now". It is structured, it is
//     gated by LOG_LEVEL, and PII fields are masked, because a container log is copied, indexed
//     and pasted in ways the database is not (AGENTS.md, Data Protection).
//   - one agent_interactions row per run answers "why did the agent say that", weeks later,
//     with the tool inputs and observations intact. That is ADR-001's rule, and 0017 built the
//     read path - vw_tool_calls, vw_tool_performance, vw_failed_interactions - that only works
//     if the writer keeps the shape the views derive from.
//
// The shape is a contract, so it is stated here rather than implied: actions_taken and
// tool_observations are arrays of equal length, aligned by position, one entry per tool call.
// vw_tool_calls joins step n of one to step n of the other by ordinality, and a run whose arrays
// differ in length shows mispaired calls rather than failing - which 0017 measured and probe H
// demonstrates. Every method in this file that could break that pairing maintains it explicitly.
package logging

import (
	"fmt"
	"log/slog"
	"os"
	"regexp"
	"sort"
	"strings"
)

// Environment names. LOG_LEVEL is the whole verbosity control; the default is info, and the
// deployment sets debug.
const (
	EnvLevel = "LOG_LEVEL"
	EnvFmt   = "LOG_FORMAT"
)

var (
	// piiKeys are the attribute names whose values are masked on stdout. The list is the
	// CRM's own vocabulary of contact points and names, read from the columns the tools accept.
	piiKeys = map[string]bool{
		"email": true, "phone": true, "mobile": true,
		"first_name": true, "last_name": true, "name": true,
		"street": true, "postal_code": true, "customer_name": true,
		"contact_id": true, "entity_id": true, "telegram_chat_id": true, "user_id": true,
	}

	// piiInText catches the same facts when they arrive inside a message string - a summary the
	// model echoed, an error that quoted a query. Partial by design: an address in prose stays,
	// an email address does not.
	piiInText = regexp.MustCompile(`(?i)([A-Za-z0-9._%+-]+)@([A-Za-z0-9.-]+\.[A-Za-z]{2,})`)

	phoneInText = regexp.MustCompile(`(?i)(\+?\d[\d ()\-.]{6,}\d)`)
)

// Setup configures the default logger and returns the level actually in force, which /api/health
// reports. A silently-ignored LOG_LEVEL=debuug is a support conversation waiting to happen.
func Setup() slog.Level {
	lvl := slog.LevelInfo
	switch strings.ToLower(strings.TrimSpace(os.Getenv(EnvLevel))) {
	case "debug":
		lvl = slog.LevelDebug
	case "warn", "warning":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	case "", "info":
	default:
		fmt.Fprintf(os.Stderr, "warning: %s=%q is not a level; using info\n", EnvLevel, os.Getenv(EnvLevel))
	}

	opts := &slog.HandlerOptions{
		Level: lvl,
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			if len(groups) == 0 && (a.Key == slog.TimeKey || a.Key == "level") {
				return a
			}
			if isKey(listLeaf(groups, a.Key)) {
				return slog.String(listLeaf(groups, a.Key), Mask(a.Value.String()))
			}
			return a
		},
	}

	if strings.EqualFold(os.Getenv(EnvFmt), "json") {
		slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, opts)))
	} else {
		slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, opts)))
	}
	return lvl
}

func listLeaf(groups []string, key string) string {
	if len(groups) > 0 {
		return groups[len(groups)-1]
	}
	return key
}

func isKey(k string) bool { return piiKeys[k] }

// Mask redacts contact details in a string destined for a log line. It is deliberately not
// applied to what goes into agent_interactions: the trajectory is the record an auditor
// cross-checks the trail against (0013's reason for auditing telemetry rows), and a masked
// tool_input there would make the row useless for the question it exists to answer.
func Mask(s string) string {
	if s == "" {
		return s
	}
	s = piiInText.ReplaceAllStringFunc(s, func(m string) string {
		parts := strings.SplitN(m, "@", 2)
		if len(parts) != 2 {
			return "***"
		}
		local := parts[0]
		keep := ""
		if len(local) > 1 {
			keep = local[:1]
		}
		return keep + "***@" + domainTail(parts[1])
	})
	s = phoneInText.ReplaceAllStringFunc(s, func(m string) string {
		digits := onlyDigits(m)
		if len(digits) < 4 {
			return "***"
		}
		return "***" + digits[len(digits)-4:]
	})
	return s
}

// MaskArgs is the debug-log form of a tool's arguments: keys sorted so two identical calls print
// identically, values masked.
func MaskArgs(args map[string]any) string {
	keys := make([]string, 0, len(args))
	for k := range args {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var b strings.Builder
	for i, k := range keys {
		if i > 0 {
			b.WriteByte(' ')
		}
		v := fmt.Sprintf("%v", args[k])
		if piiKeys[k] {
			v = Mask(v)
		} else if len(v) > 120 {
			v = v[:120] + "…"
		}
		b.WriteString(k)
		b.WriteByte('=')
		b.WriteString(v)
	}
	if b.Len() == 0 {
		return "(no arguments)"
	}
	return b.String()
}

func domainTail(d string) string {
	if i := strings.Index(d, "."); i > 0 && i+1 < len(d) {
		return d[i+1:]
	}
	return "*"
}

func onlyDigits(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return b.String()
}
