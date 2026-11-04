package tools

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"jada-backend/pkg/memory"

	"github.com/PuerkitoBio/goquery"
)

type ToolPolicy struct {
	ReadOnly         bool `json:"read_only"`
	Destructive      bool `json:"destructive"`
	RequiresApproval bool `json:"requires_approval"`
}

// ToolDefinition is one callable tool.
//
// ExecuteContext is the newer of the two entry points and is the one a tool that touches the
// database implements: it needs a context to carry a deadline and a cancellation into a query, and
// the run identity that makes an idempotency key. Execute remains for tools with no such need, and
// exactly one of the two is consulted per call - see Resolve.
//
// A tool with neither is registered but broken, and Resolve reports that rather than letting the
// agent discover it as a nil dereference in the middle of a conversation.
type ToolDefinition struct {
	Name           string                 `json:"name"`
	Description    string                 `json:"description"`
	Parameters     map[string]interface{} `json:"parameters"`
	Policy         ToolPolicy             `json:"policy,omitempty"`
	Execute        func(args map[string]interface{}) (string, error)
	ExecuteContext func(ctx context.Context, args map[string]interface{}) (string, error)
}

// Resolve runs one tool, preferring the context-aware entry point.
func (t ToolDefinition) Resolve(ctx context.Context, args map[string]any) (string, error) {
	if t.ExecuteContext != nil {
		return t.ExecuteContext(ctx, args)
	}
	if t.Execute != nil {
		return t.Execute(args)
	}
	return "", fmt.Errorf("tool %q has no implementation registered", t.Name)
}

func isPrivateIP(ip net.IP) bool {
	if ip == nil {
		return true
	}
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified() {
		return true
	}
	ip4 := ip.To4()
	if ip4 != nil {
		switch {
		case ip4[0] == 10:
			return true
		case ip4[0] == 172 && ip4[1] >= 16 && ip4[1] <= 31:
			return true
		case ip4[0] == 192 && ip4[1] == 168:
			return true
		case ip4[0] == 169 && ip4[1] == 254:
			return true
		}
	}
	return false
}

func ValidateScrapeURL(urlStr string) error {
	allowInternal := strings.ToLower(os.Getenv("ALLOW_INTERNAL_SCRAPE"))
	if allowInternal == "true" || allowInternal == "1" || allowInternal == "yes" {
		return nil
	}

	parsedURL, err := url.Parse(urlStr)
	if err != nil {
		return fmt.Errorf("invalid URL format: %w", err)
	}

	scheme := strings.ToLower(parsedURL.Scheme)
	if scheme != "http" && scheme != "https" {
		return fmt.Errorf("forbidden URL scheme '%s' (only http and https allowed)", scheme)
	}

	hostname := parsedURL.Hostname()
	if hostname == "" {
		return fmt.Errorf("invalid host in URL")
	}

	ips, err := net.LookupIP(hostname)
	if err != nil {
		return fmt.Errorf("could not resolve host %s: %w", hostname, err)
	}

	for _, ip := range ips {
		if isPrivateIP(ip) {
			return fmt.Errorf("access to restricted or internal IP %s (%s) is forbidden", ip.String(), hostname)
		}
	}

	return nil
}

func GetCurrentTime() (string, error) {
	nowUTC := time.Now().UTC()
	nowLocal := time.Now()
	tzName := os.Getenv("TZ")
	if tzName == "" {
		tzName = "America/Chicago"
	}

	// The weekday is the reason this tool exists, and it was not in its output. A model asked to set a
	// follow-up for "next Tuesday" has to derive the day of week from a numeric date, which is calendar
	// arithmetic rather than reading, and a live turn did exactly that: it stored 2026-11-09 - a Monday -
	// while telling the customer the call was moved to Tuesday. The prose and the row disagreed, and only
	// the row is what vw_pending_followups surfaces on the due date. Naming the day turns the reasoning
	// into one subtraction.
	//
	// The ISO week number is printed for the other phrasing that reaches this tool, "later this week" and
	// "next week", which are week questions rather than day questions.
	_, isoWeek := nowLocal.ISOWeek()
	return fmt.Sprintf(
		"Current UTC time (for UTC ISO parameters): %s, a %s\n"+
			"Current Local time (%s): %s, a %s\n"+
			"Local ISO week number: %d (weeks start on Monday)",
		nowUTC.Format("2006-01-02T15:04:05Z"), nowUTC.Weekday(),
		tzName,
		nowLocal.Format("2006-01-02 15:04:05"), nowLocal.Weekday(),
		isoWeek,
	), nil
}

