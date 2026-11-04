// Command server is the customer service agent's HTTP interface: a chat endpoint, a streaming chat
// endpoint, and the read paths that make what the agent did inspectable.
//
// The startup order is the interesting part, and it is the reason main looks like this:
//
//  1. logging first, so everything after it is recorded rather than printed;
//  2. the database next, because the tool list depends on whether it answered;
//  3. tools, memory, then the agent, then the router.
//
// A database that is unreachable does not stop the process. It changes which tools are registered -
// see registerTools - and the health endpoint says which mode it came up in. The alternative,
// refusing to start, would take the UI and the memory tools down over a dependency that a reader can
// see in one field, and it would make the container restart-loop on a maintenance window.
//
// "Unreachable" is measured, not claimed: connect() waits out a short grace window (see pingGrace)
// before deciding, because on a host reboot the agent's first dial lands a few hundred milliseconds
// before postgres logs that it is ready to accept connections, and one attempt at that is a coin flip
// the agent used to lose.
package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"jada-backend/pkg/agent"
	"jada-backend/pkg/crm"
	"jada-backend/pkg/db"
	"jada-backend/pkg/logging"
	"jada-backend/pkg/mcp"
	"jada-backend/pkg/memory"
	"jada-backend/pkg/tools"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/cors"
)

const version = "1.0.0-customer-service"

// Env names this binary reads. Anything not here is read by the package that owns it (pkg/db's
// AFPC_PG_*, pkg/logging's LOG_*, and AGENT_ROLE, which pkg/agent resolves through crm because that
// is the package that writes it into communications.agent_id), and
// scripts/docs/check_agent_docs.sh fails when a key used in compose is missing from one of those
// tables.
const (
	EnvAPIKeys   = "API_KEYS"
	EnvPort      = "PORT"
	EnvHost      = "HOST"
	EnvLogLevel  = "LOG_LEVEL"
	EnvLogFormat = "LOG_FORMAT"
	EnvMemoryDrv = "MEMORY_DRIVER"
	EnvReqApprov = "REQUIRE_WRITE_APPROVAL"
	EnvStream    = "LLM_STREAM"
	EnvMaxIter   = "MAX_TOOL_ITERATIONS"
	EnvTrace     = "LOG_AGENT_INTERACTIONS"
	EnvBodyLimit = "MAX_BODY_BYTES"
	EnvCORS      = "CORS_ORIGINS"
)

type ChatRequest struct {
	Message  string `json:"message"`
	ThreadID string `json:"thread_id,omitempty"`
	UserID   string `json:"user_id,omitempty"`
}

type ChatResponse struct {
	Response string `json:"response"`
	ThreadID string `json:"thread_id"`
	RunID    string `json:"run_id,omitempty"`
}

func main() {
	lvl := logging.Setup()
	log.SetOutput(io.Discard) // stdlib log is chi's; routing it to slog keeps one format

	started := time.Now()
	slog.Info("customer service agent starting",
		"version", version, "pid", os.Getpid(),
		"role", agent.AgentName(), "log_level", lvl.String())

	// The runtime configuration that changes behaviour, in one line, at startup. This is what makes
	// "which build is this" answerable without reading the container's environment.
	slog.Info("configuration",
		"provider", envOr("LLM_PROVIDER", "local"),
		"memory_driver", envOr(EnvMemoryDrv, memory.Driver()),
		"write_approval", envYes(EnvReqApprov),
		"streaming", envOr(EnvStream, "true"),
		"trajectory", envOr(EnvTrace, "true"),
		"auth", authMode())

	d, dbConfigured := connect()

	toolsList := registerTools(d)
	agentMgr := agent.NewAgentManager(toolsList)
	agentMgr.AttachRecorder(logging.NewRecorder(d, !envFalse(EnvTrace)))

	var rehydrator crm.Querier
	if d != nil {
		rehydrator = d
	}

	r := buildRouter(agentMgr, d, rehydrator, toolsList, dbConfigured)

	addr := fmt.Sprintf("%s:%s", envOr(EnvHost, "0.0.0.0"), envOr(EnvPort, "8000"))
	srv := &http.Server{
		Addr:              addr,
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
		// IdleTimeout matters more than it looks for this service: a chat turn streams for up to
		// 180s and a browser holds the connection open afterwards, so a too-short idle timeout
		// closes the socket between turns and the UI sees a dropped connection rather than an idle
		// one. ReadTimeout is deliberately unset for the same reason - the body of a chat request
		// arrives in one piece, but a long turn must not be cut off mid-stream.
		IdleTimeout: 750 * time.Second,
	}

	go func() {
		slog.Info("listening", "addr", addr, "tools", len(toolsList),
			"startup_ms", time.Since(started).Milliseconds())
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("server failed", "err", err)
			os.Exit(1)
		}
	}()

	// A container gets SIGTERM from docker stop and nothing else. Exiting without Shutdown would cut
	// every in-flight turn at the moment the proxy already knows it is gone, and a run interrupted
	// that way is exactly the row the trajectory exists to record.
	sig := make(chan os.Signal, 2)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	s := <-sig
	slog.Info("shutdown signal received", "signal", s.String())

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		slog.Error("graceful shutdown exceeded its deadline", "err", err)
	}
	if d != nil {
		d.Close()
	}
	slog.Info("stopped", "uptime", time.Since(started).Round(time.Second).String())
}

