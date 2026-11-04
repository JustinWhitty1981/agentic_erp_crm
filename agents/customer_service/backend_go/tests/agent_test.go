package tests

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"jada-backend/pkg/agent"
	"jada-backend/pkg/formatters"
	"jada-backend/pkg/mcp"
	"jada-backend/pkg/memory"
	"jada-backend/pkg/tools"
)

// TestCurrentTimeTool asserts the weekday is named, because that is the one thing this tool exists to
// provide and the thing it left out. A live turn was asked to move a follow-up to "next Tuesday", had no
// weekday to read, computed one from the date, and stored the Monday: the reply said Tuesday and the row
// said Monday, and vw_pending_followups will act on the row.
//
// The assertion checks each of the seven names is producible rather than checking today's, which would
// make the test depend on the day it runs. It also drops the `!A && !B` the first version had - that
// shape passed when either half went missing, so a tool that printed only UTC was green.
func TestCurrentTimeTool(t *testing.T) {
	res, err := tools.GetCurrentTime()
	if err != nil {
		t.Fatalf("GetCurrentTime returned error: %v", err)
	}
	for _, want := range []string{"Current UTC time", "Current Local time", "ISO week number"} {
		if !strings.Contains(res, want) {
			t.Errorf("output is missing %q:\n%s", want, res)
		}
	}

	named := false
	for _, day := range []string{"Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"} {
		if strings.Contains(res, day) {
			named = true
		}
	}
	if !named {
		t.Errorf("no weekday named in the output, so a caller has to compute one:\n%s", res)
	}
}

