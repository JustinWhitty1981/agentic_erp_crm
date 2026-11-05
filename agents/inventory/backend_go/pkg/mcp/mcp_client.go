package mcp

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"jada-backend/pkg/formatters"
	"jada-backend/pkg/tools"
)

func LogInsightSummary(toolName string, args map[string]interface{}, responseResult string) {
	dir := "insight_logging"
	if err := os.MkdirAll(dir, 0755); err != nil {
		log.Printf("Failed to create insight_logging directory: %v", err)
		return
	}

	now := time.Now().UTC()
	filename := fmt.Sprintf("insight_%s_%d.md", now.Format("20060102_150405"), now.Nanosecond()/1e6)
	fp := filepath.Join(dir, filename)

	var sb strings.Builder
	sb.WriteString("# Published Insight Summary\n\n")
	sb.WriteString(fmt.Sprintf("**Timestamp:** %s\n", now.Format("2006-01-02 15:04:05 UTC")))
	sb.WriteString(fmt.Sprintf("**Tool Name:** %s\n\n", toolName))

	sb.WriteString("## Input Parameters\n```json\n")
	argsJSON, _ := json.MarshalIndent(args, "", "  ")
	sb.WriteString(string(argsJSON))
	sb.WriteString("\n```\n\n")

	sb.WriteString("## Response Result\n```\n")
	sb.WriteString(responseResult)
	sb.WriteString("\n```\n")

	if err := os.WriteFile(fp, []byte(sb.String()), 0644); err != nil {
		log.Printf("Failed to write insight summary to %s: %v", fp, err)
	} else {
		log.Printf("Insight summary logged successfully to: %s", fp)
	}
}

func fixInsightPayload(v interface{}) interface{} {
	switch val := v.(type) {
	case string:
		strTrim := strings.TrimSpace(val)
		if (strings.HasPrefix(strTrim, "[") && strings.HasSuffix(strTrim, "]")) ||
			(strings.HasPrefix(strTrim, "{") && strings.HasSuffix(strTrim, "}")) {
			var parsed interface{}
			if err := json.Unmarshal([]byte(strTrim), &parsed); err == nil {
				return fixInsightPayload(parsed)
			}
		}
		return val
	case map[string]interface{}:
		return []interface{}{val}
	case []interface{}:
		var cleaned []interface{}
		for _, item := range val {
			subCleaned := fixInsightPayload(item)
			if subList, ok := subCleaned.([]interface{}); ok {
				cleaned = append(cleaned, subList...)
			} else {
				cleaned = append(cleaned, subCleaned)
			}
		}
		return cleaned
	default:
		return v
	}
}

func SanitizeMCPToolArgs(toolName string, args map[string]interface{}) map[string]interface{} {
	if args == nil {
		return args
	}

	sanitized := make(map[string]interface{})
	for k, v := range args {
		sanitized[k] = v
	}

	nowUTC := time.Now().UTC()

	timeKeys := []string{"start_ts", "end_ts", "compare_start_ts", "compare_end_ts"}
	for _, tk := range timeKeys {
		val, ok := sanitized[tk]
		if !ok {
			continue
		}
		valStr, isStr := val.(string)
		if !isStr {
			continue
		}

		valTrimmed := strings.TrimSpace(valStr)
		valLower := strings.ToLower(valTrimmed)

		if valLower == "now" || valLower == "today" {
			sanitized[tk] = nowUTC.Format("2006-01-02T15:04:05Z")
		} else if strings.HasPrefix(valLower, "now-") {
			re := regexp.MustCompile(`now-(\d+)([hdm])`)
			match := re.FindStringSubmatch(valLower)
			if len(match) > 2 {
				num, _ := strconv.Atoi(match[1])
				unit := match[2]
				var st time.Time
				switch unit {
				case "h":
					st = nowUTC.Add(-time.Duration(num) * time.Hour)
				case "d":
					st = nowUTC.Add(-time.Duration(num) * 24 * time.Hour)
				case "m":
					st = nowUTC.Add(-time.Duration(num) * time.Minute)
				default:
					st = nowUTC.Add(-4 * time.Hour)
				}
				sanitized[tk] = st.Format("2006-01-02T15:04:05Z")
			}
		} else if strings.Contains(valLower, "hour") || strings.Contains(valLower, "day") || strings.Contains(valLower, "ago") {
			re := regexp.MustCompile(`(\d+)\s*(hour|day|min)`)
			match := re.FindStringSubmatch(valLower)
			if len(match) > 2 {
				num, _ := strconv.Atoi(match[1])
				unit := match[2]
				var st time.Time
				if strings.Contains(unit, "hour") {
					st = nowUTC.Add(-time.Duration(num) * time.Hour)
				} else if strings.Contains(unit, "day") {
					st = nowUTC.Add(-time.Duration(num) * 24 * time.Hour)
				} else {
					st = nowUTC.Add(-time.Duration(num) * time.Minute)
				}
				sanitized[tk] = st.Format("2006-01-02T15:04:05Z")
			}
		}
	}

	nameLower := strings.ToLower(toolName)
	if strings.Contains(nameLower, "insightspublish") || strings.Contains(nameLower, "publish") {
		sanitized["agent_name"] = "J.A.D.A"
		if rawInsight, ok := sanitized["insight"]; ok {
			sanitized["insight"] = fixInsightPayload(rawInsight)
		}
	}

	return sanitized
}