type TavilySearchRequest struct {
	Query       string `json:"query"`
	SearchDepth string `json:"search_depth"`
	MaxResults  int    `json:"max_results"`
}

type TavilySearchResult struct {
	Title   string `json:"title"`
	Content string `json:"content"`
	URL     string `json:"url"`
}

type TavilyResponse struct {
	Results []TavilySearchResult `json:"results"`
}

func SearchWeb(query string) (string, error) {
	apiKey := os.Getenv("TAVILY_API_KEY")
	if apiKey == "" {
		return "Tavily API key not configured. Please set TAVILY_API_KEY environment variable.", nil
	}

	reqBody := TavilySearchRequest{
		Query:       query,
		SearchDepth: "basic",
		MaxResults:  5,
	}

	jsonBytes, err := json.Marshal(reqBody)
	if err != nil {
		return "", fmt.Errorf("failed to marshal tavily request: %w", err)
	}

	req, err := http.NewRequest("POST", "https://api.tavily.com/search", bytes.NewBuffer(jsonBytes))
	if err != nil {
		return "", fmt.Errorf("failed to create tavily request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", apiKey))

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Sprintf("Search failed: %v", err), nil
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Sprintf("Search failed with status %d: %s", resp.StatusCode, string(body)), nil
	}

	var tavilyResp TavilyResponse
	if err := json.NewDecoder(resp.Body).Decode(&tavilyResp); err != nil {
		return "", fmt.Errorf("failed to decode tavily response: %w", err)
	}

	if len(tavilyResp.Results) == 0 {
		return "No search results found.", nil
	}

	var formatted []string
	for i, res := range tavilyResp.Results {
		title := res.Title
		if title == "" {
			title = "No title"
		}
		snippet := res.Content
		if snippet == "" {
			snippet = "No description"
		}
		url := res.URL
		if url == "" {
			url = "No URL"
		}

		formatted = append(formatted, fmt.Sprintf("%d. **%s**\n   %s\n   URL: %s", i+1, title, snippet, url))
	}

	return strings.Join(formatted, "\n\n"), nil
}

func ScrapeURL(urlStr string) (string, error) {
	if err := ValidateScrapeURL(urlStr); err != nil {
		return fmt.Sprintf("Scraping blocked by security policy: %v", err), nil
	}

	req, err := http.NewRequest("GET", urlStr, nil)
	if err != nil {
		return fmt.Sprintf("Failed to create request: %v", err), nil
	}

	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Sprintf("Failed to fetch URL: %v", err), nil
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Sprintf("Scraping failed with status: %d", resp.StatusCode), nil
	}

	maxBytes := int64(2097152) // Default 2MB limit
	if envMax := os.Getenv("MAX_SCRAPE_BYTES"); envMax != "" {
		if parsed, err := strconv.ParseInt(envMax, 10, 64); err == nil && parsed > 0 {
			maxBytes = parsed
		}
	}

	limitedReader := io.LimitReader(resp.Body, maxBytes)
	doc, err := goquery.NewDocumentFromReader(limitedReader)
	if err != nil {
		return fmt.Sprintf("Scraping failed: %v", err), nil
	}

	doc.Find("script, style, noscript").Each(func(i int, s *goquery.Selection) {
		s.Remove()
	})

	text := doc.Text()

	lines := strings.Split(text, "\n")
	var cleanedLines []string
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed != "" {
			cleanedLines = append(cleanedLines, trimmed)
		}
	}

	cleanedText := strings.Join(cleanedLines, "\n")

	if len(cleanedText) > 5000 {
		cleanedText = cleanedText[:5000] + "\n\n... (content truncated)"
	}

	return fmt.Sprintf("Content from %s:\n\n%s", urlStr, cleanedText), nil
}