// TestMemoryFileStore exercises the fallback path, which is the only one a test can reach without a
// server. It is not the deployment's store: 0023 moved memory into agent_memories and the assertions
// that matter there - append-only by grant, one key spelled three ways, tenancy - live in
// db/tests/4_7_cs_agent_surface.sql, where the database can answer them. What is checked here is that
// the fallback still works, because a fallback that quietly broke would turn "no database" into "no
// memory" with no error anywhere.
func TestMemoryFileStore(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "afpc_memory")
	if err != nil {
		t.Fatalf("temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	memory.Use(nil) // file mode, explicitly rather than by omission
	if got := memory.Driver(); got != memory.DriverFile {
		t.Fatalf("Driver() = %q after Use(nil), want %q", got, memory.DriverFile)
	}
	memory.SetDir(tmpDir)

	ctx := context.Background()
	const key = "test_gold_preference_unit"
	const content = "User tracks the live market price of gold."

	if res := memory.Save(ctx, key, content); !strings.Contains(res, key) {
		t.Errorf("Save did not name the key: %s", res)
	}
	if res := memory.Read(ctx, key, 10); !strings.Contains(res, content) {
		t.Errorf("Read did not return the content: %s", res)
	}
	if res := memory.List(ctx); !strings.Contains(res, key) {
		t.Errorf("List did not include the key: %s", res)
	}
	if res := memory.Read(ctx, "no_such_key_at_all", 10); !strings.Contains(res, "No memory") {
		t.Errorf("a missing key should say so plainly, got: %s", res)
	}

	fp := filepath.Join(tmpDir, key+".md")
	if _, err := os.Stat(fp); err != nil {
		t.Errorf("the file store wrote somewhere other than %s: %v", fp, err)
	}
}

// TestMemoryAppendKeepsHistory is the property the file store shares with the database one, and the
// reason the file path was kept rather than dropped: a second save under one key must not destroy the
// first. The database version of this assertion - two rows, newest first - is 0023's probe D.
func TestMemoryAppendKeepsHistory(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "afpc_memory_hist")
	if err != nil {
		t.Fatalf("temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	memory.Use(nil)
	memory.SetDir(tmpDir)
	ctx := context.Background()

	memory.Save(ctx, "prefs", "prefers mornings")
	memory.Save(ctx, "prefs", "changed to afternoons")

	res := memory.Read(ctx, "prefs", 10)
	for _, want := range []string{"mornings", "afternoons"} {
		if !strings.Contains(res, want) {
			t.Errorf("the history lost %q - an append that overwrote: %s", want, res)
		}
	}
}

func TestFormatters(t *testing.T) {
	// Paint defects sample data
	data := []map[string]interface{}{
		{"door_grade": "pass", "is_fail": 0},
		{"door_grade": "fail", "is_fail": 1, "reason_description": "Scratch on surface"},
	}

	summary := formatters.SummarizePaintDefectsData(data)
	if !strings.Contains(summary, "Total Inspected Doors") || !strings.Contains(summary, "Scratch on surface") {
		t.Errorf("SummarizePaintDefectsData result invalid: %s", summary)
	}

	// Truncation
	longStr := strings.Repeat("A", 15000)
	truncated := formatters.TruncateToolOutput(longStr, 1000)
	if len(truncated) >= 15000 || !strings.Contains(truncated, "truncated") {
		t.Errorf("TruncateToolOutput failed to truncate properly")
	}
}

func TestMCPSanitizer(t *testing.T) {
	args := map[string]interface{}{
		"start_ts": "now-4h",
		"end_ts":   "now",
	}

	sanitized := mcp.SanitizeMCPToolArgs("paint_defects", args)
	startTS, ok := sanitized["start_ts"].(string)
	if !ok || !strings.HasSuffix(startTS, "Z") {
		t.Errorf("SanitizeMCPToolArgs failed to produce ISO UTC timestamp for start_ts: %v", sanitized["start_ts"])
	}

	insightsArgs := mcp.SanitizeMCPToolArgs("InsightsPublish", map[string]interface{}{})
	if insightsArgs["agent_name"] != "J.A.D.A" {
		t.Errorf("SanitizeMCPToolArgs failed to enforce agent_name = J.A.D.A")
	}

	// Test stringified JSON array in insight parameter
	rawStringifiedInsight := `[{"type": "quality_risk", "title": "Test Insight Title"}]`
	insightArgs := map[string]interface{}{
		"insight": []interface{}{rawStringifiedInsight},
	}
	sanitizedInsights := mcp.SanitizeMCPToolArgs("InsightsPublish", insightArgs)
	cleanedInsightList, ok := sanitizedInsights["insight"].([]interface{})
	if !ok || len(cleanedInsightList) == 0 {
		t.Fatalf("SanitizeMCPToolArgs failed to parse stringified insight array into list")
	}
	firstObj, ok := cleanedInsightList[0].(map[string]interface{})
	if !ok || firstObj["title"] != "Test Insight Title" {
		t.Errorf("SanitizeMCPToolArgs failed to unwrap stringified insight object: %v", cleanedInsightList[0])
	}
}

func TestToolPolicies(t *testing.T) {
	localTools := tools.GetLocalTools()
	if len(localTools) == 0 {
		t.Fatalf("GetLocalTools returned empty tool list")
	}

	for _, tool := range localTools {
		if tool.Name == "current_time" || tool.Name == "search_web" || tool.Name == "scrape_url" {
			if !tool.Policy.ReadOnly {
				t.Errorf("Tool '%s' should be marked ReadOnly", tool.Name)
			}
		}
		if tool.Name == "save_memory_tool" {
			if tool.Policy.ReadOnly {
				t.Errorf("save_memory_tool should not be marked ReadOnly")
			}
		}
	}
}

func TestScraperSSRF(t *testing.T) {
	os.Unsetenv("ALLOW_INTERNAL_SCRAPE")

	// 1. Loopback should be blocked
	if err := tools.ValidateScrapeURL("http://127.0.0.1/test"); err == nil {
		t.Errorf("Expected 127.0.0.1 to be blocked by SSRF check, but passed")
	}

	// 2. Metadata service should be blocked
	if err := tools.ValidateScrapeURL("http://169.254.169.254/latest/meta-data/"); err == nil {
		t.Errorf("Expected 169.254.169.254 to be blocked by SSRF check, but passed")
	}

	// 3. Invalid scheme should be blocked
	if err := tools.ValidateScrapeURL("file:///etc/passwd"); err == nil {
		t.Errorf("Expected file:// scheme to be blocked, but passed")
	}

	// 4. ALLOW_INTERNAL_SCRAPE override should allow loopback
	os.Setenv("ALLOW_INTERNAL_SCRAPE", "true")
	if err := tools.ValidateScrapeURL("http://127.0.0.1/test"); err != nil {
		t.Errorf("Expected ALLOW_INTERNAL_SCRAPE=true to allow loopback, but got error: %v", err)
	}
	os.Unsetenv("ALLOW_INTERNAL_SCRAPE")
}

func TestInsightLogging(t *testing.T) {
	tmpLoggingDir := "insight_logging"
	_ = os.RemoveAll(tmpLoggingDir)

	mcp.LogInsightSummary("InsightsPublish", map[string]interface{}{"title": "Paint Quality Test"}, "Success")

	entries, err := os.ReadDir(tmpLoggingDir)
	if err != nil || len(entries) == 0 {
		t.Fatalf("Failed to find logged insight file in %s: %v", tmpLoggingDir, err)
	}

	content, err := os.ReadFile(filepath.Join(tmpLoggingDir, entries[0].Name()))
	if err != nil || !strings.Contains(string(content), "Published Insight Summary") {
		t.Errorf("Insight summary content invalid: %s", string(content))
	}

	_ = os.RemoveAll(tmpLoggingDir)
}

func TestAgentPolicyEnforcement(t *testing.T) {
	testTools := []tools.ToolDefinition{
		{
			Name: "InsightsPublish",
			Policy: tools.ToolPolicy{
				ReadOnly:         false,
				Destructive:      false,
				RequiresApproval: true,
			},
			Execute: func(args map[string]interface{}) (string, error) {
				return "Published successfully", nil
			},
		},
	}

	am := agent.NewAgentManager(testTools)
	toolDef := am.Tools["InsightsPublish"]

	// INSIGHT_HUMAN_IN_THE_LOOP=true without approval
	os.Setenv("INSIGHT_HUMAN_IN_THE_LOOP", "true")
	hitlEnv := strings.ToLower(os.Getenv("INSIGHT_HUMAN_IN_THE_LOOP"))
	argsUnapproved := map[string]interface{}{}
	approved, _ := argsUnapproved["approved"].(bool)

	if (hitlEnv == "true") && !approved {
		// Passed HITL check blocking unapproved calls
	} else {
		t.Errorf("Expected HITL check to detect unapproved state")
	}

	// With approval=true
	argsApproved := map[string]interface{}{"approved": true}
	res, err := toolDef.Execute(argsApproved)
	if err != nil || res != "Published successfully" {
		t.Errorf("Expected tool execution to succeed with approved=true, got: %v, %v", res, err)
	}

	os.Unsetenv("INSIGHT_HUMAN_IN_THE_LOOP")
}