type MCPToolSchema struct {
	Name        string                 `json:"name"`
	Description string                 `json:"description"`
	InputSchema map[string]interface{} `json:"inputSchema"`
}

type MCPListToolsResult struct {
	Tools []MCPToolSchema `json:"tools"`
}

type MCPJSONRPCRequest struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      interface{} `json:"id,omitempty"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params,omitempty"`
}

type MCPJSONRPCResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      interface{}     `json:"id,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

func initMCPSession(mcpURL, bearerToken string) (string, error) {
	client := &http.Client{Timeout: 15 * time.Second}

	initPayload := MCPJSONRPCRequest{
		JSONRPC: "2.0",
		ID:      1,
		Method:  "initialize",
		Params: map[string]interface{}{
			"protocolVersion": "2024-11-05",
			"capabilities":    map[string]interface{}{},
			"clientInfo": map[string]string{
				"name":    "J.A.D.A-Go",
				"version": "1.0.0",
			},
		},
	}

	jsonBytes, err := json.Marshal(initPayload)
	if err != nil {
		return "", err
	}

	req, err := http.NewRequest("POST", mcpURL, bytes.NewBuffer(jsonBytes))
	if err != nil {
		return "", err
	}

	req.Header.Set("Content-Type", "application/json")
	if bearerToken != "" {
		req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", bearerToken))
	}

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("MCP initialize returned status %d: %s", resp.StatusCode, string(body))
	}

	sessionID := resp.Header.Get("Mcp-Session-Id")

	// Send initialized notification
	notifPayload := MCPJSONRPCRequest{
		JSONRPC: "2.0",
		Method:  "notifications/initialized",
	}
	notifBytes, _ := json.Marshal(notifPayload)
	notifReq, err := http.NewRequest("POST", mcpURL, bytes.NewBuffer(notifBytes))
	if err == nil {
		notifReq.Header.Set("Content-Type", "application/json")
		if bearerToken != "" {
			notifReq.Header.Set("Authorization", fmt.Sprintf("Bearer %s", bearerToken))
		}
		if sessionID != "" {
			notifReq.Header.Set("Mcp-Session-Id", sessionID)
		}
		notifResp, err := client.Do(notifReq)
		if err == nil {
			notifResp.Body.Close()
		}
	}

	return sessionID, nil
}

func GetHighByteMCPTools() []tools.ToolDefinition {
	enabledEnv := strings.ToLower(os.Getenv("HIGHBYTE_MCP_ENABLED"))
	if enabledEnv == "false" || enabledEnv == "0" || enabledEnv == "no" {
		log.Println("HighByte MCP integration is disabled via HIGHBYTE_MCP_ENABLED=false.")
		return nil
	}

	mcpURL := os.Getenv("HIGHBYTE_MCP_URL")
	if mcpURL == "" {
		mcpURL = "https://your-mcp-server:8885/mcp"
	}

	bearerToken := os.Getenv("HIGHBYTE_MCP_BEARER_TOKEN")
	if bearerToken == "" {
		bearerToken = os.Getenv("MCP_BEARER_TOKEN")
	}

	log.Printf("Loading HighByte MCP tools from: %s", mcpURL)

	sessionID, err := initMCPSession(mcpURL, bearerToken)
	if err != nil {
		log.Printf("Could not initialize HighByte MCP session: %v. Proceeding with local tools only.", err)
		return nil
	}

	reqBody := MCPJSONRPCRequest{
		JSONRPC: "2.0",
		ID:      2,
		Method:  "tools/list",
	}

	jsonBytes, err := json.Marshal(reqBody)
	if err != nil {
		log.Printf("Could not marshal MCP list request: %v", err)
		return nil
	}

	client := &http.Client{Timeout: 15 * time.Second}
	req, err := http.NewRequest("POST", mcpURL, bytes.NewBuffer(jsonBytes))
	if err != nil {
		log.Printf("Could not create MCP list request: %v", err)
		return nil
	}

	req.Header.Set("Content-Type", "application/json")
	if bearerToken != "" {
		req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", bearerToken))
	}
	if sessionID != "" {
		req.Header.Set("Mcp-Session-Id", sessionID)
	}

	resp, err := client.Do(req)
	if err != nil {
		log.Printf("Could not load HighByte MCP tools from %s: %v. Proceeding with local tools only.", mcpURL, err)
		return nil
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		log.Printf("MCP tools/list returned status %d. Proceeding with local tools only.", resp.StatusCode)
		return nil
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Printf("Could not read MCP response: %v", err)
		return nil
	}

	var jsonResp MCPJSONRPCResponse
	if err := json.Unmarshal(body, &jsonResp); err != nil {
		log.Printf("Could not decode MCP JSON-RPC response: %v", err)
		return nil
	}

	if jsonResp.Error != nil {
		log.Printf("MCP JSON-RPC error: %s", jsonResp.Error.Message)
		return nil
	}

	var listResult MCPListToolsResult
	if err := json.Unmarshal(jsonResp.Result, &listResult); err != nil {
		log.Printf("Could not parse MCP tools list: %v", err)
		return nil
	}

	var mcpTools []tools.ToolDefinition
	for _, t := range listResult.Tools {
		toolName := t.Name
		toolDesc := t.Description
		toolParams := t.InputSchema

		nameLower := strings.ToLower(toolName)
		isInsightPublish := strings.Contains(nameLower, "insightspublish") || strings.Contains(nameLower, "publish")
		isDestructive := strings.Contains(nameLower, "delete") || strings.Contains(nameLower, "remove")

		toolPolicy := tools.ToolPolicy{
			ReadOnly:         !isInsightPublish && !isDestructive,
			Destructive:      isDestructive,
			RequiresApproval: isInsightPublish || isDestructive,
		}

		execFunc := func(args map[string]interface{}) (string, error) {
			sanitizedArgs := SanitizeMCPToolArgs(toolName, args)

			// Execute tool with on-demand MCP session initialization to prevent session expiry
			execSessionID, err := initMCPSession(mcpURL, bearerToken)
			if err != nil {
				execSessionID = sessionID // Fallback to startup sessionID if re-init fails
			}

			callReq := MCPJSONRPCRequest{
				JSONRPC: "2.0",
				ID:      3,
				Method:  "tools/call",
				Params: map[string]interface{}{
					"name":      toolName,
					"arguments": sanitizedArgs,
				},
			}

			callBytes, _ := json.Marshal(callReq)
			httpReq, err := http.NewRequest("POST", mcpURL, bytes.NewBuffer(callBytes))
			if err != nil {
				return fmt.Sprintf("Error executing tool '%s': %v", toolName, err), nil
			}

			httpReq.Header.Set("Content-Type", "application/json")
			if bearerToken != "" {
				httpReq.Header.Set("Authorization", fmt.Sprintf("Bearer %s", bearerToken))
			}
			if execSessionID != "" {
				httpReq.Header.Set("Mcp-Session-Id", execSessionID)
			}

			callClient := &http.Client{Timeout: 30 * time.Second}
			callResp, err := callClient.Do(httpReq)
			if err != nil {
				return fmt.Sprintf("Error executing tool '%s': %v", toolName, err), nil
			}
			defer callResp.Body.Close()

			callBody, err := io.ReadAll(callResp.Body)
			if err != nil {
				return fmt.Sprintf("Error reading output from tool '%s': %v", toolName, err), nil
			}

			var callJSONResp MCPJSONRPCResponse
			if err := json.Unmarshal(callBody, &callJSONResp); err != nil {
				resStr := string(callBody)
				if isInsightPublish {
					LogInsightSummary(toolName, sanitizedArgs, resStr)
				}
				return formatters.TruncateToolOutput(resStr, formatters.MaxToolOutputChars), nil
			}

			if callJSONResp.Error != nil {
				return fmt.Sprintf("Error executing tool '%s': %s", toolName, callJSONResp.Error.Message), nil
			}

			resStr := string(callJSONResp.Result)
			if isInsightPublish {
				LogInsightSummary(toolName, sanitizedArgs, resStr)
			}
			return formatters.TruncateToolOutput(resStr, formatters.MaxToolOutputChars), nil
		}

		mcpTools = append(mcpTools, tools.ToolDefinition{
			Name:        toolName,
			Description: toolDesc,
			Parameters:  toolParams,
			Policy:      toolPolicy,
			Execute:     execFunc,
		})
	}

	log.Printf("Successfully loaded %d HighByte MCP tools into Go agent.", len(mcpTools))
	return mcpTools
}