// connect opens the database, or returns nil with the reason recorded. The bool says whether one
// was *configured* - AFPC_PG_HOST set - because that distinction is what healthHandler needs: a
// machine with no database at all is the file-backed mode the deployment chose, while a configured
// database that never answered is the same process gone blind, and only the second one deserves an
// unhealthy verdict.
func connect() (*db.DB, bool) {
	if strings.TrimSpace(os.Getenv(db.EnvHost)) == "" {
		slog.Warn("no database configured: the CRM tools are not registered and memory is file-backed",
			"missing", db.EnvHost)
		return nil, false
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	d, err := db.Open(ctx)
	if err != nil {
		slog.Error("database configuration failed; starting without the CRM tools",
			"err", err, "config", configOf(err))
		return nil, true
	}

	// Ping tells the difference between "the pool exists" and "the tenant works", and the second one
	// is the failure mode that matters here: a connection that succeeds but has no tenant answers
	// every query with zero rows, because row security is filtering on a GUC nobody set. That is
	// indistinguishable from an empty database from the outside, so it is checked at startup.
	//
	// The check gets a grace window rather than one attempt. This container and afpc-pg are separate
	// compose projects, so nothing orders them: on a host reboot the dial can land while postgres is
	// still starting and answers connection refused for under a second - measured at both boots on
	// 2026-11-04, the agent dalling 450ms and 515ms before the log line that said it was ready. One
	// refused socket used to mean the agent ran all day with zero CRM tools and a model guessing at
	// their names.
	if err := retryPing(ctx, pingGrace, time.Second, d.Ping); err != nil {
		slog.Error("database is unreachable; starting without the CRM tools",
			"err", err, "config", d.String(), "waited", pingGrace.String())
		return nil, true
	}

	var tenant string
	if err := d.Pool().QueryRow(ctx,
		"SELECT coalesce(current_setting('app.tenant_id', true), '')").Scan(&tenant); err != nil {
		slog.Error("could not read the tenant this connection resolves to", "err", err)
	} else if strings.TrimSpace(tenant) == "" {
		slog.Warn("app.tenant_id is unset on this connection: row security will filter every query "+
			"to the server default, which is a real tenant but not necessarily the intended one",
			"fallback_used", true)
	}

	memory.Use(d)
	slog.Info("database connected", "config", d.String(), "tenant_guc", tenant)
	return d, true
}

// pingGrace is how long connect() waits for a database that is refusing before it registers no CRM
// tools and moves on. It is deliberately far longer than the measured boot race and far shorter than
// a maintenance window a restart should not sit through, so the common case resolves on the second
// attempt and the rare one gives up while the operator is still watching the logs.
const pingGrace = 15 * time.Second

// retryPing calls ping with exponential backoff until it succeeds, the window runs out, or ctx ends.
// It returns the last error, because that is the one whose text the startup log should carry.
func retryPing(ctx context.Context, grace, firstBackoff time.Duration, ping func(context.Context) error) error {
	err := ping(ctx)
	deadline := time.NewTimer(grace)
	defer deadline.Stop()
	backoff := firstBackoff
	for err != nil {
		select {
		case <-ctx.Done():
			return err
		case <-deadline.C:
			return err
		case <-time.After(backoff):
		}
		err = ping(ctx)
		if backoff *= 2; backoff > 5*time.Second {
			backoff = 5 * time.Second
		}
	}
	return nil
}

func configOf(err error) string {
	if errors.Is(err, db.ErrNoTenant) {
		return db.EnvTenant + " is missing"
	}
	return "unreadable"
}

// registerTools builds the tool list, which is a function of what the environment configured.
//
// A tool registered against a database that is not there is worse than a missing tool: the model was
// told about it in the prompt, it will call it, and the failure will look like a data problem. So the
// CRM tools appear only with a connection, and the health endpoint and /api/tools both report the
// difference, which is the only way a support conversation can tell "no customers" from "no database".
func registerTools(d *db.DB) []tools.ToolDefinition {
	var crmTools []tools.ToolDefinition
	if d != nil {
		crmTools = crm.Tools(d)
	}

	list := append(tools.GetLocalTools(), crmTools...)
	list = append(list, mcp.GetHighByteMCPTools()...)

	names := make([]string, 0, len(list))
	for _, t := range list {
		names = append(names, t.Name)
	}
	slog.Info("tools registered", "count", len(list), "names", strings.Join(names, " "),
		"crm", len(crmTools) > 0)

	if len(crmTools) == 0 {
		slog.Warn("no CRM tools: this agent can search the web and remember things but cannot see a " +
			"customer. Either AFPC_PG_HOST and AFPC_TENANT_ID are unset, or the database they name " +
			"refused startup's attempts to reach it - check the line above this one.")
	}
	return list
}

func buildRouter(am *agent.AgentManager, d *db.DB, q crm.Querier, list []tools.ToolDefinition, dbConfigured bool) *chi.Mux {
	r := chi.NewRouter()

	r.Use(chimw.RequestID)
	r.Use(chimw.RealIP)
	r.Use(accessLog)
	r.Use(chimw.Recoverer)
	r.Use(cors.Handler(cors.Options{
		// The default is same-origin only, and the reason it is not "*" is the auth token: a CORS
		// wildcard and a bearer token is a page on someone's laptop that can use the agent against
		// this tenant.
		AllowedOrigins:   allowedOrigins(),
		AllowedMethods:   []string{"GET", "POST", "OPTIONS"},
		AllowedHeaders:   []string{"Accept", "Authorization", "Content-Type", "X-API-Key"},
		AllowCredentials: true,
		MaxAge:           300,
	}))

	bodyLimit := int64(1 << 20)
	if v := os.Getenv(EnvBodyLimit); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			bodyLimit = n
		} else {
			slog.Warn("MAX_BODY_BYTES is not a positive number; keeping the default",
				"value", v, "default_bytes", bodyLimit)
		}
	}

	r.Get("/api/health", healthHandler(am, d, list, dbConfigured))

	// Everything below answers as the tenant, so everything below is authenticated.
	r.Group(func(pr chi.Router) {
		pr.Use(apiKey)
		pr.Use(func(next http.Handler) http.Handler {
			return http.MaxBytesHandler(next, bodyLimit)
		})

		pr.Post("/api/chat", chatHandler(am, q))
		pr.Post("/api/chat/stream", streamHandler(am, q))
		pr.Post("/api/reset", resetHandler(am))
		pr.Get("/api/history", historyHandler(am))
		pr.Get("/api/tools", toolsHandler(am))
		pr.Get("/api/interactions", interactionsHandler(q))
	})

	staticDir := pickStatic()
	if staticDir != "" {
		fileServer := http.FileServer(http.Dir(staticDir))
		r.Handle("/*", fileServer)
		r.Handle("/static/*", http.StripPrefix("/static/", fileServer))
		slog.Info("serving the UI", "dir", staticDir)
	} else {
		r.Get("/", func(w http.ResponseWriter, _ *http.Request) {
			writeJSON(w, http.StatusOK, map[string]string{
				"service": "customer service agent", "version": version,
				"docs": "/api/health",
			})
		})
	}
	return r
}

