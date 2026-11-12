package main

import "testing"

func TestRetryRejectsUnknownEvidence(t *testing.T) {
	for _, value := range []any{nil, "unavailable", "unexpected", "failed", 0} {
		if got := retryStatus(map[string]any{"status": value}); got != "failed" {
			t.Errorf("status %v reduced to %s", value, got)
		}
	}
	if got := retryStatus(map[string]any{}); got != "failed" {
		t.Errorf("missing status reduced to %s", got)
	}
}
