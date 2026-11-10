package embed

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The tests in this file exist to hold one measured fact in place: an embedding server can answer a
// request for 1536 dimensions with something else, and it can do that with a status code that says
// everything worked. pkg/embed's whole reason to be a package is that refusal, so each test below is
// a shape of "the answer was not what was asked for", and none of them is hypothetical.

func dims(n int) []float32 {
	v := make([]float32, n)
	for i := range v {
		v[i] = 0.001
	}
	return v
}

// serve is a fake embedder. It answers with whatever the test needs to have gone wrong, including
// nothing at all.
func serve(t *testing.T, handler http.HandlerFunc) *Client {
	t.Helper()
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	return &Client{
		BaseURL:    srv.URL,
		Model:      "fake/model",
		APIKey:     "sekrit",
		Dimensions: SchemaDimensions,
		BatchSize:  defaultBatchSize,
		HTTP:       srv.Client(),
	}
}

func TestEmbedAcceptsTheDeclaredWidth(t *testing.T) {
	c := serve(t, func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "Bearer sekrit" {
			t.Errorf("the key was not sent: %q - LiteLLM answers 401 to a request with no credential, "+
				"and the failure looks like a model server that is down", got)
		}
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		if body["dimensions"].(float64) != SchemaDimensions {
			t.Errorf("dimensions was %v; the request must ask for the width the column declares",
				body["dimensions"])
		}
		inputs := body["input"].([]any)
		data := make([]map[string]any, len(inputs))
		for i := range inputs {
			data[i] = map[string]any{"index": i, "embedding": dims(SchemaDimensions)}
		}
		json.NewEncoder(w).Encode(map[string]any{"data": data})
	})

	got, err := c.Embed(context.Background(), []string{"one", "two"})
	if err != nil {
		t.Fatalf("a correct answer produced an error: %v", err)
	}
	if len(got) != 2 || len(got[0]) != SchemaDimensions {
		t.Fatalf("got %d vectors of %d", len(got), len(got[0]))
	}
}

// TestEmbedRefusesAShortVectorWithAStatus200 is the finding. Measured on this server: a model whose
// native width is below what was asked for answered 200 OK with 1024 floats and no complaint. An hour
// later the same call answered 400. Either is survivable; writing the 1024 would not be, because
// pgvector would reject it while a 1536-from-the-wrong-model would not be rejected by anything.
func TestEmbedRefusesAShortVectorWithAStatus200(t *testing.T) {
	c := serve(t, func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"data": []any{map[string]any{"index": 0, "embedding": dims(1024)}},
		})
	})
	_, err := c.Embed(context.Background(), []string{"one"})
	if err == nil {
		t.Fatal("a 200 carrying the wrong width was accepted, which is the defect this package exists for")
	}
	for _, want := range []string{"1024", "1536", "fake/model"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the error names the failure but not %q: %v", want, err)
		}
	}
}

// A server is allowed to answer data in any order and pair it by index. Sending them back in request
// order without reading the field would attach a correct vector to the wrong row, and nothing
// downstream could ever see that: every value involved is 1536 numbers long.
func TestEmbedFollowsTheIndexAndNotTheAnswerOrder(t *testing.T) {
	c := serve(t, func(w http.ResponseWriter, r *http.Request) {
		// Deliberately reversed, and with distinct values so the pairing is checkable.
		json.NewEncoder(w).Encode(map[string]any{
			"data": []any{
				map[string]any{"index": 2, "embedding": []float32{3, 3, 3, 3}},
				map[string]any{"index": 0, "embedding": []float32{1, 1, 1, 1}},
				map[string]any{"index": 1, "embedding": []float32{2, 2, 2, 2}},
			},
		})
	})
	c.Dimensions = 4
	got, err := c.Embed(context.Background(), []string{"a", "b", "c"})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	for i, want := range []float32{1, 2, 3} {
		if got[i][0] != want {
			t.Errorf("vector %d is %v; the index was ignored", i, got[i][0])
		}
	}
}

func TestEmbedRefusesAnAnswerThatSkipsOrDuplicatesAnIndex(t *testing.T) {
	cases := map[string]string{
		"missing":       `{"data":[{"index":0,"embedding":[1,1,1,1]}]}`,
		"doubled":       `{"data":[{"index":0,"embedding":[1,1,1,1]},{"index":0,"embedding":[2,2,2,2]}]}`,
		"too_many":      `{"data":[{"index":0,"embedding":[1,1,1,1]},{"index":1,"embedding":[1,1,1,1]},{"index":2,"embedding":[1,1,1,1]}]}`,
		"oob":           `{"data":[{"index":7,"embedding":[1,1,1,1]},{"index":1,"embedding":[1,1,1,1]}]}`,
		"in_band_error": `{"error":{"message":"upstream refused"},"data":[]}`,
	}
	for name, payload := range cases {
		t.Run(name, func(t *testing.T) {
			c := serve(t, func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				fmt.Fprint(w, payload)
			})
			c.Dimensions = 4
			if _, err := c.Embed(context.Background(), []string{"a", "b"}); err == nil {
				t.Fatal("a malformed answer was accepted without an error")
			}
		})
	}
}

