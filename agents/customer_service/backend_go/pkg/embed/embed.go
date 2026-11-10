// Package embed is the way this process asks a model to turn text into numbers.
//
// It exists as its own package for one reason, and it is not tidiness. The database declares
// `communications.embedding` as `vector(1536)` (0001), indexes it with `vector_cosine_ops` (0012),
// and 0035's door refuses to write anything that is not exactly 1536 long. The other side of that
// contract is an HTTP endpoint on a machine this repository does not own, and the two did not agree
// the first time they were tested against each other. Measured, on this server, an hour apart:
//
//	asked for 1536, model A answers 1536 floats, norm 1.000000     (the one to use)
//	asked for 1536, model B answers 400 "dimensions 1536 exceeds embedding length 1024"
//	asked for 1536, model B answers 200 OK with 1024 floats, no complaint
//
// The second and third lines are the same request to the same model. So the status code is not the
// answer, and the shape of the JSON is not the answer either: the only thing that can decide whether
// a vector is writable is its length, checked here, before anything is called. That is this package's
// entire value-add over a fetch, and Embed's test is a fake server that returns a short vector with a
// 200, because that response is not hypothetical.
//
// The second reason is the harder one. A vector is only comparable to the vectors around it if the
// same model produced them, and nothing in pgvector, in the catalog, or in a query plan can tell you
// otherwise - a column holding two models' vectors still searches, and the ranking it returns is
// plausible garbage. So Model is not a string this package forwards and forgets: it is the identity of
// the client, it travels with every write (embed_communications' p_model), and public.embedding_space
// is the table that remembers what was written.
package embed

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// SchemaDimensions is the width communications.embedding declares, in the database.
//
// It is a constant and not a knob. The number is stated in 0001's DDL, enforced by pgvector on every
// INSERT, restated in 0035's CHECK constraint and its door, and cross-checked against the catalog by
// verify.sh's B31. A fifth place to set it from the environment would be a place that can disagree
// with the other four, and the four that exist already needed a migration to notice the third.
const SchemaDimensions = 1536

// Environment. The two names with a fallback are the reason: one OpenAI-compatible server serving both
// the chat loop and the embedder needs one URL and one key, and a deployment that splits them can say
// so. firstSet is the resolution rule, and it is shared with pkg/agent's VLLM_API_KEY so there is one
// answer to "which key does this process send".
const (
	EnvModel      = "EMBEDDING_MODEL"
	EnvBaseURL    = "EMBEDDING_BASE_URL"
	EnvAPIKey     = "EMBEDDING_API_KEY"
	EnvDimensions = "EMBEDDING_DIMENSIONS"
	EnvBatchSize  = "EMBEDDING_BATCH_SIZE"
	EnvChatBase   = "VLLM_BASE_URL"
	EnvChatKey    = "VLLM_API_KEY"
	// EnvServerKey is the third name this resolves, and it exists because of a compose rule written
	// down in agents/customer_service/docker-compose.yml: ${LITELLM_API_KEY} inside an `environment:`
	// entry interpolates from the PROJECT .env and not from the env_file: list, so the obvious
	// translation line - `- VLLM_API_KEY=${LITELLM_API_KEY}` - expands to nothing and the agent starts
	// with no credential while the secret sits one file away. dev/.env is under env_file:, so the
	// value reaches the container environment whole and the only thing that has to know its name is
	// the process. Same reason pkg/db's resolvePassword reads two names for one role.
	EnvServerKey = "LITELLM_API_KEY"
)

const (
	defaultBatchSize    = 8
	maxBatchSize        = 64
	defaultRequestLimit = 60 * time.Second
)

// Client is one embedder, at one endpoint, with one identity.
type Client struct {
	BaseURL string
	Model   string
	APIKey  string
	// Dimensions is what this client asks for AND demands. It is a field rather than the constant at
	// the point of use so the check and the request are the same value; two reads of SchemaDimensions
	// would be one fewer failure mode, not more, but the field is also what a test can aim at.
	Dimensions int
	BatchSize  int
	HTTP       *http.Client
}

