package main

import "testing"

func TestParseRejectsTraceLoss(t *testing.T) {
	_, err := parseTraces([]byte("{\"rui_test_phase\":\"lifecycle_boundary\",\"at_ns\":\"1\",\"start_ns\":\"0\",\"wait_ns\":\"0\",\"process\":\"7\",\"run\":\"1\",\"clock\":\"awake_ns\",\"sequence\":\"1\",\"trace_lost\":true}\n"))
	if err == nil {
		t.Fatal("expected provenance failure")
	}
}
