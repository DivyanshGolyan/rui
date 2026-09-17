package main

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestScenarioCallsVaryClassificationAndPayloadIndependently(t *testing.T) {
	value := scenario{Name: "asymmetric", Valid: 2, Rejected: 3, ArgumentBytes: 37}
	calls := scenarioCalls(value, "/must/not/run")
	if len(calls) != 5 {
		t.Fatalf("got %d calls", len(calls))
	}
	for index := 0; index < 2; index++ {
		if calls[index].Name != "bash" {
			t.Fatalf("valid call %d classified by fixture as %q", index, calls[index].Name)
		}
		var descriptor struct {
			Cmd string `json:"cmd"`
		}
		if err := json.Unmarshal([]byte(calls[index].Arguments), &descriptor); err != nil {
			t.Fatal(err)
		}
		if !bytes.HasPrefix([]byte(descriptor.Cmd), []byte("touch \"/must/not/run\"")) {
			t.Fatalf("valid call does not create the forbidden-effect sentinel if launched: %q", descriptor.Cmd)
		}
		if !bytes.Contains([]byte(descriptor.Cmd), bytes.Repeat([]byte("x"), 37)) {
			t.Fatalf("valid descriptor omitted independent payload: %q", descriptor.Cmd)
		}
	}
	if calls[2].Name != "unknown" || calls[3].Name != "bash" || calls[3].Arguments != "{" || calls[4].Name != "unknown" {
		t.Fatalf("rejected population does not alternate unknown/malformed: %+v", calls[2:])
	}
}

func TestLatencySummaryUsesNearestRank(t *testing.T) {
	actual := latencySummary([]float64{100, 1, 2, 3, 4})
	if actual["minimum_ms"] != float64(1) || actual["p50_ms"] != float64(3) ||
		actual["p95_ms"] != float64(100) || actual["maximum_ms"] != float64(100) {
		t.Fatalf("unexpected summary: %v", actual)
	}
	if empty := latencySummary(nil); empty["count"] != 0 || len(empty) != 1 {
		t.Fatalf("unexpected empty summary: %v", empty)
	}
}

func TestObservedCountsRejectsMalformedReport(t *testing.T) {
	_, _, err := observedCounts(map[string]any{
		"actions":        map[string]any{"count": 1},
		"rejected_calls": map[string]any{"count": "0"},
	})
	if err == nil {
		t.Fatal("numeric action count must not be silently accepted")
	}
}

func TestCombineStatusPreservesVerdictPrecedence(t *testing.T) {
	if got := combineStatus("unavailable", "target_miss"); got != "target_miss" {
		t.Fatalf("target miss hidden by unavailable: %q", got)
	}
	if got := combineStatus("behavior_error", "passed"); got != "behavior_error" {
		t.Fatalf("behavior failure overwritten: %q", got)
	}
}