// ---------------------------------------------------------------------------
// Middleware
// ---------------------------------------------------------------------------

// authMode is what the startup line and /api/health report, because "is this endpoint open" is the
// first question worth asking of a deployment and it should not require reading the code to answer.
func authMode() string {
	raw := strings.TrimSpace(os.Getenv(EnvAPIKeys))
	switch {
	case raw == "":
		return "DISABLED"
	case strings.Contains(strings.ToLower(raw), "dev-key"):
		return "reference-token"
	default:
		return "enabled"
	}
}

func keyList() []string {
	raw := strings.TrimSpace(os.Getenv(EnvAPIKeys))
	if raw == "" {
		return nil
	}
	var out []string
	for _, k := range strings.Split(raw, ",") {
		if k = strings.TrimSpace(k); k != "" {
			out = append(out, k)
		}
	}
	return out
}

// apiKey guards every endpoint that answers as the tenant.
//
// The reason is the tenant: it is resolved once, from the environment, for the whole process, so
// an open endpoint is an open window into one tenant's customer records - names, phone numbers, and
// the full text of every interaction. The reference deployment sat on a LAN IP with no auth, which
// was a reasonable choice for a demo and is not one for this.
//
// Comparison is constant-time, and the digest is taken before the compare so that a key of one
// deployment's length cannot be inferred from how long the check took.
// warnOnce is why the unauthenticated warning used to print six times on an otherwise quiet startup:
// apiKey is installed per route group, so the same condition was discovered six times. A warning that
// repeats is a warning that reads as louder rather than as already-seen, and the line is worth exactly
// one look.
var warnOnce sync.Once

