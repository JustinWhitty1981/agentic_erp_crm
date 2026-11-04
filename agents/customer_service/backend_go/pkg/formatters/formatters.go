package formatters

import (
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const MaxToolOutputChars = 12000

func SummarizePaintDefectsData(data []map[string]interface{}) string {
	total := len(data)
	var fails []map[string]interface{}
	var passes []map[string]interface{}

	defects := make(map[string]int)

	for _, d := range data {
		isFail := false
		if val, ok := d["is_fail"]; ok {
			switch v := val.(type) {
			case float64:
				if v == 1 {
					isFail = true
				}
			case int:
				if v == 1 {
					isFail = true
				}
			case bool:
				if v {
					isFail = true
				}
			}
		}

		if grade, ok := d["door_grade"]; ok {
			if strings.EqualFold(fmt.Sprintf("%v", grade), "fail") {
				isFail = true
			} else if strings.EqualFold(fmt.Sprintf("%v", grade), "pass") {
				passes = append(passes, d)
			}
		}

		if isFail {
			fails = append(fails, d)
			reason := "Unspecified Defect"
			if r, ok := d["reason_description"]; ok && fmt.Sprintf("%v", r) != "" && fmt.Sprintf("%v", r) != "<nil>" {
				reason = fmt.Sprintf("%v", r)
			}
			defects[reason]++
		}
	}

	failRate := 0.0
	if total > 0 {
		failRate = math.Round(float64(len(fails))/float64(total)*1000) / 10.0
	}

	var lines []string
	lines = append(lines, "## Paint Inspection Defect Summary Data\n")
	lines = append(lines, fmt.Sprintf("- **Total Inspected Doors**: %d", total))
	lines = append(lines, fmt.Sprintf("- **Passes**: %d", len(passes)))
	lines = append(lines, fmt.Sprintf("- **Failures**: %d (%.1f%% failure rate)\n", len(fails), failRate))
	lines = append(lines, "### Defect Breakdown by Type:")

	if len(defects) > 0 {
		type kv struct {
			Key   string
			Value int
		}
		var sortedDefects []kv
		for k, v := range defects {
			sortedDefects = append(sortedDefects, kv{k, v})
		}
		sort.Slice(sortedDefects, func(i, j int) bool {
			return sortedDefects[i].Value > sortedDefects[j].Value
		})

		for _, item := range sortedDefects {
			lines = append(lines, fmt.Sprintf("- **%s**: %d", item.Key, item.Value))
		}
	} else {
		lines = append(lines, "No defect failures recorded in this dataset.")
	}

	return strings.Join(lines, "\n")
}

func SummarizeRawJSONIfNeeded(rawStr string) string {
	if strings.TrimSpace(rawStr) == "" {
		return rawStr
	}

	cleanRaw := strings.TrimSpace(rawStr)
	if cleanRaw == "null" || cleanRaw == "[]" {
		return "No records found for the requested parameters."
	}

	if strings.HasPrefix(cleanRaw, "[") && strings.HasSuffix(cleanRaw, "]") {
		var list []map[string]interface{}
		if err := json.Unmarshal([]byte(cleanRaw), &list); err == nil && len(list) > 0 {
			first := list[0]
			_, hasGrade := first["door_grade"]
			_, hasReason := first["reason_description"]
			_, hasIsFail := first["is_fail"]
			if hasGrade || hasReason || hasIsFail {
				return SummarizePaintDefectsData(list)
			}
		}
	}

	return rawStr
}

func TruncateToolOutput(result interface{}, maxChars int) string {
	if maxChars <= 0 {
		maxChars = MaxToolOutputChars
	}

	var resStr string
	switch v := result.(type) {
	case string:
		resStr = v
	default:
		bytes, err := json.Marshal(v)
		if err != nil {
			resStr = fmt.Sprintf("%v", v)
		} else {
			resStr = string(bytes)
		}
	}

	resStr = SummarizeRawJSONIfNeeded(resStr)

	if len(resStr) > maxChars {
		originalLen := len(resStr)
		resStr = resStr[:maxChars] + fmt.Sprintf("\n\n... (tool output truncated from %d characters to fit context window)", originalLen)
	}

	return resStr
}

func FormatFallbackToolSummary(rawOutput string) string {
	if strings.TrimSpace(rawOutput) == "" {
		return "Task completed successfully."
	}

	cleanRaw := strings.TrimSpace(rawOutput)

	// 1. Check paint defects JSON
	if strings.HasPrefix(cleanRaw, "[") && strings.HasSuffix(cleanRaw, "]") {
		var list []map[string]interface{}
		if err := json.Unmarshal([]byte(cleanRaw), &list); err == nil && len(list) > 0 {
			first := list[0]
			_, hasIsFail := first["is_fail"]
			_, hasDoorNum := first["door_number"]
			if hasIsFail || hasDoorNum {
				return SummarizePaintDefectsData(list)
			}
		}
	}

	// 2. Weather snippet formatting
	if strings.Contains(cleanRaw, "temp_f") || strings.Contains(cleanRaw, "temp_c") || strings.Contains(cleanRaw, "humidity") {
		reTempF := regexp.MustCompile(`"temp_f"\s*:\s*([\d\.]+)`)
		reHumidity := regexp.MustCompile(`"humidity"\s*:\s*(\d+)`)
		reCondition := regexp.MustCompile(`"text"\s*:\s*"([^"]+)"`)

		matchF := reTempF.FindStringSubmatch(cleanRaw)
		matchHum := reHumidity.FindStringSubmatch(cleanRaw)
		matchCond := reCondition.FindStringSubmatch(cleanRaw)

		var lines []string
		lines = append(lines, "## Weather Summary\n")

		if len(matchF) > 1 {
			valF, _ := strconv.ParseFloat(matchF[1], 64)
			valC := math.Round((valF-32)*5/9*10) / 10
			lines = append(lines, fmt.Sprintf("- **Temperature**: %.1f°F (%.1f°C)", valF, valC))
		}
		if len(matchHum) > 1 {
			lines = append(lines, fmt.Sprintf("- **Humidity**: %s%%", matchHum[1]))
		}
		if len(matchCond) > 1 {
			lines = append(lines, fmt.Sprintf("- **Conditions**: %s", strings.TrimSpace(matchCond[1])))
		}

		if len(lines) > 1 {
			return strings.Join(lines, "\n")
		}
	}

	reNewlines := regexp.MustCompile(`[\r\n]{3,}`)
	cleaned := reNewlines.ReplaceAllString(cleanRaw, "\n\n")
	cleaned = strings.TrimSpace(cleaned)

	if cleaned != "" {
		return cleaned
	}
	return "The tool query completed successfully."
}
