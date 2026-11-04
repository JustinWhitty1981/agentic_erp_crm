package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

type TestResultItem struct {
	NodeID          string  `json:"node_id"`
	TestName        string  `json:"test_name"`
	Status          string  `json:"status"`
	DurationSeconds float64 `json:"duration_seconds"`
	Error           string  `json:"error,omitempty"`
}

type TestSummaryReport struct {
	Timestamp       string           `json:"timestamp"`
	Total           int              `json:"total"`
	Passed          int              `json:"passed"`
	Failed          int              `json:"failed"`
	Skipped         int              `json:"skipped"`
	DurationSeconds float64          `json:"duration_seconds"`
	ExitCode        int              `json:"exit_code"`
	Tests           []TestResultItem `json:"tests"`
}

func main() {
	fmt.Println("======================================================================")
	fmt.Println("J.A.D.A GO AGENT REGRESSION & UNIT TEST SUITE")
	fmt.Println("======================================================================")

	startTime := time.Now()

	cmd := exec.Command("go", "test", "-v", "./tests/...")
	cmd.Dir = filepath.Dir(os.Args[0])
	out, err := cmd.CombinedOutput()
	duration := time.Since(startTime).Seconds()

	exitCode := 0
	if err != nil {
		exitCode = 1
	}

	fmt.Println(string(out))

	passed := 1
	failed := 0
	if exitCode != 0 {
		passed = 0
		failed = 1
	}

	report := TestSummaryReport{
		Timestamp:       time.Now().Format("2006-01-02 15:04:05"),
		Total:           passed + failed,
		Passed:          passed,
		Failed:          failed,
		Skipped:         0,
		DurationSeconds: duration,
		ExitCode:        exitCode,
		Tests: []TestResultItem{
			{
				NodeID:          "tests/agent_test.go",
				TestName:        "GoBackendSuite",
				Status:          func() string { if exitCode == 0 { return "PASSED" }; return "FAILED" }(),
				DurationSeconds: duration,
			},
		},
	}

	reportPath := "test_results.json"
	bytes, _ := json.MarshalIndent(report, "", "  ")
	_ = os.WriteFile(reportPath, bytes, 0644)

	fmt.Println("======================================================================")
	fmt.Printf("Detailed report saved to: %s\n\n", reportPath)
	os.Exit(exitCode)
}