func apiKey(next http.Handler) http.Handler {
	keys := keyList()
	if len(keys) == 0 {
		warnOnce.Do(func() {
			slog.Warn("API_KEYS is unset: every authenticated endpoint is open. This is fine on a "+
				"loopback port and never fine on a network address.", "env", EnvAPIKeys)
		})
		return next
	}

	want := make([][]byte, len(keys))
	for i, k := range keys {
		sum := sha256.Sum256([]byte(k))
		want[i] = sum[:]
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := bearer(r)
		if got == "" {
			authFail(w, r, "no credential presented")
			return
		}
		sum := sha256.Sum256([]byte(got))
		ok := false
		for _, k := range want {
			if subtle.ConstantTimeCompare(sum[:], k) == 1 {
				ok = true
				break
			}
		}
		if !ok {
			authFail(w, r, "the credential is not one this agent knows")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func bearer(r *http.Request) string {
	if h := r.Header.Get("Authorization"); h != "" {
		if len(h) > 7 && strings.EqualFold(h[:7], "bearer ") {
			return strings.TrimSpace(h[7:])
		}
		return strings.TrimSpace(h)
	}
	return strings.TrimSpace(r.Header.Get("X-API-Key"))
}

// authFail logs the fingerprint rather than the key. A rejected credential in a log line is a
// plaintext password in a log file, and the log is the part of this system that gets shipped.
func authFail(w http.ResponseWriter, r *http.Request, why string) {
	sum := sha256.Sum256([]byte(bearer(r)))
	slog.Warn("request refused",
		"path", r.URL.Path, "remote", r.RemoteAddr,
		"why", why, "presented", "sha256:"+hex.EncodeToString(sum[:8]))
	writeJSON(w, http.StatusUnauthorized, map[string]string{
		"error": "not authorised", "detail": why,
		"how": "send the key in an 'Authorization: Bearer <key>' header",
	})
}

// accessLog replaces chi's stdlib logger so HTTP lines share the format and the level of everything
// else. A 401 is logged at warn, because on this service it means someone is trying, not that a page
// is loading.
func accessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ww := chimw.NewWrapResponseWriter(w, r.ProtoMajor)
		next.ServeHTTP(ww, r)

		status := ww.Status()
		attrs := []any{
			"method", r.Method, "path", r.URL.Path, "status", status,
			"ms", time.Since(start).Milliseconds(), "bytes", ww.BytesWritten(),
			"remote", r.RemoteAddr, "request_id", chimw.GetReqID(r.Context()),
		}
		switch {
		case status >= 500:
			slog.Error("request failed", attrs...)
		case status == http.StatusUnauthorized:
			slog.Warn("request refused", attrs...)
		case status >= 400:
			slog.Info("client error", attrs...)
		default:
			slog.Debug("request", attrs...)
		}
	})
}

