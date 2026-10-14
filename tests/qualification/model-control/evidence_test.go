package main

import (
	"testing"

	"rui.local/qualification/measurement"
)

func TestControlRejectsUnknownEvidence(t *testing.T) {
	for _, value := range []any{nil, "unexpected", 0} {
		if got := controlStatus(map[string]any{"status": value}); got != "failed" {
			t.Errorf("status %v reduced to %s", value, got)
		}
	}
	if got := controlStatus(map[string]any{}); got != "failed" {
		t.Errorf("missing status reduced to %s", got)
	}
	for _, status := range []string{"unavailable", "invalid_measurement"} {
		got := controlStatus(map[string]any{"status": status})
		if got != status || measurement.QualificationExitCode(map[string]any{"status": got}) == 0 {
			t.Errorf("nonqualifying evidence %s reduced to %s", status, got)
		}
	}
}