func GetLocalTools() []ToolDefinition {
	return []ToolDefinition{
		{
			Name: "current_time",
			Description: "Get the current date and time in UTC (for ISO database parameters) and in the " +
				"server's local timezone, each with its weekday named, plus the local ISO week number. " +
				"Call it before resolving any relative date the caller gives you - \"next Tuesday\", " +
				"\"end of this week\", \"a fortnight\" - because the weekday is a fact about today that a " +
				"date alone does not carry, and an off-by-one in a follow-up date is stored in a row that " +
				"someone will act on. When the phrasing is ambiguous (\"next Tuesday\" from a Monday could " +
				"be in six days or thirteen), ask; do not pick silently.",
			Parameters: map[string]interface{}{
				"type":       "object",
				"properties": map[string]interface{}{},
			},
			Policy: ToolPolicy{
				ReadOnly:         true,
				Destructive:      false,
				RequiresApproval: false,
			},
			Execute: func(args map[string]interface{}) (string, error) {
				return GetCurrentTime()
			},
		},
		{
			Name:        "search_web",
			Description: "Search the web using Tavily API.",
			Parameters: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"query": map[string]interface{}{
						"type":        "string",
						"description": "The search query string.",
					},
				},
				"required": []string{"query"},
			},
			Policy: ToolPolicy{
				ReadOnly:         true,
				Destructive:      false,
				RequiresApproval: false,
			},
			Execute: func(args map[string]interface{}) (string, error) {
				q, _ := args["query"].(string)
				return SearchWeb(q)
			},
		},
		{
			Name:        "scrape_url",
			Description: "Scrape content from a web page URL.",
			Parameters: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"url": map[string]interface{}{
						"type":        "string",
						"description": "The URL to scrape.",
					},
				},
				"required": []string{"url"},
			},
			Policy: ToolPolicy{
				ReadOnly:         true,
				Destructive:      false,
				RequiresApproval: false,
			},
			Execute: func(args map[string]interface{}) (string, error) {
				u, _ := args["url"].(string)
				return ScrapeURL(u)
			},
		},
		{
			Name: "save_memory_tool",
			Description: "Remember something for later: one fact under one key. Writing a key that " +
				"already exists appends a dated entry rather than replacing anything, so the history " +
				"of what was learned is kept. Keep keys short, lowercase and stable - a key is how a " +
				"fact is found again, and re-wording one starts a new history.",
			Parameters: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"key": map[string]interface{}{
						"type": "string",
						"description": "A short, stable identifier, lowercase with dots, hyphens, " +
							"underscores or single spaces.",
					},
					"content": map[string]interface{}{
						"type":        "string",
						"description": "The fact to remember, in one or two sentences.",
					},
				},
				"required": []string{"key", "content"},
			},
			Policy: ToolPolicy{
				ReadOnly:         false,
				Destructive:      false,
				RequiresApproval: false,
			},
			// ExecuteContext, not Execute: save_memory takes an idempotency claim, and the claim
			// is derived from the run, which only the context knows. A memory tool registered
			// without one would write duplicates on every retry and report success doing it.
			ExecuteContext: func(ctx context.Context, args map[string]interface{}) (string, error) {
				key, _ := args["key"].(string)
				content, _ := args["content"].(string)
				return memory.Save(ctx, key, content), nil
			},
		},
		{
			Name: "get_memory_tool",
			Description: "Everything remembered under one key, newest first. Case and surrounding " +
				"whitespace do not matter, and a run of spaces is one space, so 'Customer  Prefs' and " +
				"'customer prefs' find the same history. An underscore is not whitespace: " +
				"'customer_prefs' is a different memory, deliberately.",
			Parameters: map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"key": map[string]interface{}{
						"type":        "string",
						"description": "The memory key to look up.",
					},
					"limit": map[string]interface{}{
						"type":        "integer",
						"description": "How many entries to return, newest first. Default 10, maximum 200.",
					},
				},
				"required": []string{"key"},
			},
			Policy: ToolPolicy{
				ReadOnly:         true,
				Destructive:      false,
				RequiresApproval: false,
			},
			ExecuteContext: func(ctx context.Context, args map[string]interface{}) (string, error) {
				key, _ := args["key"].(string)
				limit := 10
				if v, ok := args["limit"].(float64); ok {
					limit = int(v)
				}
				return memory.Read(ctx, key, limit), nil
			},
		},
		{
			Name: "list_memories_tool",
			Description: "Every memory key this tenant has, with how many entries each holds and " +
				"when the last was written. The counts are what say whether something was learned " +
				"repeatedly or corrected once.",
			Parameters: map[string]interface{}{
				"type":       "object",
				"properties": map[string]interface{}{},
			},
			Policy: ToolPolicy{
				ReadOnly:         true,
				Destructive:      false,
				RequiresApproval: false,
			},
			ExecuteContext: func(ctx context.Context, args map[string]interface{}) (string, error) {
				return memory.List(ctx), nil
			},
		},
	}
}