func allowedOrigins() []string {
	if v := strings.TrimSpace(os.Getenv(EnvCORS)); v != "" {
		var out []string
		for _, o := range strings.Split(v, ",") {
			if o = strings.TrimSpace(o); o != "" {
				out = append(out, o)
			}
		}
		return out
	}
	// Loopback. The UI is served by this very process, so same-origin needs no entry and this list only
	// matters for a browser on another machine - which is a decision the operator makes with
	// CORS_ORIGINS rather than a default a source file can know. An earlier version named this
	// repository's own development host here, which is both wrong for every other clone and an
	// instruction to a stranger's browser to talk to somebody's LAN. cmd/server's
	// TestDefaultOriginsAreLoopbackOnly is what keeps it out again.
	return []string{"http://localhost:4550", "http://127.0.0.1:4550"}
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

func chatHandler(am *agent.AgentManager, q crm.Querier) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req ChatRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "the request body is not JSON", "detail": err.Error()})
			return
		}
		if strings.TrimSpace(req.Message) == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "message is required"})
			return
		}
		thread := threadOf(req)
		am.Rehydrate(r.Context(), q, thread)

		out, err := am.RunChatSync(r.Context(), thread, req.Message)
		if err != nil {
			// 200 with an error field is what the reference did, and it is wrong in a specific way:
			// the UI cannot tell a failed turn from a successful one without parsing prose, and a
			// client that retries on 5xx would then be able to. The answer text still comes back,
			// because for a refused tool call the sentence IS the useful part.
			writeJSON(w, http.StatusBadGateway, ChatResponse{
				Response: fmt.Sprintf("I could not finish that: %v", err), ThreadID: thread})
			return
		}
		writeJSON(w, http.StatusOK, ChatResponse{Response: out, ThreadID: thread})
	}
}

func streamHandler(am *agent.AgentManager, q crm.Querier) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "streaming is not supported by this server", http.StatusInternalServerError)
			return
		}

		var req ChatRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "invalid JSON body", http.StatusBadRequest)
			return
		}
		if strings.TrimSpace(req.Message) == "" {
			http.Error(w, "message is required", http.StatusBadRequest)
			return
		}
		thread := threadOf(req)
		am.Rehydrate(r.Context(), q, thread)

		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")
		w.Header().Set("X-Accel-Buffering", "no") // nginx in front of the container must not buffer

		eventChan := make(chan agent.SSEEvent, 256)
		go am.RunChatStream(r.Context(), thread, req.Message, eventChan)

		// The keepalive is not politeness. A tool call that takes 40s emits nothing, and a proxy or
		// a browser that gives up on a silent connection ends the turn; one comment line every 15s
		// is what keeps a long call looking alive rather than hung.
		keepalive := time.NewTicker(15 * time.Second)
		defer keepalive.Stop()

		for {
			select {
			case <-r.Context().Done():
				slog.Info("stream closed by the client", "thread_id", thread)
				return
			case <-keepalive.C:
				fmt.Fprint(w, ": keepalive\n\n")
				flusher.Flush()
			case ev, open := <-eventChan:
				if !open {
					return
				}
				b, err := json.Marshal(ev)
				if err != nil {
					slog.Error("event could not be encoded", "err", err)
					continue
				}
				fmt.Fprintf(w, "data: %s\n\n", b)
				flusher.Flush()
				keepalive.Reset(15 * time.Second)
			}
		}
	}
}