// FromEnv builds the client from the process environment, or returns nil when no embedder is
// configured.
//
// nil is a state and not a failure, and it is the state this deployment was in until the LiteLLM
// server arrived: the vector columns and their indexes exist, nothing writes them, and the honest
// description of that is a missing capability rather than a broken one. A caller that got a
// half-configured client out of here would discover it at the first tick, which is how 0011's
// retention policy and 0030's reconciliation both looked alive until somebody read a row.
func FromEnv() *Client {
	model := strings.TrimSpace(os.Getenv(EnvModel))
	if model == "" {
		slog.Info(EnvModel + " is unset: nothing will write communications.embedding, and " +
			"vw_embedding_status will report the corpus as EMPTY")
		return nil
	}

	base := strings.TrimSuffix(firstSet(EnvBaseURL, EnvChatBase), "/")
	if base == "" {
		base = "http://192.168.0.42:18300/v1" // the same fallback pkg/agent uses for the chat loop
	}

	batch := defaultBatchSize
	if v := strings.TrimSpace(os.Getenv(EnvBatchSize)); v != "" {
		if n, err := strconv.Atoi(v); err != nil || n <= 0 {
			slog.Warn(EnvBatchSize+" is not a positive number; keeping the default",
				"value", v, "default", defaultBatchSize)
		} else if n > maxBatchSize {
			slog.Warn(EnvBatchSize+" is above the cap; using the cap",
				"configured", n, "cap", maxBatchSize)
			batch = maxBatchSize
		} else {
			batch = n
		}
	}

	c := &Client{
		BaseURL:    base,
		Model:      model,
		APIKey:     firstSet(EnvAPIKey, EnvChatKey, EnvServerKey),
		Dimensions: SchemaDimensions,
		BatchSize:  batch,
		HTTP:       &http.Client{Timeout: defaultRequestLimit},
	}

	// The dimension is a fact about the schema, and an environment variable cannot change it without
	// a migration. What the key is allowed to do is fail loudly at startup rather than at the first
	// write, which is the only service it can usefully render.
	if v := strings.TrimSpace(os.Getenv(EnvDimensions)); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n != SchemaDimensions {
			slog.Error(EnvDimensions+" cannot be honoured: the column declares a fixed width, and "+
				"changing it is a migration, not a deployment setting",
				"configured", v, "schema_declares", SchemaDimensions,
				"where", "db/migrations/0001_baseline_canonical_port.sql")
		}
	}

	slog.Info("embedder configured", "model", c.Model, "base", c.BaseURL,
		"dimensions", c.Dimensions, "batch", c.BatchSize, "key", c.APIKey != "")
	return c
}

// firstSet returns the first non-empty value among the named variables. It is the same resolution
// rule pkg/db's resolvePassword applies to the database password, and for the same reason: the
// obvious alternative - documenting one canonical name and silently ignoring the other - is how a
// deployment ends up running with no credential while the file beside it has one.
func firstSet(names ...string) string {
	for _, n := range names {
		if v := strings.TrimSpace(os.Getenv(n)); v != "" {
			return v
		}
	}
	return ""
}

// Embed turns texts into vectors, preserving order, and refuses any answer that is not the width the
// schema declares.
//
// Order is worth stating because the HTTP contract allows a server to answer `data` in any order and
// pair each vector to its input with an `index` field. Sending them back in request order without
// reading that field would put the right vector on the wrong row: 1536 floats, all of them valid,
// attached to a conversation that did not say them. There is no check downstream that could see
// that - the column would accept it, the index would build, and the search would be confidently,
// permanently wrong.
func (c *Client) Embed(ctx context.Context, texts []string) ([][]float32, error) {
	if c == nil {
		return nil, fmt.Errorf("no embedder is configured (%s is unset)", EnvModel)
	}
	out := make([][]float32, 0, len(texts))
	for start := 0; start < len(texts); start += c.BatchSize {
		end := start + c.BatchSize
		if end > len(texts) {
			end = len(texts)
		}
		// An empty document is not embeddable and is not worth a request: the model answers a valid
		// unit vector for "", and every such vector is close to every other, which is how a corpus
		// fills with rows that all match each other. The caller is expected to have filtered these;
		// vw_unembedded_communications publishes nothing_to_embed for exactly that reason, and the
		// keeper refuses them rather than sending them. What this line protects is the case that
		// slips through: a batch of nothing, which the server would otherwise answer with one
		// vector for zero texts and decode into the wrong row.
		if batchHasNoContent(texts[start:end]) {
			continue
		}
		vecs, err := c.embedBatch(ctx, texts[start:end])
		if err != nil {
			return nil, err
		}
		out = append(out, vecs...)
	}
	return out, nil
}