func TestEmbedReportsAServerError(t *testing.T) {
	c := serve(t, func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "no such model", http.StatusNotFound)
	})
	_, err := c.Embed(context.Background(), []string{"a"})
	if err == nil || !strings.Contains(err.Error(), "404") {
		t.Fatalf("the status code did not reach the caller: %v", err)
	}
}

// One call is chunked into requests of BatchSize. The keeper would otherwise put the whole backlog in
// a single POST, and the first tick on a year of communications would be one request with ten
// thousand inputs in it.
func TestEmbedChunksByBatchSize(t *testing.T) {
	var calls, texts int
	c := serve(t, func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		calls++
		n := len(body["input"].([]any))
		texts += n
		data := make([]map[string]any, n)
		for i := range n {
			data[i] = map[string]any{"index": i, "embedding": dims(SchemaDimensions)}
		}
		json.NewEncoder(w).Encode(map[string]any{"data": data})
	})
	c.BatchSize = 3
	in := make([]string, 8)
	for i := range in {
		in[i] = fmt.Sprintf("text %d", i)
	}
	got, err := c.Embed(context.Background(), in)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if calls != 3 || texts != 8 || len(got) != 8 {
		t.Fatalf("8 texts at a batch of 3: %d calls, %d inputs, %d vectors", calls, texts, len(got))
	}
}

// A batch of nothing must not reach the server: an empty string embeds to a valid unit vector, and a
// response with one vector in it for zero inputs would be decoded onto a row that had nothing to say.
func TestEmbedSendsNothingForAnAllEmptyBatch(t *testing.T) {
	c := serve(t, func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("an empty batch was sent to the server")
	})
	c.BatchSize = 1
	got, err := c.Embed(context.Background(), []string{"", "   ", "\n"})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("%d vectors for nothing", len(got))
	}
}

func TestFromEnvIsOffWhenNoModelIsConfigured(t *testing.T) {
	t.Setenv(EnvModel, "")
	t.Setenv(EnvBaseURL, "")
	if c := FromEnv(); c != nil {
		t.Fatal("a deployment with no embedder built a client anyway")
	}
}

func TestFromEnvTakesTheKeyAndURLFromTheChatEndpointWhenNotSaidTwice(t *testing.T) {
	t.Setenv(EnvModel, "qwen3-embedding:latest")
	t.Setenv(EnvChatBase, "http://192.168.0.53:4000/v1")
	t.Setenv(EnvChatKey, "sk-from-the-chat-loop")
	t.Setenv(EnvAPIKey, "")
	t.Setenv(EnvBaseURL, "")

	c := FromEnv()
	if c == nil {
		t.Fatal("a configured model built no client")
	}
	if c.APIKey != "sk-from-the-chat-loop" || c.BaseURL != "http://192.168.0.53:4000/v1" {
		t.Fatalf("fallbacks did not resolve: %+v", c)
	}
	if c.Dimensions != SchemaDimensions {
		t.Errorf("dimensions came from somewhere other than the schema: %d", c.Dimensions)
	}
}

func TestFromEnvLetsASecondEndpointHaveItsOwnKey(t *testing.T) {
	t.Setenv(EnvModel, "m")
	t.Setenv(EnvChatKey, "chat-key")
	t.Setenv(EnvAPIKey, "embed-key")
	t.Setenv(EnvBaseURL, "http://elsewhere/v1")
	if got := FromEnv().APIKey; got != "embed-key" {
		t.Fatalf("the embedding-specific key lost to the chat one: %q", got)
	}
}

// EMBEDDING_DIMENSIONS is not a knob. It is allowed to be wrong, and only so that a deployment that set
// it by mistake finds out at startup instead of at the first write.
func TestFromEnvRefusesToBeToldTheColumnIsAWider(t *testing.T) {
	t.Setenv(EnvModel, "m")
	t.Setenv(EnvDimensions, "3072")
	if got := FromEnv().Dimensions; got != SchemaDimensions {
		t.Fatalf("an environment variable changed the width the schema declares: %d", got)
	}
}

func TestNilClientIsAnErrorAndNotAPanic(t *testing.T) {
	var c *Client
	if _, err := c.Embed(context.Background(), []string{"a"}); err == nil {
		t.Fatal("a nil client answered")
	}
	if d := c.Describe(); d == "" {
		t.Fatal("Describe must say what is not configured")
	}
}