func resetHandler(am *agent.AgentManager) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		thread := r.URL.Query().Get("thread_id")
		if thread == "" {
			thread = "default"
		}
		am.ResetHistory(thread)
		writeJSON(w, http.StatusOK, map[string]string{
			"status": "success",
			// The wording matters: this clears what the model is shown, not what the database
			// recorded. A reader who believes otherwise will think a conversation was deleted.
			"message": "conversation context cleared for " + thread +
				" - the history of runs is still in the database",
		})
	}
}

func historyHandler(am *agent.AgentManager) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		thread := r.URL.Query().Get("thread_id")
		if thread == "" {
			thread = "default"
		}
		hist := am.GetHistory(thread)
		writeJSON(w, http.StatusOK, map[string]any{
			"thread_id":     thread,
			"history":       hist,
			"message_count": len(hist),
			"note":          "in-process context only; the durable record is /api/interactions",
		})
	}
}

func toolsHandler(am *agent.AgentManager) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		infos := make([]map[string]any, 0, len(am.ToolList))
		for _, t := range am.ToolList {
			infos = append(infos, map[string]any{
				"name":        t.Name,
				"description": t.Description,
				"read_only":   t.Policy.ReadOnly,
				"destructive": t.Policy.Destructive,
				// Whether the tool needs a run id in order to be deduplicated - which is the same as
				// asking whether it writes. It belongs in this response because the difference between
				// "the agent will not retry" and "the agent cannot retry safely" is invisible
				// anywhere else.
				"claims_idempotency": strings.HasPrefix(t.Name, "add_") ||
					strings.HasPrefix(t.Name, "save_"),
			})
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"total_tools": len(infos),
			"tools":       infos,
			"agent_role":  agent.AgentName(),
		})
	}
}

// interactionsHandler exposes the trajectory read path, 0017's views, over HTTP.
//
// It is here rather than left to psql because the point of vw_failed_interactions is that a human
// checking on the agent should not need database credentials to find out what it got wrong, and the
// reason it is one endpoint with a `view` parameter rather than four is that the four differ only in
// their WHERE clause - which is the view's job, not this handler's.
// trajectoryViews is what GET /api/interactions can read, one entry per published view: the columns to
// project and the order to return them in.
//
// Order is per view rather than one clause appended to all four, and the reason is the bug this
// comment is attached to. Every entry used to share `ORDER BY "timestamp" DESC`, and only two of the
// four views have a `timestamp`: vw_tool_calls's chronology is interaction_at (the run's) and its
// within-run position is step_number, and vw_tool_performance has no time column at all. So two of the
// four documented values of ?view= answered 502 with 42703 column "timestamp" does not exist - the
// endpoint had never been exercised for either, because the smoke test that finally found it was the
// first request anyone had made to them. cmd/server's TestTrajectoryViewsNameRealColumns is the check,
// and it reads pg_attribute rather than the SELECT text because that is the difference between a
// self-consistent test and one that can fail.
var trajectoryViews = map[string]struct {
	cols, order string
	byBot       bool
}{
	"recent": {
		cols: `interaction_id, "timestamp", run_id, bot_id, human_input, final_output,
		        error_message, duration_ms, step_count`,
		order: `ORDER BY "timestamp" DESC`,
		byBot: true,
	},
	"failed": {
		// No final_output: a run that failed has one only when the failure came after the answer,
		// and error_message is why anyone is reading this row.
		cols:  `interaction_id, "timestamp", run_id, bot_id, human_input, error_message, duration_ms`,
		order: `ORDER BY "timestamp" DESC`,
		byBot: true,
	},
	"tool_calls": {
		// observation, not tool_output - and observations_aligned and run_errored are here because
		// they are the honest caveats: the first says the pairing with actions_taken held for this
		// call, the second says the error belongs to the run and not necessarily to this step.
		cols: `interaction_id, run_id, bot_id, tool_name, step_number, tool_input, observation,
		       observation_type, observations_aligned, run_errored, run_duration_ms, interaction_at`,
		order: `ORDER BY interaction_at DESC, interaction_id, step_number`,
		byBot: true,
	},
	"performance": {
		// Busiest first: this is the listing that answers "what is the agent spending time on", and a
		// tool nobody calls is not the interesting row.
		cols:  `tool_name, call_count, run_count, mean_run_duration_ms, errored_run_count, errored_run_pct`,
		order: `ORDER BY call_count DESC`,
		// No bot_id column: the view groups by tool across every agent, because 0017 found that
		// grouping it by bot as well doubled the rows for a tool two agents share. So this listing
		// cannot be filtered by agent, and the endpoint says so rather than returning the unfiltered
		// answer and letting the caller believe the filter had applied.
		byBot: false,
	},
}