func batchHasNoContent(texts []string) bool {
	for _, t := range texts {
		if strings.TrimSpace(t) != "" {
			return false
		}
	}
	return true
}

// embedBatch is one request. It returns exactly len(texts) vectors or an error; there is no
// partially-successful shape of this call, because a caller that wrote half of a batch would have to
// be idempotent about the half it did write, and the keeper is already going to retry the whole thing
// on the next tick.
func (c *Client) embedBatch(ctx context.Context, texts []string) ([][]float32, error) {
	payload, err := json.Marshal(map[string]any{
		"model":      c.Model,
		"input":      texts,
		"dimensions": c.Dimensions,
	})
	if err != nil {
		return nil, fmt.Errorf("marshal the embedding request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.BaseURL+"/embeddings", bytes.NewReader(payload))
	if err != nil {
		return nil, fmt.Errorf("build the embedding request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if c.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.APIKey)
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("reach the embedder at %s: %w", c.BaseURL, err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return nil, fmt.Errorf("read the embedder's answer: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("the embedder answered %d: %s", resp.StatusCode, oneLine(body))
	}

	var decoded struct {
		Error *struct {
			Message string `json:"message"`
		} `json:"error"`
		Data []struct {
			Index     int       `json:"index"`
			Embedding []float32 `json:"embedding"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &decoded); err != nil {
		return nil, fmt.Errorf("decode the embedder's JSON: %w", err)
	}
	// An in-band error with a 200 is what a proxy does when it decided the upstream failure was not
	// worth a status code. LiteLLM is that proxy. Counting the vectors instead of reading this field
	// would surface the same incident as "3 vectors for 8 texts", which is a worse sentence.
	if decoded.Error != nil && strings.TrimSpace(decoded.Error.Message) != "" {
		return nil, fmt.Errorf("the embedder answered 200 with an error: %s",
			oneLine([]byte(decoded.Error.Message)))
	}
	if len(decoded.Data) != len(texts) {
		return nil, fmt.Errorf("the embedder answered %d vectors for %d texts",
			len(decoded.Data), len(texts))
	}

	out := make([][]float32, len(texts))
	seen := make([]bool, len(texts))
	for _, d := range decoded.Data {
		if d.Index < 0 || d.Index >= len(texts) {
			return nil, fmt.Errorf("the embedder answered index %d for a batch of %d",
				d.Index, len(texts))
		}
		if len(d.Embedding) != c.Dimensions {
			// The message names the model, because the finding is never "the number was wrong"; it is
			// "EMBEDDING_MODEL points at something that does not do 1536".
			return nil, fmt.Errorf("%s answered %d dimensions and the schema declares %d: refusing "+
				"to write, because a vector of this width is not comparable with the ones already in "+
				"the column (check %s against public.embedding_space, which names what filled it)",
				c.Model, len(d.Embedding), c.Dimensions, EnvModel)
		}
		if seen[d.Index] {
			return nil, fmt.Errorf("the embedder answered index %d twice", d.Index)
		}
		seen[d.Index], out[d.Index] = true, d.Embedding
	}
	for i, ok := range seen {
		if !ok {
			return nil, fmt.Errorf("the embedder never answered for input %d of %d", i, len(texts))
		}
	}
	return out, nil
}

// Describe is the configuration in one line, for the health endpoint and the startup log. The key is
// never included, and whether one is set is: that is the fact that explains a 401, and it is the same
// distinction API_KEYS makes at /api/health.
func (c *Client) Describe() string {
	if c == nil {
		return "not configured"
	}
	authed := "no key"
	if c.APIKey != "" {
		authed = "key set"
	}
	return fmt.Sprintf("%s at %s, %d dimensions, %s", c.Model, c.BaseURL, c.Dimensions, authed)
}

func oneLine(b []byte) string {
	return strings.Join(strings.Fields(strings.ReplaceAll(string(b), "\n", " ")), " ")
}
