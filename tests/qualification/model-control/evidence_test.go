package main

import "testing"

func TestControlRejectsUnknownEvidence(t *testing.T) {
	for _, value := range []any{nil, "unavailable", "unexpected", 0} {
		if got := controlStatus(map[string]any{"status": value}); got != "failed" {
			t.Errorf("status %v reduced to %s", value, got)
		}
	}
	if got := controlStatus(map[string]any{}); got != "failed" {
		t.Errorf("missing status reduced to %s", got)
	}
}