// viewName is the only place the mapping from a ?view= value to a relation is written; the test reads
// the columns out of trajectoryViews and the relation from here, so the two cannot disagree about what
// a view is called.
func viewName(which string) string {
	switch which {
	case "recent":
		return "vw_recent_interactions"
	case "failed":
		return "vw_failed_interactions"
	case "tool_calls":
		return "vw_tool_calls"
	case "performance":
		return "vw_tool_performance"
	}
	return ""
}

func interactionsHandler(q crm.Querier) http.HandlerFunc {
	allowed := map[string]string{}
	for name, v := range trajectoryViews {
		allowed[name] = "SELECT " + v.cols + " FROM " + viewName(name)
	}

	return func(w http.ResponseWriter, r *http.Request) {
		if q == nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{
				"error": "no database is connected, so there is no trajectory to read",
			})
			return
		}

		which := r.URL.Query().Get("view")
		if which == "" {
			which = "recent"
		}
		base, ok := allowed[which]
		if !ok {
			names := make([]string, 0, len(allowed))
			for k := range allowed {
				names = append(names, k)
			}
			writeJSON(w, http.StatusBadRequest, map[string]any{
				"error":   "unknown view",
				"detail":  which,
				"allowed": names,
			})
			return
		}

		limit := 20
		if v := r.URL.Query().Get("limit"); v != "" {
			n, err := strconv.Atoi(v)
			if err != nil || n < 1 || n > 500 {
				writeJSON(w, http.StatusBadRequest, map[string]any{
					"error":  "limit must be a whole number between 1 and 500",
					"detail": v,
				})
				return
			}
			limit = n
		}

		// The filter is on bot_id, not on tenant: the row security policy already confines every query
		// to this process's tenant, and repeating that condition here would state a rule the database
		// enforces in a place the database cannot see it.
		order := trajectoryViews[which].order
		sql := base + " " + order + " LIMIT $1"
		args := []any{limit}
		if bot := r.URL.Query().Get("bot_id"); bot != "" {
			if !trajectoryViews[which].byBot {
				writeJSON(w, http.StatusBadRequest, map[string]any{
					"error":  "bot_id cannot filter this view",
					"detail": viewName(which) + " has no bot_id column; the other three listings do",
				})
				return
			}
			sql = base + " WHERE bot_id = $2 " + order + " LIMIT $1"
			args = append(args, bot)
		}

		rows, err := q.Query(r.Context(), sql, args...)
		if err != nil {
			slog.Error("trajectory query failed", "view", which, "err", err)
			writeJSON(w, http.StatusBadGateway, map[string]any{
				"error": "the trajectory query failed", "detail": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"view": which, "count": len(rows), "rows": rows,
		})
	}
}

