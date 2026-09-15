package main

import (
	"encoding/json"
	"testing"
)

func TestOrderedRawRequestBodies(t *testing.T) {
	inspection, err := json.Marshal(inspectRequest{Version: "1", Kind: "inspect_session", Store: "store", Session: "session"})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(inspection), `{"version":"1","kind":"inspect_session","store":"store","session":"session"}`; got != want {
		t.Fatalf("inspection = %s, want %s", got, want)
	}
	result, err := json.Marshal(readResultRequest{Version: "1", Kind: "read_result", Store: "store", Key: "key"})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := string(result), `{"version":"1","kind":"read_result","store":"store","key":"key"}`; got != want {
		t.Fatalf("read result = %s, want %s", got, want)
	}
}

func TestLatencyStatusBoundaryAndTopLevelReduction(t *testing.T) {
	if got := latencyStatus(1000, 1000); got != "passed" {
		t.Fatalf("limit boundary reduced to %s", got)
	}
	if got := latencyStatus(1000, 1000.001); got != "target_miss" {
		t.Fatalf("above-limit latency reduced to %s", got)
	}
	if got := controlStatus(map[string]any{"status": "passed"}, map[string]any{"status": "target_miss"}); got != "target_miss" {
		t.Fatalf("top-level control status reduced to %s", got)
	}
}