func healthHandler(am *agent.AgentManager, d *db.DB, list []tools.ToolDefinition, dbConfigured bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
		defer cancel()

		out := map[string]any{
			"status":             "healthy",
			"service":            agent.AgentName(),
			"version":            version,
			"llm_provider":       am.LLMProvider,
			"vllm_url":           am.VLLMURL,
			"model":              am.VLLMModel,
			"active_tools_count": len(list),
			"memory_driver":      memory.Driver(),
			"auth":               authMode(),
		}
		if memory.Driver() == memory.DriverFile {
			out["memory_dir"] = memory.Dir()
			out["memory_note"] = "file-backed: entries will not survive a container rebuild"
		}

		if d == nil {
			out["crm_tools"] = 0
			out["status"] = "degraded"
			if !dbConfigured {
				// A machine with no database in its environment at all: the file-backed memory
				// mode the operator chose, not a failure. It reports degraded for the same
				// reason as below - the agent cannot see a customer - but it holds 200, because
				// a healthcheck on this box is supposed to flap only for something that used to
				// work.
				out["database"] = "not configured"
				out["degraded_reason"] = "no database: the agent cannot see any customer data"
				writeJSON(w, http.StatusOK, out)
				return
			}
			// The environment configured a database and startup could not reach it, so this
			// process is serving without the tools it exists to serve with. That is not healthy,
			// and since 2026-11-04 it is not reported as healthy either: this was the mode a host
			// reboot left the agent in - up for hours, container green, CRM tools zero - because
			// the one ping that decided it lost the boot race by under a second.
			out["database"] = "configured but never connected"
			out["degraded_reason"] = "the database is configured but the agent could not connect at " +
				"startup: the CRM tools are not registered"
			writeJSON(w, http.StatusServiceUnavailable, out)
			return
		}

		dbStatus := map[string]any{"config": d.String()}
		if err := d.Ping(ctx); err != nil {
			dbStatus["state"] = "unreachable"
			dbStatus["error"] = err.Error()
			out["status"] = "degraded"
			out["degraded_reason"] = "the database is configured but not answering"
		} else {
			dbStatus["state"] = "connected"
			// The effective tenant, read from the connection rather than from the environment, because
			// the environment is a claim and this is the value the row security policies actually
			// compared against. A wrong AFPC_TENANT_ID still pings fine and answers zero rows.
			var (
				tenant  string
				missing []string
			)
			if err := d.Pool().QueryRow(ctx,
				"SELECT coalesce(afpc_current_tenant()::text, 'none')").Scan(&tenant); err == nil {
				dbStatus["tenant"] = tenant
			}
			if err := d.Pool().QueryRow(ctx, `
				SELECT coalesce(array_agg(t), ARRAY[]::text[]) FROM unnest(
					ARRAY['add_communication','save_memory','get_followup_customers']
				) AS t(name)
				 WHERE NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = t.name)`).
				Scan(&missing); err == nil && len(missing) > 0 {
				dbStatus["missing_functions"] = missing
				out["status"] = "degraded"
				out["degraded_reason"] = fmt.Sprintf(
					"the connected database lacks %s - it is not migrated to 0023",
					strings.Join(missing, ", "))
			}
		}
		out["database"] = dbStatus

		// The tool count the health check reports is counted from the registration, not from the
		// length of the list the process believes it built, because the two differ when a duplicate
		// name silently displaced a tool at startup - which is 4.4's fault wearing a different hat.
		crmCount := 0
		for _, t := range am.ToolList {
			if strings.HasPrefix(t.Name, "add_") || strings.HasPrefix(t.Name, "get_customer") ||
				strings.HasPrefix(t.Name, "get_entity") || strings.HasPrefix(t.Name, "get_followup") ||
				strings.HasPrefix(t.Name, "update_customer") || strings.HasPrefix(t.Name, "mark_") {
				crmCount++
			}
		}
		out["crm_tools"] = crmCount

		code := http.StatusOK
		if out["status"] != "healthy" {
			code = http.StatusServiceUnavailable
		}
		writeJSON(w, code, out)
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// threadOf is the caller's conversation key. A missing one is "default", which is the behaviour the
// UI was built against; the alternative, refusing the request, would make every stateless client
// break at once for no benefit.
func threadOf(req ChatRequest) string {
	if t := strings.TrimSpace(req.ThreadID); t != "" {
		return t
	}
	return "default"
}

func pickStatic() string {
	for _, c := range []string{"static", "/app/backend_go/static", "/app/static"} {
		if st, err := os.Stat(c); err == nil && st.IsDir() {
			return c
		}
	}
	return ""
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("response could not be encoded", "err", err)
	}
}

func envOr(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

func envYes(k string) bool {
	v := strings.ToLower(strings.TrimSpace(os.Getenv(k)))
	return v == "true" || v == "1" || v == "yes"
}

func envFalse(k string) bool {
	v := strings.ToLower(strings.TrimSpace(os.Getenv(k)))
	return v == "false" || v == "0" || v == "no"
}
